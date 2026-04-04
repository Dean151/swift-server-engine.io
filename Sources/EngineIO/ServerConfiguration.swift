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

/// Lifecycle events emitted by the Engine.IO server.
public enum EngineIOEvent: Sendable {
    /// A client established a new Engine.IO session.
    case connected(EngineIOConnection)
    /// A client sent a payload.
    case received(EngineIOConnection, EngineIOData)
    /// A session closed.
    case closed(EngineIOConnection, EngineIOCloseReason)
    /// The server observed an error while handling a request or session.
    case error(EngineIOErrorContext)
}

/// Why an Engine.IO connection closed.
public enum EngineIOCloseReason: Sendable, Equatable {
    /// The client initiated the close.
    case clientInitiated
    /// The server initiated the close.
    case serverInitiated
    /// The client did not answer heartbeat pings in time.
    case heartbeatTimeout
    /// The connection was closed because the client violated the protocol.
    case protocolViolation(String)
    /// The underlying transport closed unexpectedly.
    case transportClosed(String)
}

/// Context describing an Engine.IO error.
public struct EngineIOErrorContext: Sendable {
    /// The server phase where an error happened.
    public enum Phase: Sendable {
        /// Request admission before any transport-specific handshake.
        case requestAdmission
        /// Initial handshake validation.
        case handshake
        /// HTTP long-polling request handling.
        case polling
        /// WebSocket request handling.
        case websocket
        /// CORS preflight or response generation.
        case cors
        /// Session creation, lookup, or lifecycle management.
        case session
    }

    /// The broad category of an Engine.IO error.
    public enum Kind: Sendable {
        /// The request was deliberately rejected by policy.
        case rejected
        /// The client sent an invalid request or packet for the current state.
        case protocolViolation
        /// The payload could not be decoded or accepted.
        case invalidPayload
        /// A timeout elapsed.
        case timeout
        /// The server encountered an unexpected internal failure.
        case internalFailure
    }

    /// The phase where the error occurred.
    public let phase: Phase
    /// The kind of failure that occurred.
    public let kind: Kind
    /// A human-readable description of the error.
    public let message: String
    /// The request being processed when the error occurred, when available.
    public let request: HTTPRequest?
    /// The associated Engine.IO connection, when available.
    public let connection: EngineIOConnection?
    /// The transport being used when the error occurred, when available.
    public let transport: Transport?
    /// Whether the error terminated the current request or session.
    public let isTerminal: Bool
    /// A string representation of the underlying error, when one exists.
    public let underlyingErrorDescription: String?

    /// Creates an error context.
    ///
    /// - Parameters:
    ///   - phase: The server phase where the error occurred.
    ///   - kind: The category of error.
    ///   - message: A human-readable description.
    ///   - request: The request being processed, if any.
    ///   - connection: The associated connection, if any.
    ///   - transport: The transport in use, if any.
    ///   - isTerminal: Whether the error terminated the current operation.
    ///   - underlyingErrorDescription: A string representation of the underlying error, if any.
    public init(
        phase: Phase,
        kind: Kind,
        message: String,
        request: HTTPRequest? = nil,
        connection: EngineIOConnection? = nil,
        transport: Transport? = nil,
        isTerminal: Bool,
        underlyingErrorDescription: String? = nil
    ) {
        self.phase = phase
        self.kind = kind
        self.message = message
        self.request = request
        self.connection = connection
        self.transport = transport
        self.isTerminal = isTerminal
        self.underlyingErrorDescription = underlyingErrorDescription
    }
}

/// A protocol-level rejection returned during request admission or handshake processing.
public struct EngineIORejection: Sendable {
    /// The HTTP status to return to HTTP clients.
    public let httpStatus: HTTPResponse.Status
    /// The HTTP response body or status message.
    public let httpMessage: String
    /// The close reason to send to WebSocket clients.
    public let websocketReason: String

