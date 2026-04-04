//
//  MIT License
//
//  Copyright (c) 2026 Thomas Durand
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.
//

import HTTPTypes
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Hummingbird
import HummingbirdCompression
import HummingbirdWebSocket
import HummingbirdWSCompression
import Logging
import ServiceLifecycle

/// Installs Engine.IO routes into an existing Hummingbird router.
public struct EngineIOEndpoint: Sendable {
    /// The configuration used by this endpoint.
    public let configuration: ServerConfiguration

    private let handler: ServerHandler

    /// Creates an endpoint with the provided configuration.
    ///
    /// - Parameter configuration: The Engine.IO server configuration to apply.
    public init(configuration: ServerConfiguration = .init()) {
        self.configuration = configuration
        self.handler = ServerHandler(configuration: configuration)
    }

    /// The WebSocket server configuration that must be passed to Hummingbird's upgrade server.
    public var webSocketConfiguration: WebSocketServerConfiguration {
        configuration.webSocketServerConfiguration
    }

    /// The currently connected Engine.IO clients keyed by session identifier.
    public var clients: [String: EngineIOConnection] {
        get async {
            await handler.clients
        }
    }

    /// The number of currently connected Engine.IO clients.
    public var clientsCount: Int {
        get async {
            await handler.clientsCount
        }
    }

    /// Registers the Engine.IO HTTP routes into a router.
    ///
    /// - Parameter router: The router that should serve the Engine.IO endpoint.
    public func install(into router: Router<BasicRequestContext>) {
        if let httpCompression = configuration.httpCompression {
            router.add(middleware: ResponseCompressionMiddleware<BasicRequestContext>(
                minimumResponseSizeToCompress: httpCompression.minimumByteCount
            ))
        }
        let primaryPath = configuration.supportedPaths.first ?? configuration.path
        let routePath = RouterPath(primaryPath)
        router.get(routePath, use: handler.callAsFunction)
        router.post(routePath, use: handler.callAsFunction)
        router.put(routePath, use: handler.callAsFunction)
        router.patch(routePath, use: handler.callAsFunction)
        router.delete(routePath, use: handler.callAsFunction)
        router.head(routePath, use: handler.callAsFunction)
        router.on(routePath, method: .options, use: handler.preflight)
    }

    /// Validates and prepares a WebSocket upgrade request.
    ///
    /// - Parameters:
    ///   - request: The incoming HTTP upgrade request.
    ///   - logger: The logger associated with the request.
    /// - Returns: The Hummingbird upgrade decision for the request.
    public func shouldUpgrade(
        request: HTTPRequest,
        logger: Logger
    ) async -> ShouldUpgradeResult<WebSocketDataHandler<HTTP1WebSocketUpgradeChannel.Context>> {
        await handler.shouldUpgrade(request: request, logger: logger)
    }

    /// Stops accepting new Engine.IO sessions and closes all currently connected clients.
    public func close() async {
        await handler.close()
    }
}

/// A convenience Hummingbird service that hosts an Engine.IO endpoint.
public struct Server: Service {
    /// The Engine.IO endpoint exposed by the server.
    public let endpoint: EngineIOEndpoint
    /// The underlying Hummingbird application.
    public let application: Application<RouterResponder<BasicRequestContext>>

    /// The currently connected Engine.IO clients keyed by session identifier.
    public var clients: [String: EngineIOConnection] {
        get async {
            await endpoint.clients
        }
    }

    /// The number of currently connected Engine.IO clients.
    public var clientsCount: Int {
        get async {
            await endpoint.clientsCount
        }
    }

    /// Creates a server bound to a TCP port.
    ///
    /// - Parameters:
    ///   - port: The port to bind on `0.0.0.0`.
    ///   - configuration: The Engine.IO server configuration to apply.
    public init(port: Int, configuration: ServerConfiguration = .init()) {
        self.init(host: "0.0.0.0", port: port, configuration: configuration)
    }

