import Testing
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Hummingbird
import HummingbirdTesting
import HummingbirdWSCompression
import HummingbirdWSTesting
@testable import EngineIO

private func makeRequest(path: String = "/engine.io") -> HTTPRequest {
    .init(method: .get, scheme: nil, authority: nil, path: path, headerFields: [:])
}

private func waitUntil(
    timeout: Duration = .seconds(1),
    _ condition: @escaping @Sendable () async -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() {
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Timed out waiting for condition")
}

private func expectInvalidPacket(
    _ expectedMessage: String,
    _ operation: () throws -> Void
) {
    do {
        try operation()
        Issue.record("Expected packet decoding to fail")
    } catch let PacketDecodingError.invalidPacket(message) {
        #expect(message == expectedMessage)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

private func expectBadRequest(
    _ expectedMessage: String,
    _ operation: () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("Expected session operation to fail")
    } catch let error as SessionError {
        #expect(error == .badRequest(expectedMessage))
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

private struct ClosedEvent: Sendable, Equatable {
    let sid: String
    let reason: EngineIOCloseReason
}

private struct ErrorEvent: Sendable, Equatable {
    let phase: EngineIOErrorContext.Phase
    let kind: EngineIOErrorContext.Kind
    let message: String
}

private struct OpenPacketPayload: Decodable {
    let sid: String
    let upgrades: [String]
    let pingInterval: Int
    let pingTimeout: Int
    let maxPayload: Int
}

@Test func encodesOpenPacketForPolling() throws {
    let configuration = ServerConfiguration(
        pingTimeout: .milliseconds(200),
        pingInterval: .milliseconds(300),
        maxHttpBufferSize: 1_000_000,
        sessionIDGenerator: { "abc123" }
    )
    let packet = EngineIOPacket.open(.init(sid: "abc123", configuration: configuration, transport: .polling))
    let encoded = try packet.encodeForPolling()

    #expect(encoded.first == "0")
    let payload = Data(encoded.dropFirst().utf8)
    let openPacket = try JSONDecoder().decode(OpenPacketPayload.self, from: payload)
    #expect(openPacket.sid == "abc123")
    #expect(openPacket.pingInterval == 300)
    #expect(openPacket.pingTimeout == 200)
    #expect(openPacket.maxPayload == 1_000_000)
    #expect(openPacket.upgrades == ["websocket"])
}

@Test func disablesAdvertisedTransportUpgrades() throws {
    let configuration = ServerConfiguration(
        sessionIDGenerator: { "abc123" },
        allowUpgrades: false
    )
    let packet = EngineIOPacket.open(.init(sid: "abc123", configuration: configuration, transport: .polling))
    let encoded = try packet.encodeForPolling()

    let payload = Data(encoded.dropFirst().utf8)
    let openPacket = try JSONDecoder().decode(OpenPacketPayload.self, from: payload)
    #expect(openPacket.upgrades.isEmpty)
}

@Test func decodesPollingPayloadWithTextAndBinaryMessages() throws {
    let payload = ByteBuffer(string: "4hello\u{1e}bAQID")
    let packets = try EngineIOPacket.decodePollingPayload(payload)

    #expect(packets.count == 2)
    #expect(packets[0] == EngineIOPacket.message(.text("hello")))
    #expect(packets[1] == EngineIOPacket.message(.binary(.init(bytes: [0x01, 0x02, 0x03]))))
}

@Test func roundTripsBinaryPollingPacket() throws {
    let packet = EngineIOPacket.message(.binary(.init(bytes: [0x01, 0x02, 0x03])))
    let encoded = try packet.encodeForPolling()
    let decoded = try EngineIOPacket.decodePollingPayload(ByteBuffer(string: encoded))

    #expect(decoded == [packet])
}

@Test func rejectsInvalidPollingBase64Payload() {
    expectInvalidPacket("Invalid base64 payload") {
        _ = try EngineIOPacket.decodePollingPacket("b%%%")
    }
}

@Test func rejectsUnknownPacketType() {
    expectInvalidPacket("Unknown packet type") {
        _ = try EngineIOPacket.decodeTextPacket("9invalid")
    }
}

@Test func rejectsClientSentOpenPacket() {
    expectInvalidPacket("Client cannot send open packets") {
        _ = try EngineIOPacket.decodeTextPacket("0{\"sid\":\"abc123\"}")
    }
}

@Test func duplicatePollRequestClosesSession() async throws {
    let store = SessionStore(configuration: .init(
        pingTimeout: .seconds(10),
        pingInterval: .seconds(10),
        sessionIDGenerator: { "polling-session" }
    ))
    let handshake = try #require(await store.createPollingSession(request: makeRequest()))
    let firstPoll = Task {
        try await store.poll(sid: handshake.connection.sid)
    }
    try await waitUntil {
        await store.hasPendingPollRequest(sid: handshake.connection.sid)
    }

    await expectBadRequest("A polling GET request is already active") {
        _ = try await store.poll(sid: handshake.connection.sid)
    }

    let resumedPackets = try await firstPoll.value
    #expect(resumedPackets == [.close])
}

@Test func duplicatePollPostClosesSession() async throws {
    let store = SessionStore(configuration: .init(
        pingTimeout: .seconds(10),
        pingInterval: .seconds(10),
        sessionIDGenerator: { "post-session" }
    ))
    let handshake = try #require(await store.createPollingSession(request: makeRequest()))

    try await store.beginPollingPost(sid: handshake.connection.sid)
    await expectBadRequest("A polling POST request is already active") {
        try await store.beginPollingPost(sid: handshake.connection.sid)
    }
    await expectBadRequest("Unknown session id") {
        _ = try await store.poll(sid: handshake.connection.sid)
    }
}

@Test func pollingCloseWithPendingPollReturnsNoopAndClosesSession() async throws {
    let store = SessionStore(configuration: .init(
        pingTimeout: .seconds(10),
        pingInterval: .seconds(10),
        sessionIDGenerator: { "close-pending-session" }
    ))
    let handshake = try #require(await store.createPollingSession(request: makeRequest()))
    let pendingPoll = Task {
        try await store.poll(sid: handshake.connection.sid)
    }
    try await waitUntil {
        await store.hasPendingPollRequest(sid: handshake.connection.sid)
    }

    let receivedMessages = try await store.processIncomingPacket(sid: handshake.connection.sid, packet: .close, via: .polling)
    #expect(receivedMessages.isEmpty)

    let resumedPackets = try await pendingPoll.value
    #expect(resumedPackets == [.noop])
    await expectBadRequest("Unknown session id") {
        _ = try await store.poll(sid: handshake.connection.sid)
    }
}

@Test func pollingCloseWithoutPendingPollDrainsNoopAndClosesSession() async throws {
    let store = SessionStore(configuration: .init(
        pingTimeout: .seconds(10),
        pingInterval: .seconds(10),
        sessionIDGenerator: { "close-drain-session" }
    ))
    let handshake = try #require(await store.createPollingSession(request: makeRequest()))

    let receivedMessages = try await store.processIncomingPacket(sid: handshake.connection.sid, packet: .close, via: .polling)
    #expect(receivedMessages.isEmpty)

    let drainedPackets = try await store.poll(sid: handshake.connection.sid)
    #expect(drainedPackets == [.noop])
    await expectBadRequest("Unknown session id") {
        _ = try await store.poll(sid: handshake.connection.sid)
    }
}

@Test func probePingOutsideUpgradeIsRejected() async throws {
    let store = SessionStore(configuration: .init(
        pingTimeout: .seconds(10),
        pingInterval: .seconds(10),
        sessionIDGenerator: { "probe-reject-session" }
    ))
    let handshake = try #require(await store.createPollingSession(request: makeRequest()))

    await expectBadRequest("WebSocket session is not active") {
        _ = try await store.processIncomingPacket(sid: handshake.connection.sid, packet: .ping("probe"), via: .websocket)
    }
}

@Test func websocketUpgradePacketBeforeProbeIsRejected() async throws {
    let store = SessionStore(configuration: .init(
        pingTimeout: .seconds(10),
        pingInterval: .seconds(10),
        sessionIDGenerator: { "upgrade-reject-session" }
    ))
    let handshake = try #require(await store.createPollingSession(request: makeRequest()))
    let (_, continuation) = AsyncStream.makeStream(of: EngineIOPacket.self)
    await store.attachWebSocketUpgrade(sid: handshake.connection.sid, continuation: continuation)

    await expectBadRequest("WebSocket upgrade is incomplete") {
        _ = try await store.processIncomingPacket(sid: handshake.connection.sid, packet: .upgrade, via: .websocket)
    }
}

@Test func websocketUpgradeRequiresProbeBeforeUpgradePacket() async throws {
    let store = SessionStore(configuration: .init(
        pingTimeout: .seconds(10),
        pingInterval: .seconds(10),
        sessionIDGenerator: { "upgrade-session" }
    ))
    let handshake = try #require(await store.createPollingSession(request: makeRequest()))
    let pendingPoll = Task {
        try await store.poll(sid: handshake.connection.sid)
    }
    try await waitUntil {
        await store.hasPendingPollRequest(sid: handshake.connection.sid)
    }

    let (stream, continuation) = AsyncStream.makeStream(of: EngineIOPacket.self)
    await store.attachWebSocketUpgrade(sid: handshake.connection.sid, continuation: continuation)

    let pendingPackets = try await pendingPoll.value
    #expect(pendingPackets == [.noop])

    let probeMessages = try await store.processIncomingPacket(sid: handshake.connection.sid, packet: .ping("probe"), via: .websocket)
    #expect(probeMessages.isEmpty)

    var iterator = stream.makeAsyncIterator()
    let probeResponse = await iterator.next()
    #expect(probeResponse == .pong("probe"))

    await store.send(.text("queued"), to: handshake.connection.sid)
    _ = try await store.processIncomingPacket(sid: handshake.connection.sid, packet: .upgrade, via: .websocket)

    let upgradedPacket = await iterator.next()
    #expect(upgradedPacket == .message(.text("queued")))
}

@Test func upgradeTimeoutClosesIncompleteUpgrade() async throws {
    let store = SessionStore(configuration: .init(
        pingTimeout: .seconds(10),
        pingInterval: .seconds(10),
        upgradeTimeout: .milliseconds(50),
        sessionIDGenerator: { "upgrade-timeout-session" }
    ))
    let handshake = try #require(await store.createPollingSession(request: makeRequest()))
    let plan = await store.prepareWebSocketConnection(request: makeRequest(), sid: handshake.connection.sid)
    #expect(plan == .upgradeExisting(handshake.connection.sid))

    let (stream, continuation) = AsyncStream.makeStream(of: EngineIOPacket.self)
    var iterator = stream.makeAsyncIterator()
    await store.attachWebSocketUpgrade(sid: handshake.connection.sid, continuation: continuation)

    try await Task.sleep(for: .milliseconds(150))

    let closePacket = await iterator.next()
    #expect(closePacket == .close)

    await expectBadRequest("WebSocket session is not active") {
        _ = try await store.processIncomingPacket(sid: handshake.connection.sid, packet: .upgrade, via: .websocket)
    }
}

@Test func destroyUpgradeTimeoutReleasesReservedUpgrade() async throws {
    let store = SessionStore(configuration: .init(
        destroyUpgrade: .after(timeout: .milliseconds(50)),
        pingTimeout: .seconds(10),
        pingInterval: .seconds(10),
        sessionIDGenerator: { "destroy-upgrade-release" }
    ))
    let handshake = try #require(await store.createPollingSession(request: makeRequest()))
    let plan = await store.prepareWebSocketConnection(request: makeRequest(), sid: handshake.connection.sid)
    #expect(plan == .upgradeExisting(handshake.connection.sid))

    await expectBadRequest("Polling is no longer available for this session") {
        try await store.beginPollingPost(sid: handshake.connection.sid)
    }

    try await Task.sleep(for: .milliseconds(150))
    try await store.beginPollingPost(sid: handshake.connection.sid)
    await store.finishPollingPost(sid: handshake.connection.sid)
}

@Test func destroyUpgradeNoLeavesReservedUpgradeOpen() async throws {
    let store = SessionStore(configuration: .init(
        destroyUpgrade: .no,
        pingTimeout: .seconds(10),
        pingInterval: .seconds(10),
        sessionIDGenerator: { "destroy-upgrade-no" }
    ))
    let handshake = try #require(await store.createPollingSession(request: makeRequest()))
    let plan = await store.prepareWebSocketConnection(request: makeRequest(), sid: handshake.connection.sid)
    #expect(plan == .upgradeExisting(handshake.connection.sid))

    try await Task.sleep(for: .milliseconds(150))

    await expectBadRequest("Polling is no longer available for this session") {
        try await store.beginPollingPost(sid: handshake.connection.sid)
    }
}

@Test func connectionCarriesRequestAndCanBeClosed() async throws {
    let request = makeRequest(path: "/engine.io")
    let store = SessionStore(configuration: .init(
        pingTimeout: .seconds(10),
        pingInterval: .seconds(10),
        sessionIDGenerator: { "request-session" }
    ))
    let handshake = try #require(await store.createPollingSession(request: request))

    #expect(handshake.connection.request.path == "/engine.io")
    await handshake.connection.close()

    await expectBadRequest("Unknown session id") {
        _ = try await store.poll(sid: handshake.connection.sid)
    }
}

@Test func serverInvokesLifecycleHooks() async throws {
    actor Recorder {
        var opened: [String] = []
        var closed: [ClosedEvent] = []

        func recordOpen(_ sid: String) {
            opened.append(sid)
        }

        func recordClose(_ sid: String, reason: EngineIOCloseReason) {
            closed.append(.init(sid: sid, reason: reason))
        }
    }

    let recorder = Recorder()
    let server = Server(port: 8080, configuration: .init(
        sessionIDGenerator: { "lifecycle-session" },
        lifecycle: .init(
            onConnect: { connection in
                await recorder.recordOpen(connection.sid)
            },
            onDisconnect: { connection, reason in
                await recorder.recordClose(connection.sid, reason: reason)
            }
        )
    ))

    try await server.application.test(TestingSetup.router) { client in
        let response = try await client.execute(uri: "/engine.io?EIO=4&transport=polling", method: .get)
        #expect(response.status == .ok)

        _ = try await client.execute(
            uri: "/engine.io?EIO=4&transport=polling&sid=lifecycle-session",
            method: .post,
            headers: [.contentType: "text/plain; charset=UTF-8"],
            body: .init(string: "1")
        )

        let drain = try await client.execute(
            uri: "/engine.io?EIO=4&transport=polling&sid=lifecycle-session",
            method: .get
        )
        #expect(drain.status == .ok)
    }

    try await waitUntil {
        await recorder.closed == [.init(sid: "lifecycle-session", reason: .clientInitiated)]
    }

    #expect(await recorder.opened == ["lifecycle-session"])
    #expect(await recorder.closed == [.init(sid: "lifecycle-session", reason: .clientInitiated)])
}

@Test func serverExposesClientsAndCanCloseAllSessions() async throws {
    actor Recorder {
        var closed: [ClosedEvent] = []

        func recordClose(_ sid: String, reason: EngineIOCloseReason) {
            closed.append(.init(sid: sid, reason: reason))
        }
    }

    let recorder = Recorder()
    let server = Server(port: 8080, configuration: .init(
        sessionIDGenerator: { "managed-session" },
        lifecycle: .init(
            onDisconnect: { connection, reason in
                await recorder.recordClose(connection.sid, reason: reason)
            }
        )
    ))

    try await server.application.test(TestingSetup.router) { client in
        let response = try await client.execute(uri: "/engine.io?EIO=4&transport=polling", method: .get)
        #expect(response.status == .ok)

        #expect(await server.clientsCount == 1)
        let clients = await server.clients
        #expect(clients.keys.sorted() == ["managed-session"])
        #expect(clients["managed-session"]?.sid == "managed-session")

        await server.close()

        #expect(await server.clientsCount == 0)
        #expect((await server.clients).isEmpty)

        let closedResponse = try await client.execute(uri: "/engine.io?EIO=4&transport=polling", method: .get)
        #expect(closedResponse.status == .serviceUnavailable)
        #expect(String(buffer: closedResponse.body) == "Server is closed")
    }

    try await waitUntil {
        await recorder.closed == [.init(sid: "managed-session", reason: .serverInitiated)]
    }
}

@Test func serverSupportsTrailingSlashByDefault() async throws {
    let server = Server(port: 8080, configuration: .init(sessionIDGenerator: { "slash-enabled" }))

    try await server.application.test(TestingSetup.router) { client in
        let response = try await client.execute(uri: "/engine.io/?EIO=4&transport=polling", method: HTTPRequest.Method.get)
        #expect(response.status == .ok)
    }
}

@Test func serverCanDisableTrailingSlashSupport() async throws {
    let server = Server(port: 8080, configuration: .init(
        addTrailingSlash: false,
        sessionIDGenerator: { "slash-disabled" }
    ))

    try await server.application.test(TestingSetup.router) { client in
        let response = try await client.execute(uri: "/engine.io?EIO=4&transport=polling", method: HTTPRequest.Method.get)
        #expect(response.status == .ok)

        let trailingSlashResponse = try await client.execute(uri: "/engine.io/?EIO=4&transport=polling", method: HTTPRequest.Method.get)
        #expect(trailingSlashResponse.status == .notFound)
    }
}

@Test func serverRejectsHandshakeWhenAllowRequestReturnsFalse() async throws {
    let server = Server(port: 8080, configuration: .init(
        allowRequest: { _ in false }
    ))

    try await server.application.test(TestingSetup.router) { client in
        let response = try await client.execute(uri: "/engine.io?EIO=4&transport=polling", method: HTTPRequest.Method.get)
        #expect(response.status == .forbidden)
        #expect(String(buffer: response.body) == "Forbidden")
    }
}

@Test func serverIncludesInitialPacketInPollingHandshake() async throws {
    let server = Server(port: 8080, configuration: .init(
        sessionIDGenerator: { "initial-polling" },
        initialPacket: .text("hello")
    ))

    try await server.application.test(TestingSetup.router) { client in
        let response = try await client.execute(uri: "/engine.io?EIO=4&transport=polling", method: .get)
        #expect(response.status == .ok)
        #expect(String(buffer: response.body).contains("\u{1e}4hello"))
    }
}

@Test func serverAddsCookieToPollingHandshake() async throws {
    let server = Server(port: 8080, configuration: .init(
        sessionIDGenerator: { "cookie-session" },
        cookie: .init(
            name: "engine",
            path: "/engine.io",
            domain: "example.com",
            secure: true,
            sameSite: ServerConfiguration.CookieConfiguration.SameSite.none,
            maxAge: 60
        )
    ))

    try await server.application.test(TestingSetup.router) { client in
        let response = try await client.execute(uri: "/engine.io?EIO=4&transport=polling", method: .get)
        #expect(response.status == .ok)
        let setCookies = response.headers[values: .setCookie]
        #expect(setCookies.count == 1)
        let cookie = try #require(setCookies.first)
        #expect(cookie.contains("engine=cookie-session"))
        #expect(cookie.contains("Path=/engine.io"))
        #expect(cookie.contains("Domain=example.com"))
        #expect(cookie.contains("Max-Age=60"))
        #expect(cookie.contains("Secure"))
        #expect(cookie.contains("HttpOnly"))
        #expect(cookie.contains("SameSite=None"))
    }
}

@Test func serverDoesNotReemitCookieOnSubsequentPollingRequests() async throws {
    let server = Server(port: 8080, configuration: .init(
        sessionIDGenerator: { "cookie-drain-session" },
        cookie: .init()
    ))

    try await server.application.test(TestingSetup.router) { client in
        let handshake = try await client.execute(uri: "/engine.io?EIO=4&transport=polling", method: .get)
        #expect(handshake.headers[values: .setCookie].count == 1)

        let followUp = try await client.execute(
            uri: "/engine.io?EIO=4&transport=polling&sid=cookie-drain-session",
            method: .post,
            headers: [.contentType: "text/plain; charset=UTF-8"],
            body: .init(string: "1")
        )
        #expect(followUp.headers[values: .setCookie].isEmpty)
    }
}

@Test func serverAppliesHTTPCompressionToPollingResponses() async throws {
    let server = Server(port: 8080, configuration: .init(
        sessionIDGenerator: { "compression-session" },
        initialPacket: .text(String(repeating: "a", count: 2_000)),
        httpCompression: .init(minimumByteCount: 0)
    ))

    let headers: HTTPFields = [.acceptEncoding: "gzip"]
    try await server.application.test(TestingSetup.router) { client in
        let response = try await client.execute(
            uri: "/engine.io?EIO=4&transport=polling",
            method: .get,
            headers: headers
        )
        #expect(response.status == .ok)
        #expect(response.headers[.contentEncoding] == "gzip")
        #expect(response.headers[.transferEncoding] == "chunked")
    }
}

@Test func serverSkipsHTTPCompressionForSmallPollingResponses() async throws {
    let server = Server(port: 8080, configuration: .init(
        sessionIDGenerator: { "compression-small-session" },
        httpCompression: .init(minimumByteCount: 10_000)
    ))

    let headers: HTTPFields = [.acceptEncoding: "gzip"]
    try await server.application.test(TestingSetup.router) { client in
        let response = try await client.execute(
            uri: "/engine.io?EIO=4&transport=polling",
            method: .get,
            headers: headers
        )
        #expect(response.status == .ok)
        #expect(response.headers[.contentEncoding] == nil)
    }
}

@Test func serverBuildsPerMessageDeflateWebSocketConfiguration() {
    let serverConfiguration = ServerConfiguration(
        perMessageDeflate: .init(minFrameSizeToCompress: 0)
    )

    #expect(serverConfiguration.webSocketServerConfiguration.extensions.count == 1)
}

@Test func serverSendsInitialBinaryPacketOnDirectWebSocketHandshake() async throws {
    actor Recorder {
        var texts: [String] = []
        var binaries: [ByteBuffer] = []

        func record(text: String) {
            texts.append(text)
        }

        func record(binary: ByteBuffer) {
            binaries.append(binary)
        }
    }

    let recorder = Recorder()
    let server = Server(port: 8080, configuration: .init(
        maxHttpBufferSize: 1_000_000,
        sessionIDGenerator: { "initial-websocket" },
        initialPacket: .binary(.init(bytes: [0x01, 0x02, 0x03]))
    ))

    try await server.application.test(.live) { client in
        _ = try await client.ws(
            "/engine.io?EIO=4&transport=websocket",
            configuration: .init(extensions: [.perMessageDeflate(minFrameSizeToCompress: 0)])
        ) { inbound, outbound, _ in
            for try await message in inbound.messages(maxSize: 1_000_000) {
                switch message {
                case .text(let text):
                    await recorder.record(text: text)
                case .binary(let buffer):
                    await recorder.record(binary: buffer)
                    try await outbound.close(.normalClosure, reason: nil)
                    return
                }
            }
        }
    }

    let receivedTexts = await recorder.texts
    let receivedBinaries = await recorder.binaries
    #expect(receivedTexts.count == 1)
    #expect(receivedTexts[0].hasPrefix("0"))
    #expect(receivedBinaries == [.init(bytes: [0x01, 0x02, 0x03])])
}

@Test func serverAddsCorsHeadersToHandshakeResponses() async throws {
    let server = Server(port: 8080, configuration: .init(
        sessionIDGenerator: { "cors-handshake" },
        cors: .static(.init(
            allowedOrigin: .originBased,
            allowCredentials: true
        ))
    ))

    let headers: HTTPFields = [.origin: "https://example.com"]
    try await server.application.test(TestingSetup.router) { client in
        let response = try await client.execute(
            uri: "/engine.io?EIO=4&transport=polling",
            method: HTTPRequest.Method.get,
            headers: headers
        )
        #expect(response.status == .ok)
        #expect(response.headers[.accessControlAllowOrigin] == "https://example.com")
        #expect(response.headers[.accessControlAllowCredentials] == "true")
        #expect(response.headers[values: .vary].contains("Origin"))
    }
}

@Test func serverHandlesCorsPreflightRequests() async throws {
    let server = Server(port: 8080, configuration: .init(
        cors: .static(.init(
            allowedOrigin: .all,
            allowedMethods: [.get, .post],
            allowedHeaders: [.authorization, .contentType],
            allowCredentials: true,
            cacheExpiration: 3600,
            exposedHeaders: [.contentLength]
        ))
    ))

    let headers: HTTPFields = [
        .origin: "https://example.com",
        .accessControlRequestHeaders: "authorization, content-type",
    ]
    try await server.application.test(TestingSetup.router) { client in
        let response = try await client.execute(
            uri: "/engine.io",
            method: HTTPRequest.Method.options,
            headers: headers
        )
        #expect(response.status == .noContent)
        #expect(response.headers[.accessControlAllowOrigin] == "*")
        #expect(response.headers[.accessControlAllowMethods] == "GET, POST")
        #expect(response.headers[.accessControlAllowHeaders] == "authorization, content-type")
        #expect(response.headers[.accessControlAllowCredentials] == "true")
        #expect(response.headers[.accessControlMaxAge] == "3600")
        #expect(response.headers[.accessControlExposeHeaders] == "content-length")
    }
}

@Test func serverLifecycleOnEventReceivesTypedEvents() async throws {
    actor Recorder {
        var connected: [String] = []
        var received: [String] = []
        var closed: [ClosedEvent] = []

        func record(_ event: EngineIOEvent) {
            switch event {
            case .connected(let connection):
                connected.append(connection.sid)
            case .received(_, .text(let text)):
                received.append(text)
            case .received:
                break
            case .closed(let connection, let reason):
                closed.append(.init(sid: connection.sid, reason: reason))
            case .error:
                break
            }
        }
    }

    let recorder = Recorder()
    let server = Server(port: 8080, configuration: .init(
        sessionIDGenerator: { "typed-events-session" },
        lifecycle: .init(onEvent: { event in
            await recorder.record(event)
        })
    ))

    try await server.application.test(TestingSetup.router) { client in
        let handshake = try await client.execute(uri: "/engine.io?EIO=4&transport=polling", method: .get)
        #expect(handshake.status == .ok)

        _ = try await client.execute(
            uri: "/engine.io?EIO=4&transport=polling&sid=typed-events-session",
            method: .post,
            headers: [.contentType: "text/plain; charset=UTF-8"],
            body: .init(string: "4hello")
        )

        _ = try await client.execute(
            uri: "/engine.io?EIO=4&transport=polling&sid=typed-events-session",
            method: .post,
            headers: [.contentType: "text/plain; charset=UTF-8"],
            body: .init(string: "1")
        )

        _ = try await client.execute(
            uri: "/engine.io?EIO=4&transport=polling&sid=typed-events-session",
            method: .get
        )
    }

    try await waitUntil {
        let connected = await recorder.connected
        let received = await recorder.received
        let closed = await recorder.closed
        return connected == ["typed-events-session"]
            && received == ["hello"]
            && closed == [.init(sid: "typed-events-session", reason: .clientInitiated)]
    }
}

@Test func serverLifecycleErrorHookReceivesInvalidPayload() async throws {
    actor Recorder {
        var errors: [ErrorEvent] = []

        func record(_ context: EngineIOErrorContext) {
            errors.append(.init(phase: context.phase, kind: context.kind, message: context.message))
        }
    }

    let recorder = Recorder()
    let server = Server(port: 8080, configuration: .init(
        sessionIDGenerator: { "invalid-payload-session" },
        lifecycle: .init(onError: { context in
            await recorder.record(context)
        })
    ))

    try await server.application.test(TestingSetup.router) { client in
        let handshake = try await client.execute(uri: "/engine.io?EIO=4&transport=polling", method: .get)
        #expect(handshake.status == .ok)

        let response = try await client.execute(
            uri: "/engine.io?EIO=4&transport=polling&sid=invalid-payload-session",
            method: .post,
            headers: [.contentType: "text/plain; charset=UTF-8"],
            body: .init(string: "b%%%")
        )
        #expect(response.status == .badRequest)
        #expect(String(buffer: response.body) == "Invalid payload")
    }

    try await waitUntil {
        await recorder.errors.contains(.init(phase: .polling, kind: .invalidPayload, message: "Invalid payload"))
    }
}

@Test func serverPolicyCanMapHandshakeErrors() async throws {
    let server = Server(port: 8080, configuration: .init(
        policy: .init(
            mapHandshakeError: { context in
                if context.message == "Missing or invalid EIO" {
                    return .init(httpStatus: .unauthorized, httpMessage: "Custom handshake rejection")
                } else {
                    return nil
                }
            }
        )
    ))

    try await server.application.test(TestingSetup.router) { client in
        let response = try await client.execute(uri: "/engine.io?transport=polling", method: .get)
        #expect(response.status == .unauthorized)
        #expect(String(buffer: response.body) == "Custom handshake rejection")
    }
}

@Test func endpointCanBeEmbeddedIntoApplication() async throws {
    let endpoint = EngineIOEndpoint(configuration: .init(sessionIDGenerator: { "endpoint-session" }))
    let router = Router()
    endpoint.install(into: router)
    let application = Application(
        router: router,
        server: .http1WebSocketUpgrade(configuration: endpoint.webSocketConfiguration) { request, _, logger in
            await endpoint.shouldUpgrade(request: request, logger: logger)
        },
        configuration: .init(address: .hostname("0.0.0.0", port: 8080))
    )

    try await application.test(TestingSetup.router) { client in
        let response = try await client.execute(uri: "/engine.io?EIO=4&transport=polling", method: .get)
        #expect(response.status == .ok)
        #expect(String(buffer: response.body).contains("\"sid\":\"endpoint-session\""))
    }
}