    /// Creates a rejection payload.
    ///
    /// - Parameters:
    ///   - httpStatus: The HTTP status code to return.
    ///   - httpMessage: The HTTP response message.
    ///   - websocketReason: The WebSocket close reason. Defaults to `httpMessage`.
    public init(
        httpStatus: HTTPResponse.Status,
        httpMessage: String,
        websocketReason: String? = nil
    ) {
        self.httpStatus = httpStatus
        self.httpMessage = httpMessage
        self.websocketReason = websocketReason ?? httpMessage
    }

    /// Creates a `403 Forbidden` rejection.
    ///
    /// - Parameter message: The message to expose to the client.
    public static func forbidden(_ message: String = "Forbidden") -> Self {
        .init(httpStatus: .forbidden, httpMessage: message)
    }

    /// Creates a `400 Bad Request` rejection.
    ///
    /// - Parameter message: The message to expose to the client.
    public static func badRequest(_ message: String) -> Self {
        .init(httpStatus: .badRequest, httpMessage: message)
    }

    /// Creates a `500 Internal Server Error` rejection.
    ///
    /// - Parameter message: The message to expose to the client.
    public static func internalServerError(_ message: String = "Internal server error") -> Self {
        .init(
            httpStatus: .internalServerError,
            httpMessage: message
        )
    }
}

/// Configuration for an Engine.IO server.
public struct ServerConfiguration: Sendable {
    /// Generates unique Engine.IO session identifiers.
    public typealias SessionIDGenerator = @Sendable () -> String
    /// Handles connection lifecycle events that only need the connection itself.
    public typealias LifecycleHandler = @Sendable (EngineIOConnection) async -> Void
    /// Handles incoming application payloads.
    public typealias MessageHandler = @Sendable (EngineIOConnection, EngineIOData) async -> Void
    /// Handles disconnection events.
    public typealias CloseHandler = @Sendable (EngineIOConnection, EngineIOCloseReason) async -> Void
    /// Handles server errors.
    public typealias ErrorHandler = @Sendable (EngineIOErrorContext) async -> Void
    /// Handles all server lifecycle events.
    public typealias EventHandler = @Sendable (EngineIOEvent) async -> Void
    /// Admits or rejects a request during the legacy convenience initialization path.
    public typealias RequestAuthorizer = @Sendable (HTTPRequest) async throws -> Bool

    /// Route-matching settings.
    public let routing: Routing
    /// Heartbeat and timeout settings.
    public let heartbeat: Heartbeat
    /// Transport-specific settings.
    public let transport: TransportConfiguration
    /// The generator used for new session identifiers.
    public let sessionIDGenerator: SessionIDGenerator
    /// CORS behavior for HTTP responses.
    public let cors: Cors
    /// Event handlers invoked for connection lifecycle changes.
    public let lifecycle: Lifecycle
    /// Request admission and handshake error mapping policies.
    public let policy: Policy

    /// Creates a configuration from grouped configuration values.
    ///
    /// - Parameters:
    ///   - routing: Route-matching settings.
    ///   - heartbeat: Heartbeat and timeout settings.
    ///   - transport: Transport-specific settings.
    ///   - sessionIDGenerator: The generator used for new session identifiers.
    ///   - cors: CORS behavior for HTTP responses.
    ///   - lifecycle: Event handlers invoked for connection lifecycle changes.
    ///   - policy: Request admission and handshake error mapping policies.
    public init(
        routing: Routing = .init(),
        heartbeat: Heartbeat = .init(),
        transport: TransportConfiguration = .init(),
        sessionIDGenerator: @escaping SessionIDGenerator = {
            UUID().uuidString.filter { $0 != "-" }
        },
        cors: Cors = .static(.init(allowedOrigin: .all)),
        lifecycle: Lifecycle = .init(),
        policy: Policy = .init()
    ) {
        self.routing = routing
        self.heartbeat = heartbeat
        self.transport = transport
        self.sessionIDGenerator = sessionIDGenerator
        self.cors = cors
        self.lifecycle = lifecycle
        self.policy = policy
    }