    /// Creates a server bound to a given host and TCP port.
    ///
    /// - Parameters:
    ///   - host: The host to bind.
    ///   - port: The port to bind.
    ///   - configuration: The Engine.IO server configuration to apply.
    public init(host: String, port: Int, configuration: ServerConfiguration = .init()) {
        let endpoint = EngineIOEndpoint(configuration: configuration)
        let router = Router()
        router.add(middleware: LogRequestsMiddleware(.debug))
        endpoint.install(into: router)
        self.endpoint = endpoint
        self.application = Application(
            router: router,
            server: .http1WebSocketUpgrade(configuration: endpoint.webSocketConfiguration) { request, _, logger in
                await endpoint.shouldUpgrade(request: request, logger: logger)
            },
            configuration: .init(address: .hostname(host, port: port))
        )
    }

    /// Starts the underlying Hummingbird application.
    public func run() async throws {
        try await application.runService()
    }

    /// Stops accepting new Engine.IO sessions and closes all currently connected clients.
    ///
    /// This only shuts down the Engine.IO layer. The surrounding Hummingbird application
    /// continues to run until its own lifecycle is stopped.
    public func close() async {
        await endpoint.close()
    }
}

private struct WebSocketHandlerPlan: Sendable {
    enum Mode: Sendable {
        case newSession(SessionHandshake)
        case upgradeExisting(String)
    }

    let mode: Mode
}

struct ServerHandler {
    let configuration: ServerConfiguration
    let sessions: SessionStore

    init(configuration: ServerConfiguration) {
        self.configuration = configuration
        self.sessions = SessionStore(configuration: configuration)
    }

    var clients: [String: EngineIOConnection] {
        get async {
            await sessions.connections()
        }
    }

    var clientsCount: Int {
        get async {
            await sessions.connectionCount()
        }
    }

    func close() async {
        await sessions.close()
    }

    func preflight(request: Request, context: BasicRequestContext) async throws -> Response {
        guard configuration.supports(path: request.uri.path) else {
            return notFoundResponse()
        }
        do {
            return try await makePreflightResponse(for: request.head)
        } catch {
            let errorContext = EngineIOErrorContext(
                phase: .cors,
                kind: .internalFailure,
                message: "Failed to build CORS preflight response",
                request: request.head,
                isTerminal: false,
                underlyingErrorDescription: String(describing: error)
            )
            return await handshakeFailureResponse(
                default: .internalServerError(),
                context: errorContext,
                request: request.head,
                logger: context.logger
            )
        }
    }