    /// Creates a configuration using the legacy convenience parameter list.
    ///
    /// - Parameters:
    ///   - path: The HTTP path served by Engine.IO.
    ///   - addTrailingSlash: Whether both `path` and `path/` should be accepted.
    ///   - destroyUpgrade: How long to keep unhandled upgrades alive.
    ///   - pingTimeout: How long to wait for the client to respond to a ping.
    ///   - pingInterval: How often the server sends heartbeat pings.
    ///   - upgradeTimeout: How long an upgrade attempt may remain in flight.
    ///   - maxHttpBufferSize: The maximum polling payload size accepted from the client.
    ///   - allowRequest: A legacy request admission hook. Return `false` to reject with `403 Forbidden`.
    ///   - transports: The transports that the server exposes.
    ///   - sessionIDGenerator: The generator used for new session identifiers.
    ///   - onOpen: Invoked when a session connects.
    ///   - onMessage: Invoked when a client payload is received.
    ///   - onClose: Invoked when a session closes. This legacy hook does not expose the close reason.
    ///   - onError: Invoked when the server emits an error.
    ///   - onEvent: Invoked for every lifecycle event.
    ///   - allowUpgrades: Whether polling clients may upgrade to WebSocket.
    ///   - initialPacket: An optional payload sent immediately after the open packet.
    ///   - cookie: An optional session cookie to set during polling handshakes.
    ///   - perMessageDeflate: WebSocket per-message deflate settings.
    ///   - httpCompression: HTTP response compression settings.
    ///   - cors: CORS behavior for HTTP responses.
    ///   - mapHandshakeError: An optional mapper that can override handshake failures.
    public init(
        path: String = "/engine.io",
        addTrailingSlash: Bool = true,
        destroyUpgrade: DestroyUpgrade = .after(timeout: .seconds(1)),
        pingTimeout: Duration = .seconds(20),
        pingInterval: Duration = .seconds(30),
        upgradeTimeout: Duration = .seconds(10),
        maxHttpBufferSize: UInt = 10_000,
        allowRequest: @escaping RequestAuthorizer = { _ in true },
        transports: Transport = [.polling, .websocket],
        sessionIDGenerator: @escaping SessionIDGenerator = {
            UUID().uuidString.filter { $0 != "-" }
        },
        onOpen: @escaping LifecycleHandler = { _ in },
        onMessage: @escaping MessageHandler = { _, _ in },
        onClose: @escaping LifecycleHandler = { _ in },
        onError: @escaping ErrorHandler = { _ in },
        onEvent: @escaping EventHandler = { _ in },
        allowUpgrades: Bool = true,
        initialPacket: EngineIOData? = nil,
        cookie: CookieConfiguration? = nil,
        perMessageDeflate: PerMessageDeflateConfiguration? = nil,
        httpCompression: HTTPCompressionConfiguration? = nil,
        cors: Cors = .static(.init(allowedOrigin: .all)),
        mapHandshakeError: Policy.HandshakeErrorMapper? = nil
    ) {
        self.init(
            routing: .init(path: path, allowsTrailingSlash: addTrailingSlash),
            heartbeat: .init(
                destroyUpgrade: destroyUpgrade,
                pingTimeout: pingTimeout,
                pingInterval: pingInterval,
                upgradeTimeout: upgradeTimeout
            ),
            transport: .init(
                transports: transports,
                allowUpgrades: allowUpgrades,
                maxPayload: maxHttpBufferSize,
                initialPacket: initialPacket,
                cookie: cookie,
                perMessageDeflate: perMessageDeflate,
                httpCompression: httpCompression
            ),
            sessionIDGenerator: sessionIDGenerator,
            cors: cors,
            lifecycle: .init(
                onEvent: onEvent,
                onConnect: onOpen,
                onMessage: onMessage,
                onDisconnect: { connection, _ in
                    await onClose(connection)
                },
                onError: onError
            ),
            policy: .init(
                requestAdmission: { request in
                    if try await allowRequest(request) {
                        return .allow
                    } else {
                        return .reject(.forbidden())
                    }
                },
                mapHandshakeError: mapHandshakeError
            )
        )
    }
}

extension ServerConfiguration {
    /// Route-matching settings for the Engine.IO endpoint.
    public struct Routing: Sendable {
        /// The path served by Engine.IO.
        public let path: String
        /// Whether both the base path and its trailing-slash variant are accepted.
        public let allowsTrailingSlash: Bool

        /// Creates route-matching settings.
        ///
        /// - Parameters:
        ///   - path: The HTTP path served by Engine.IO.
        ///   - allowsTrailingSlash: Whether both the base path and its trailing-slash variant are accepted.
        public init(
            path: String = "/engine.io",
            allowsTrailingSlash: Bool = true
        ) {
            self.path = path
            self.allowsTrailingSlash = allowsTrailingSlash
        }
    }

    /// Heartbeat and timeout settings.
    public struct Heartbeat: Sendable {
        /// How long to keep unhandled upgrade requests alive.
        public let destroyUpgrade: DestroyUpgrade
        /// How long to wait for the client to answer a ping before closing the session.
        public let pingTimeout: Duration
        /// How often the server sends heartbeat pings.
        public let pingInterval: Duration
        /// How long an upgrade attempt may remain in progress.
        public let upgradeTimeout: Duration

        /// Creates heartbeat settings.
        ///
        /// - Parameters:
        ///   - destroyUpgrade: How long to keep unhandled upgrade requests alive.
        ///   - pingTimeout: How long to wait for the client to answer a ping.
        ///   - pingInterval: How often the server sends heartbeat pings.
        ///   - upgradeTimeout: How long an upgrade attempt may remain in progress.
        public init(
            destroyUpgrade: DestroyUpgrade = .after(timeout: .seconds(1)),
            pingTimeout: Duration = .seconds(20),
            pingInterval: Duration = .seconds(30),
            upgradeTimeout: Duration = .seconds(10)
        ) {
            self.destroyUpgrade = destroyUpgrade
            self.pingTimeout = pingTimeout
            self.pingInterval = pingInterval
            self.upgradeTimeout = upgradeTimeout
        }
    }

    /// Transport-specific settings for the Engine.IO server.
    public struct TransportConfiguration: Sendable {
        /// The transports exposed by the server.
        public let transports: Transport
        /// Whether polling sessions may upgrade to WebSocket.
        public let allowUpgrades: Bool
        /// The maximum payload size accepted over polling transports.
        public let maxPayload: UInt
        /// An optional payload sent immediately after the open packet.
        public let initialPacket: EngineIOData?
        /// An optional session cookie to set during polling handshakes.
        public let cookie: CookieConfiguration?
        /// WebSocket per-message deflate settings.
        public let perMessageDeflate: PerMessageDeflateConfiguration?
        /// HTTP response compression settings.
        public let httpCompression: HTTPCompressionConfiguration?

        /// Creates transport settings.
        ///
        /// - Parameters:
        ///   - transports: The transports exposed by the server.
        ///   - allowUpgrades: Whether polling sessions may upgrade to WebSocket.
        ///   - maxPayload: The maximum polling payload size accepted from the client.
        ///   - initialPacket: An optional payload sent immediately after the open packet.
        ///   - cookie: An optional session cookie to set during polling handshakes.
        ///   - perMessageDeflate: WebSocket per-message deflate settings.
        ///   - httpCompression: HTTP response compression settings.
        public init(
            transports: Transport = [.polling, .websocket],
            allowUpgrades: Bool = true,
            maxPayload: UInt = 10_000,
            initialPacket: EngineIOData? = nil,
            cookie: CookieConfiguration? = nil,
            perMessageDeflate: PerMessageDeflateConfiguration? = nil,
            httpCompression: HTTPCompressionConfiguration? = nil
        ) {
            self.transports = transports
            self.allowUpgrades = allowUpgrades
            self.maxPayload = maxPayload
            self.initialPacket = initialPacket
            self.cookie = cookie
            self.perMessageDeflate = perMessageDeflate
            self.httpCompression = httpCompression
        }
    }