    func callAsFunction(request: Request, context: BasicRequestContext) async throws -> Response {
        guard configuration.supports(path: request.uri.path) else {
            return notFoundResponse()
        }
        let query = request.uri.queryParameters
        guard let rawVersion = query["EIO"], Int(rawVersion) == 4 else {
            let errorContext = EngineIOErrorContext(
                phase: .handshake,
                kind: .protocolViolation,
                message: "Missing or invalid EIO",
                request: request.head,
                transport: .polling,
                isTerminal: false
            )
            return await handshakeFailureResponse(
                default: .badRequest("Missing or invalid EIO"),
                context: errorContext,
                request: request.head,
                logger: context.logger
            )
        }
        guard
            let rawTransport = query["transport"],
            let transport = Transport(name: rawTransport),
            transport == .polling,
            configuration.transports.contains(.polling)
        else {
            let errorContext = EngineIOErrorContext(
                phase: .handshake,
                kind: .protocolViolation,
                message: "Missing or invalid transport",
                request: request.head,
                transport: .polling,
                isTerminal: false
            )
            return await handshakeFailureResponse(
                default: .badRequest("Missing or invalid transport"),
                context: errorContext,
                request: request.head,
                logger: context.logger
            )
        }
        guard let sid = query["sid"].map(String.init) else {
            guard request.method == .get else {
                let errorContext = EngineIOErrorContext(
                    phase: .handshake,
                    kind: .protocolViolation,
                    message: "Missing sid",
                    request: request.head,
                    transport: .polling,
                    isTerminal: false
                )
                return await handshakeFailureResponse(
                    default: .badRequest("Missing sid"),
                    context: errorContext,
                    request: request.head,
                    logger: context.logger
                )
            }
            if let rejection = await requestAdmissionRejection(for: request.head, transport: .polling) {
                let errorContext = EngineIOErrorContext(
                    phase: .requestAdmission,
                    kind: .rejected,
                    message: rejection.httpMessage,
                    request: request.head,
                    transport: .polling,
                    isTerminal: false
                )
                return await rejectionResponse(
                    rejection,
                    context: errorContext,
                    request: request.head,
                    logger: context.logger
                )
            }
            guard let handshake = await sessions.createPollingSession(request: request.head) else {
                let rejection = EngineIORejection(httpStatus: .serviceUnavailable, httpMessage: "Server is closed")
                let errorContext = EngineIOErrorContext(
                    phase: .session,
                    kind: .rejected,
                    message: rejection.httpMessage,
                    request: request.head,
                    transport: .polling,
                    isTerminal: false
                )
                return await rejectionResponse(
                    rejection,
                    context: errorContext,
                    request: request.head,
                    logger: context.logger
                )
            }
            await configuration.emit(.connected(handshake.connection))
            var response = try pollingResponse(handshakePackets(for: handshake))
            if let cookie = configuration.cookie {
                response.setCookie(cookie.makeCookie(with: handshake.connection.sid))
            }
            return await finalize(response, for: request.head, logger: context.logger)
        }

        switch request.method {
        case .get:
            do {
                let packets = try await sessions.poll(sid: sid)
                return await finalize(try pollingResponse(packets), for: request.head, logger: context.logger)
            } catch let error as SessionError {
                context.logger.notice("Polling GET rejected: \(error)")
                let connection = await sessions.connection(for: sid)
                await reportError(.init(
                    phase: .polling,
                    kind: .protocolViolation,
                    message: error.message,
                    request: request.head,
                    connection: connection,
                    transport: .polling,
                    isTerminal: false
                ))
                return await finalize(errorResponse(error.message), for: request.head, logger: context.logger)
            }
        case .post:
            do {
                try await sessions.beginPollingPost(sid: sid)
            } catch let error as SessionError {
                context.logger.notice("Polling POST rejected: \(error)")
                let connection = await sessions.connection(for: sid)
                await reportError(.init(
                    phase: .polling,
                    kind: .protocolViolation,
                    message: error.message,
                    request: request.head,
                    connection: connection,
                    transport: .polling,
                    isTerminal: false
                ))
                return await finalize(errorResponse(error.message), for: request.head, logger: context.logger)
            }
            defer {
                Task {
                    await sessions.finishPollingPost(sid: sid)
                }
            }
            do {
                var request = request
                let body = try await request.collectBody(upTo: Int(configuration.maxHttpBufferSize))
                let packets = try EngineIOPacket.decodePollingPayload(body)
                for packet in packets {
                    let receivedMessages = try await sessions.processIncomingPacket(sid: sid, packet: packet, via: .polling)
                    await deliver(receivedMessages)
                }
                return await finalize(okResponse(), for: request.head, logger: context.logger)
            } catch let error as SessionError {
                await sessions.closeSession(
                    sid: sid,
                    sendClosePacket: false,
                    reason: error.closeReason
                )
                context.logger.notice("Polling packet rejected: \(error)")
                await reportError(.init(
                    phase: .polling,
                    kind: .protocolViolation,
                    message: error.message,
                    request: request.head,
                    transport: .polling,
                    isTerminal: true
                ))
                return await finalize(errorResponse(error.message), for: request.head, logger: context.logger)
            } catch let error as PacketDecodingError {
                await sessions.closeSession(
                    sid: sid,
                    sendClosePacket: false,
                    reason: .protocolViolation("Invalid payload")
                )
                context.logger.notice("Failed to decode polling payload: \(error)")
                await reportError(.init(
                    phase: .polling,
                    kind: .invalidPayload,
                    message: "Invalid payload",
                    request: request.head,
                    transport: .polling,
                    isTerminal: true,
                    underlyingErrorDescription: String(describing: error)
                ))
                return await finalize(errorResponse("Invalid payload"), for: request.head, logger: context.logger)
            }
        default:
            let errorContext = EngineIOErrorContext(
                phase: .polling,
                kind: .protocolViolation,
                message: "Unsupported HTTP method",
                request: request.head,
                transport: .polling,
                isTerminal: false
            )
            await reportError(errorContext)
            return await finalize(errorResponse("Unsupported HTTP method"), for: request.head, logger: context.logger)
        }
    }