    /// Event handlers invoked as the server processes Engine.IO sessions.
    public struct Lifecycle: Sendable {
        /// Handles all emitted Engine.IO events.
        public typealias EventHandler = @Sendable (EngineIOEvent) async -> Void
        /// Handles newly connected sessions.
        public typealias ConnectHandler = @Sendable (EngineIOConnection) async -> Void
        /// Handles inbound application payloads.
        public typealias MessageHandler = @Sendable (EngineIOConnection, EngineIOData) async -> Void
        /// Handles session disconnects.
        public typealias DisconnectHandler = @Sendable (EngineIOConnection, EngineIOCloseReason) async -> Void
        /// Handles server errors.
        public typealias ErrorHandler = @Sendable (EngineIOErrorContext) async -> Void

        /// Invoked for every emitted Engine.IO event.
        public let onEvent: EventHandler
        private let onConnect: ConnectHandler
        private let onMessage: MessageHandler
        private let onDisconnect: DisconnectHandler
        private let onError: ErrorHandler

        /// Creates lifecycle handlers.
        ///
        /// - Parameters:
        ///   - onEvent: Invoked for every emitted Engine.IO event.
        ///   - onConnect: Invoked when a session connects.
        ///   - onMessage: Invoked when a client payload is received.
        ///   - onDisconnect: Invoked when a session closes.
        ///   - onError: Invoked when the server emits an error.
        public init(
            onEvent: @escaping EventHandler = { _ in },
            onConnect: @escaping ConnectHandler = { _ in },
            onMessage: @escaping MessageHandler = { _, _ in },
            onDisconnect: @escaping DisconnectHandler = { _, _ in },
            onError: @escaping ErrorHandler = { _ in }
        ) {
            self.onEvent = onEvent
            self.onConnect = onConnect
            self.onMessage = onMessage
            self.onDisconnect = onDisconnect
            self.onError = onError
        }

        func handle(_ event: EngineIOEvent) async {
            await self.onEvent(event)
            switch event {
            case .connected(let connection):
                await self.onConnect(connection)
            case .received(let connection, let data):
                await self.onMessage(connection, data)
            case .closed(let connection, let reason):
                await self.onDisconnect(connection, reason)
            case .error(let context):
                await self.onError(context)
            }
        }
    }

    /// Policy hooks that can admit requests and map handshake failures.
    public struct Policy: Sendable {
        /// The result of evaluating whether a request should be admitted.
        public enum RequestAdmission: Sendable {
            /// Accept the request.
            case allow
            /// Reject the request with a custom rejection payload.
            case reject(EngineIORejection)
        }

        /// Decides whether a request should be admitted.
        public typealias AdmissionHandler = @Sendable (HTTPRequest) async throws -> RequestAdmission
        /// Maps a handshake error to a custom rejection.
        public typealias HandshakeErrorMapper = @Sendable (EngineIOErrorContext) async -> EngineIORejection?

        /// The handler used to admit or reject requests.
        public let requestAdmission: AdmissionHandler
        /// An optional mapper used to override handshake failures.
        public let mapHandshakeError: HandshakeErrorMapper?

        /// Creates policy handlers.
        ///
        /// - Parameters:
        ///   - requestAdmission: The handler used to admit or reject requests.
        ///   - mapHandshakeError: An optional mapper used to override handshake failures.
        public init(
            requestAdmission: @escaping AdmissionHandler = { _ in .allow },
            mapHandshakeError: HandshakeErrorMapper? = nil
        ) {
            self.requestAdmission = requestAdmission
            self.mapHandshakeError = mapHandshakeError
        }
    }
}

extension ServerConfiguration {
    /// Controls how long unhandled upgrade requests remain open.
    public enum DestroyUpgrade: Sendable {
        /// Do not timeout on unhandled upgrade requests
        case no
        /// Timeout after a specific duration unhandled upgrade requests
        case after(timeout: Duration)
    }
}

extension ServerConfiguration {
    /// Cookie settings used for polling handshakes.
    public struct CookieConfiguration: Sendable {
        /// SameSite values supported by Engine.IO cookies.
        public enum SameSite: String, Sendable {
            /// Uses the `Lax` SameSite policy.
            case lax = "Lax"
            /// Uses the `Secure` SameSite policy.
            case secure = "Secure"
            /// Uses the `None` SameSite policy.
            case none = "None"

            fileprivate var hummingbird: Cookie.SameSite {
                switch self {
                case .lax:
                    return Cookie.SameSite(rawValue: "Lax")!
                case .secure:
                    return Cookie.SameSite(rawValue: "Strict")
                        ?? Cookie.SameSite(rawValue: "Secure")!
                case .none:
                    return Cookie.SameSite(rawValue: "None")!
                }
            }
        }

        /// The cookie name.
        public let name: String
        /// The cookie path attribute.
        public let path: String?
        /// The cookie domain attribute.
        public let domain: String?
        /// Whether the cookie should only be sent over secure connections.
        public let secure: Bool
        /// Whether the cookie should be hidden from client-side scripts.
        public let httpOnly: Bool
        /// The SameSite policy applied to the cookie.
        public let sameSite: SameSite?
        /// The cookie `Max-Age` in seconds.
        public let maxAge: Int?

        /// Creates cookie settings.
        ///
        /// - Parameters:
        ///   - name: The cookie name.
        ///   - path: The cookie path attribute.
        ///   - domain: The cookie domain attribute.
        ///   - secure: Whether the cookie should only be sent over secure connections.
        ///   - httpOnly: Whether the cookie should be hidden from client-side scripts.
        ///   - sameSite: The SameSite policy applied to the cookie.
        ///   - maxAge: The cookie `Max-Age` in seconds.
        public init(
            name: String = "io",
            path: String? = "/",
            domain: String? = nil,
            secure: Bool = false,
            httpOnly: Bool = true,
            sameSite: SameSite? = nil,
            maxAge: Int? = nil
        ) {
            self.name = name
            self.path = path
            self.domain = domain
            self.secure = secure
            self.httpOnly = httpOnly
            self.sameSite = sameSite
            self.maxAge = maxAge
        }

        func makeCookie(with sid: String) -> Cookie {
            if let sameSite {
                return .init(
                    name: name,
                    value: sid,
                    maxAge: maxAge,
                    domain: domain,
                    path: path,
                    secure: secure,
                    httpOnly: httpOnly,
                    sameSite: sameSite.hummingbird
                )
            } else {
                return .init(
                    name: name,
                    value: sid,
                    maxAge: maxAge,
                    domain: domain,
                    path: path,
                    secure: secure,
                    httpOnly: httpOnly
                )
            }
        }
    }

    /// WebSocket per-message deflate settings.
    public struct PerMessageDeflateConfiguration: Sendable {
        /// The advertised maximum client window size.
        public let clientMaxWindow: Int?
        /// Whether the client must reset compression context between frames.
        public let clientNoContextTakeover: Bool
        /// The advertised maximum server window size.
        public let serverMaxWindow: Int?
        /// Whether the server resets compression context between frames.
        public let serverNoContextTakeover: Bool
        /// The zlib compression level.
        public let compressionLevel: Int?
        /// The zlib memory level.
        public let memoryLevel: Int?
        /// The largest decompressed frame accepted by the server.
        public let maxDecompressedFrameSize: Int
        /// The minimum frame size that should be compressed.
        public let minFrameSizeToCompress: Int