    func shouldUpgrade(
        request: HTTPRequest,
        logger: Logger
    ) async -> ShouldUpgradeResult<WebSocketDataHandler<HTTP1WebSocketUpgradeChannel.Context>> {
        guard let requestTarget = request.path, let components = URLComponents(string: "http://localhost\(requestTarget)") else {
            return .dontUpgrade
        }
        guard configuration.supports(path: components.path) else {
            return .dontUpgrade
        }
        let queryItems = components.queryItems ?? []
        let query = Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name, $0.value ?? "") })
        guard let rawVersion = query["EIO"], Int(rawVersion) == 4 else {
            return await webSocketHandshakeFailure(
                default: .badRequest("Missing or invalid EIO"),
                context: .init(
                    phase: .handshake,
                    kind: .protocolViolation,
                    message: "Missing or invalid EIO",
                    request: request,
                    transport: .websocket,
                    isTerminal: false
                ),
                logger: logger
            )
        }
        guard
            let rawTransport = query["transport"],
            let transport = Transport(name: rawTransport),
            transport == .websocket,
            configuration.transports.contains(.websocket)
        else {
            return await webSocketHandshakeFailure(
                default: .badRequest("Missing or invalid transport"),
                context: .init(
                    phase: .handshake,
                    kind: .protocolViolation,
                    message: "Missing or invalid transport",
                    request: request,
                    transport: .websocket,
                    isTerminal: false
                ),
                logger: logger
            )
        }
        if let rejection = await requestAdmissionRejection(for: request, transport: .websocket) {
            return await webSocketRejection(
                rejection,
                context: .init(
                    phase: .requestAdmission,
                    kind: .rejected,
                    message: rejection.httpMessage,
                    request: request,
                    transport: .websocket,
                    isTerminal: false
                ),
                logger: logger
            )
        }

        let sid = query["sid"]
        let plan = await sessions.prepareWebSocketConnection(request: request, sid: sid)
        switch plan {
        case .reject(let reason):
            return await webSocketHandshakeFailure(
                default: .badRequest(reason),
                context: .init(
                    phase: .websocket,
                    kind: .rejected,
                    message: reason,
                    request: request,
                    transport: .websocket,
                    isTerminal: false
                ),
                logger: logger
            )
        case .newSession(let handshake):
            let handlerPlan = WebSocketHandlerPlan(mode: .newSession(handshake))
            return .upgrade(webSocketHeaders(for: handshake)) { inbound, outbound, context in
                try await handleWebSocket(inbound: inbound, outbound: outbound, context: context, plan: handlerPlan)
            }
        case .upgradeExisting(let existingSID):
            let handlerPlan = WebSocketHandlerPlan(mode: .upgradeExisting(existingSID))
            return .upgrade([:]) { inbound, outbound, context in
                try await handleWebSocket(inbound: inbound, outbound: outbound, context: context, plan: handlerPlan)
            }
        }
    }

    private func handleWebSocket(
        inbound: WebSocketInboundStream,
        outbound: WebSocketOutboundWriter,
        context: HTTP1WebSocketUpgradeChannel.Context,
        plan: WebSocketHandlerPlan
    ) async throws {
        let (stream, continuation) = AsyncStream.makeStream(of: EngineIOPacket.self)
        let connection: EngineIOConnection
        switch plan.mode {
        case .newSession(let handshake):
            connection = handshake.connection
            await sessions.attachNewWebSocket(sid: connection.sid, continuation: continuation)
            continuation.yield(.open(handshake.openPacket))
            if let initialPacket = configuration.initialPacket {
                continuation.yield(.message(initialPacket))
            }
            await configuration.emit(.connected(connection))
        case .upgradeExisting(let existingSID):
            guard let existingConnection = await sessions.connection(for: existingSID) else {
                try await outbound.close(.protocolError, reason: "Unknown session id")
                return
            }
            connection = existingConnection
            await sessions.attachWebSocketUpgrade(sid: existingSID, continuation: continuation)
        }

        let writerTask = Task {
            try await writeWebSocketPackets(stream: stream, outbound: outbound)
        }
        defer {
            writerTask.cancel()
            Task {
                await sessions.detachWebSocket(
                    sid: connection.sid,
                    reason: .transportClosed("WebSocket disconnected")
                )
            }
        }

        do {
            for try await message in inbound.messages(maxSize: Int(configuration.maxHttpBufferSize)) {
                let packet = try EngineIOPacket.decode(webSocketMessage: message)
                let receivedMessages = try await sessions.processIncomingPacket(
                    sid: connection.sid,
                    packet: packet,
                    via: .websocket
                )
                await deliver(receivedMessages)
            }
        } catch let error as PacketDecodingError {
            await reportError(.init(
                phase: .websocket,
                kind: .invalidPayload,
                message: "Invalid websocket payload",
                request: connection.request,
                connection: connection,
                transport: .websocket,
                isTerminal: true,
                underlyingErrorDescription: String(describing: error)
            ))
            await sessions.closeSession(
                sid: connection.sid,
                sendClosePacket: false,
                reason: .protocolViolation("Invalid websocket payload")
            )
            try? await outbound.close(.protocolError, reason: "Invalid websocket payload")
        } catch let error as SessionError {
            await reportError(.init(
                phase: .websocket,
                kind: .protocolViolation,
                message: error.message,
                request: connection.request,
                connection: connection,
                transport: .websocket,
                isTerminal: true
            ))
            await sessions.closeSession(
                sid: connection.sid,
                sendClosePacket: false,
                reason: error.closeReason
            )
            try? await outbound.close(.protocolError, reason: error.message)
        } catch {
            await reportError(.init(
                phase: .websocket,
                kind: .internalFailure,
                message: "WebSocket connection failed",
                request: connection.request,
                connection: connection,
                transport: .websocket,
                isTerminal: true,
                underlyingErrorDescription: String(describing: error)
            ))
            await sessions.closeSession(
                sid: connection.sid,
                sendClosePacket: false,
                reason: .transportClosed("WebSocket connection failed")
            )
            try? await outbound.close(.unexpectedServerError, reason: "Internal server error")
        }
    }

    private func writeWebSocketPackets(
        stream: AsyncStream<EngineIOPacket>,
        outbound: WebSocketOutboundWriter
    ) async throws {
        for await packet in stream {
            switch packet {
            case .message(.binary(let buffer)):
                try await outbound.write(.binary(buffer))
            case .close:
                try await outbound.write(.text("1"))
                try await outbound.close(.normalClosure, reason: nil)
                return
            default:
                try await outbound.write(.text(try packet.encodeAsText()))
            }
        }
    }

    private func deliver(_ receivedMessages: [ReceivedMessage]) async {
        for receivedMessage in receivedMessages {
            await configuration.emit(.received(receivedMessage.connection, receivedMessage.data))
        }
    }

    private func handshakePackets(for handshake: SessionHandshake) -> [EngineIOPacket] {
        var packets: [EngineIOPacket] = [.open(handshake.openPacket)]
        if let initialPacket = configuration.initialPacket {
            packets.append(.message(initialPacket))
        }
        return packets
    }

    private func requestAdmissionRejection(
        for request: HTTPRequest,
        transport: Transport
    ) async -> EngineIORejection? {
        do {
            switch try await configuration.policy.requestAdmission(request) {
            case .allow:
                return nil
            case .reject(let rejection):
                await reportError(.init(
                    phase: .requestAdmission,
                    kind: .rejected,
                    message: rejection.httpMessage,
                    request: request,
                    transport: transport,
                    isTerminal: false
                ))
                return rejection
            }
        } catch {
            let errorContext = EngineIOErrorContext(
                phase: .requestAdmission,
                kind: .internalFailure,
                message: "Request admission failed",
                request: request,
                transport: transport,
                isTerminal: false,
                underlyingErrorDescription: String(describing: error)
            )
            await reportError(errorContext)
            return await configuration.mapHandshakeRejection(.forbidden(), for: errorContext)
        }
    }

    private func reportError(_ context: EngineIOErrorContext) async {
        await configuration.emit(.error(context))
    }

    private func rejectionResponse(
        _ rejection: EngineIORejection,
        context: EngineIOErrorContext,
        request: HTTPRequest,
        logger: Logger
    ) async -> Response {
        await reportError(context)
        return await finalize(
            errorResponse(rejection.httpMessage, status: rejection.httpStatus),
            for: request,
            logger: logger
        )
    }

    private func handshakeFailureResponse(
        default rejection: EngineIORejection,
        context: EngineIOErrorContext,
        request: HTTPRequest,
        logger: Logger
    ) async -> Response {
        await reportError(context)
        let resolved = await configuration.mapHandshakeRejection(rejection, for: context)
        return await finalize(
            errorResponse(resolved.httpMessage, status: resolved.httpStatus),
            for: request,
            logger: logger
        )
    }

    private func webSocketRejection(
        _ rejection: EngineIORejection,
        context: EngineIOErrorContext,
        logger: Logger
    ) async -> ShouldUpgradeResult<WebSocketDataHandler<HTTP1WebSocketUpgradeChannel.Context>> {
        await reportError(context)
        return .upgrade([:]) { _, outbound, _ in
            logger.notice("Rejecting websocket connection: \(rejection.websocketReason)")
            try? await outbound.close(
                rejection.httpStatus.code >= 500 ? .unexpectedServerError : .protocolError,
                reason: rejection.websocketReason
            )
        }
    }

    private func webSocketHandshakeFailure(
        default rejection: EngineIORejection,
        context: EngineIOErrorContext,
        logger: Logger
    ) async -> ShouldUpgradeResult<WebSocketDataHandler<HTTP1WebSocketUpgradeChannel.Context>> {
        await reportError(context)
        let resolved = await configuration.mapHandshakeRejection(rejection, for: context)
        return .upgrade([:]) { _, outbound, _ in
            logger.notice("Rejecting websocket connection: \(resolved.websocketReason)")
            try? await outbound.close(
                resolved.httpStatus.code >= 500 ? .unexpectedServerError : .protocolError,
                reason: resolved.websocketReason
            )
        }
    }

    private func webSocketHeaders(for handshake: SessionHandshake) -> HTTPFields {
        var headers = HTTPFields()
        if let cookie = configuration.cookie {
            headers[values: .setCookie].append(cookie.makeCookie(with: handshake.connection.sid).description)
        }
        return headers
    }

    private func finalize(_ response: Response, for request: HTTPRequest, logger: Logger) async -> Response {
        do {
            var response = response
            try await applyCorsHeaders(to: &response, for: request, preflight: false)
            return response
        } catch {
            logger.error("Failed to apply CORS headers: \(error)")
            let errorContext = EngineIOErrorContext(
                phase: .cors,
                kind: .internalFailure,
                message: "Failed to apply CORS headers",
                request: request,
                isTerminal: false,
                underlyingErrorDescription: String(describing: error)
            )
            await reportError(errorContext)
            return errorResponse("Internal server error", status: .internalServerError)
        }
    }

    private func makePreflightResponse(for request: HTTPRequest) async throws -> Response {
        var response = Response(status: .noContent, headers: [.connection: "close"], body: .init())
        try await applyCorsHeaders(to: &response, for: request, preflight: true)
        return response
    }

    private func applyCorsHeaders(
        to response: inout Response,
        for request: HTTPRequest,
        preflight: Bool
    ) async throws {
        guard request.headerFields.contains(.origin) else {
            return
        }

        let cors = try await configuration.corsConfiguration(for: request)
        let allowOrigin = try await cors.allowOriginValue(for: request)
        response.headers[.accessControlAllowOrigin] = allowOrigin

        if cors.allowCredentials {
            response.headers[.accessControlAllowCredentials] = "true"
        }

        if cors.shouldVaryOnOrigin {
            response.headers[values: .vary].append("Origin")
        }

        guard preflight else {
            if let exposedHeaders = cors.exposedHeaders, !exposedHeaders.isEmpty {
                response.headers[.accessControlExposeHeaders] = exposedHeaders.map(\.canonicalName).joined(separator: ", ")
            }
            return
        }

        response.headers[.accessControlAllowMethods] = cors.allowedMethods
            .map(\.rawValue)
            .sorted()
            .joined(separator: ", ")

        let requestedHeaders = request.headerFields[.accessControlRequestHeaders]
        if cors.allowedHeaders.isEmpty {
            response.headers[.accessControlAllowHeaders] = requestedHeaders
            if requestedHeaders != nil {
                response.headers[values: .vary].append("Access-Control-Request-Headers")
            }
        } else {
            response.headers[.accessControlAllowHeaders] = cors.allowedHeaders.map(\.canonicalName).joined(separator: ", ")
        }

        if let cacheExpiration = cors.cacheExpiration {
            response.headers[.accessControlMaxAge] = String(cacheExpiration)
        }

        if let exposedHeaders = cors.exposedHeaders, !exposedHeaders.isEmpty {
            response.headers[.accessControlExposeHeaders] = exposedHeaders.map(\.canonicalName).joined(separator: ", ")
        }
    }

    private func pollingResponse(_ packets: [EngineIOPacket]) throws -> Response {
        let payload = try packets.map { try $0.encodeForPolling() }.joined(separator: "\u{1e}")
        var headers = HTTPFields()
        headers[.contentType] = "text/plain; charset=UTF-8"
        headers[.connection] = "close"
        return .init(
            status: .ok,
            headers: headers,
            body: .init(byteBuffer: .init(string: payload))
        )
    }

    private func okResponse() -> Response {
        var headers = HTTPFields()
        headers[.contentType] = "text/plain; charset=UTF-8"
        headers[.connection] = "close"
        return .init(
            status: .ok,
            headers: headers,
            body: .init(byteBuffer: .init(string: "ok"))
        )
    }

    private func notFoundResponse() -> Response {
        .init(status: .notFound)
    }

    private func errorResponse(_ message: String, status: HTTPResponse.Status = .badRequest) -> Response {
        var headers = HTTPFields()
        headers[.contentType] = "text/plain; charset=UTF-8"
        headers[.connection] = "close"
        return .init(
            status: status,
            headers: headers,
            body: .init(byteBuffer: .init(string: message))
        )
    }
}

extension ServerConfiguration {
    var webSocketServerConfiguration: WebSocketServerConfiguration {
        let extensions: [WebSocketExtensionFactory]
        if let perMessageDeflate {
            extensions = [
                .perMessageDeflate(
                    clientMaxWindow: perMessageDeflate.clientMaxWindow,
                    clientNoContextTakeover: perMessageDeflate.clientNoContextTakeover,
                    serverMaxWindow: perMessageDeflate.serverMaxWindow,
                    serverNoContextTakeover: perMessageDeflate.serverNoContextTakeover,
                    compressionLevel: perMessageDeflate.compressionLevel,
                    memoryLevel: perMessageDeflate.memoryLevel,
                    maxDecompressedFrameSize: perMessageDeflate.maxDecompressedFrameSize,
                    minFrameSizeToCompress: perMessageDeflate.minFrameSizeToCompress
                )
            ]
        } else {
            extensions = []
        }
        return .init(
            maxFrameSize: Int(maxHttpBufferSize),
            extensions: extensions
        )
    }
}