        /// Creates per-message deflate settings.
        ///
        /// - Parameters:
        ///   - clientMaxWindow: The advertised maximum client window size.
        ///   - clientNoContextTakeover: Whether the client must reset compression context between frames.
        ///   - serverMaxWindow: The advertised maximum server window size.
        ///   - serverNoContextTakeover: Whether the server resets compression context between frames.
        ///   - compressionLevel: The zlib compression level.
        ///   - memoryLevel: The zlib memory level.
        ///   - maxDecompressedFrameSize: The largest decompressed frame accepted by the server.
        ///   - minFrameSizeToCompress: The minimum frame size that should be compressed.
        public init(
            clientMaxWindow: Int? = nil,
            clientNoContextTakeover: Bool = false,
            serverMaxWindow: Int? = nil,
            serverNoContextTakeover: Bool = false,
            compressionLevel: Int? = nil,
            memoryLevel: Int? = nil,
            maxDecompressedFrameSize: Int = 1 << 14,
            minFrameSizeToCompress: Int = 256
        ) {
            self.clientMaxWindow = clientMaxWindow
            self.clientNoContextTakeover = clientNoContextTakeover
            self.serverMaxWindow = serverMaxWindow
            self.serverNoContextTakeover = serverNoContextTakeover
            self.compressionLevel = compressionLevel
            self.memoryLevel = memoryLevel
            self.maxDecompressedFrameSize = maxDecompressedFrameSize
            self.minFrameSizeToCompress = minFrameSizeToCompress
        }
    }

    /// HTTP response compression settings.
    public struct HTTPCompressionConfiguration: Sendable {
        /// The minimum uncompressed response size that should trigger compression.
        public let minimumByteCount: Int

        /// Creates HTTP response compression settings.
        ///
        /// - Parameter minimumByteCount: The minimum uncompressed response size that should trigger compression.
        public init(minimumByteCount: Int = 1024) {
            self.minimumByteCount = minimumByteCount
        }
    }
}

/// The transport mechanisms supported by Engine.IO.
public struct Transport: OptionSet, Sendable, Encodable {
    /// HTTP long-polling transport.
    public static let polling: Transport = .init(rawValue: 1 << 0)
    /// WebSocket transport.
    public static let websocket: Transport = .init(rawValue: 1 << 1)

    /// The raw option-set bitmask.
    public let rawValue: Int

    /// Creates a transport option set from a raw value.
    ///
    /// - Parameter rawValue: A bitmask containing supported transports.
    public init(rawValue: Int) {
        precondition(rawValue < (1 << 2), "Unknown transport specified!")
        self.rawValue = rawValue
    }

    init?(name: some StringProtocol) {
        switch name {
        case "polling":
            self = .polling
        case "websocket":
            self = .websocket
        default:
            return nil
        }
    }

    /// Encodes the enabled transports as their Engine.IO transport names.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        if contains(.polling) {
            try container.encode("polling")
        }
        if contains(.websocket) {
            try container.encode("websocket")
        }
    }
}

extension ServerConfiguration {
    /// CORS behavior for HTTP requests served by Engine.IO.
    public enum Cors: Sendable {
        /// Always uses a fixed CORS configuration.
        case `static`(CorsConfiguration)
        /// Computes CORS configuration dynamically for each request.
        case dynamic(@Sendable (HTTPRequest) async throws -> CorsConfiguration)
    }

    /// A concrete CORS configuration.
    public struct CorsConfiguration: Sendable {
        /// Which origins are allowed.
        public let allowedOrigin: AllowOrigin
        /// Which HTTP methods are allowed.
        public let allowedMethods: Set<HTTPRequest.Method>
        /// Which request headers are allowed.
        public let allowedHeaders: [HTTPField.Name]
        /// Whether credentialed requests are allowed.
        public let allowCredentials: Bool
        /// The `Access-Control-Max-Age` value in seconds.
        public let cacheExpiration: Int?
        /// Headers exposed to the browser.
        public let exposedHeaders: [HTTPField.Name]?

        /// Creates a CORS configuration.
        ///
        /// - Parameters:
        ///   - allowedOrigin: Which origins are allowed.
        ///   - allowedMethods: Which HTTP methods are allowed.
        ///   - allowedHeaders: Which request headers are allowed.
        ///   - allowCredentials: Whether credentialed requests are allowed.
        ///   - cacheExpiration: The `Access-Control-Max-Age` value in seconds.
        ///   - exposedHeaders: Headers exposed to the browser.
        public init(
            allowedOrigin: AllowOrigin = .originBased,
            allowedMethods: Set<HTTPRequest.Method> = [.get, .head, .put, .patch, .post, .delete],
            allowedHeaders: [HTTPField.Name] = [],
            allowCredentials: Bool = false,
            cacheExpiration: Int? = 600,
            exposedHeaders: [HTTPField.Name]? = nil
        ) {
            self.allowedOrigin = allowedOrigin
            self.allowedMethods = allowedMethods
            self.allowedHeaders = allowedHeaders
            self.allowCredentials = allowCredentials
            self.cacheExpiration = cacheExpiration
            self.exposedHeaders = exposedHeaders
        }
    }
}

extension ServerConfiguration.CorsConfiguration {
    /// Strategies for resolving the `Access-Control-Allow-Origin` value.
    public enum AllowOrigin: Sendable {
        /// Disallow any origin.
        case none
        /// Uses value of the origin header in the request.
        case originBased
        /// Uses wildcard to allow any origin.
        case all
        /// A list of allowable origins.
        case oneOf([String])
        /// Dynamic origin based on current request origin
        case dynamic(@Sendable (String) async throws -> String)
        /// Uses custom string provided as an associated value.
        case custom(String)
    }
}

extension ServerConfiguration {
    var path: String { self.routing.path }
    var addTrailingSlash: Bool { self.routing.allowsTrailingSlash }
    var destroyUpgrade: DestroyUpgrade { self.heartbeat.destroyUpgrade }
    var pingTimeout: Duration { self.heartbeat.pingTimeout }
    var pingInterval: Duration { self.heartbeat.pingInterval }
    var upgradeTimeout: Duration { self.heartbeat.upgradeTimeout }
    var maxHttpBufferSize: UInt { self.transport.maxPayload }
    var transports: Transport { self.transport.transports }
    var allowUpgrades: Bool { self.transport.allowUpgrades }
    var initialPacket: EngineIOData? { self.transport.initialPacket }
    var cookie: CookieConfiguration? { self.transport.cookie }
    var perMessageDeflate: PerMessageDeflateConfiguration? { self.transport.perMessageDeflate }
    var httpCompression: HTTPCompressionConfiguration? { self.transport.httpCompression }

    var supportedPaths: [String] {
        let trimmed: String
        if path == "/" {
            trimmed = "/"
        } else {
            trimmed = path.split(separator: "/", omittingEmptySubsequences: true).joined(separator: "/")
        }
        if trimmed == "/" {
            return ["/"]
        }
        let normalized = trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
        guard addTrailingSlash else {
            return [normalized]
        }
        let slash = normalized.hasSuffix("/") ? normalized : "\(normalized)/"
        return normalized == slash ? [normalized] : [normalized, slash]
    }

    func supports(path: String) -> Bool {
        supportedPaths.contains(path)
    }

    func emit(_ event: EngineIOEvent) async {
        await self.lifecycle.handle(event)
    }

    func mapHandshakeRejection(
        _ rejection: EngineIORejection,
        for context: EngineIOErrorContext
    ) async -> EngineIORejection {
        guard let mapper = self.policy.mapHandshakeError else {
            return rejection
        }
        return await mapper(context) ?? rejection
    }

    func corsConfiguration(for request: HTTPRequest) async throws -> CorsConfiguration {
        switch cors {
        case .static(let configuration):
            return configuration
        case .dynamic(let provider):
            return try await provider(request)
        }
    }
}

extension ServerConfiguration.CorsConfiguration {
    func allowOriginValue(for request: HTTPRequest) async throws -> String? {
        let origin = request.headerFields[.origin]
        switch allowedOrigin {
        case .none:
            return nil
        case .originBased:
            guard origin != "null" else { return nil }
            return origin
        case .all:
            return "*"
        case .oneOf(let allowedOrigins):
            guard let origin, allowedOrigins.contains(origin) else { return nil }
            return origin
        case .dynamic(let provider):
            guard let origin else { return nil }
            return try await provider(origin)
        case .custom(let value):
            return value
        }
    }

    var shouldVaryOnOrigin: Bool {
        switch allowedOrigin {
        case .originBased, .oneOf, .dynamic:
            return true
        case .none, .all, .custom:
            return false
        }
    }
}
