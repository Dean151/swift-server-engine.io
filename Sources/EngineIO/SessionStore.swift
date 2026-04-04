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
import HummingbirdWebSocket

enum SessionError: Error, Equatable {
    case badRequest(String)

    var message: String {
        switch self {
        case .badRequest(let message):
            return message
        }
    }

    var closeReason: EngineIOCloseReason {
        .protocolViolation(self.message)
    }
}

struct ReceivedMessage: Sendable, Equatable {
    let connection: EngineIOConnection
    let data: EngineIOData
}

struct SessionHandshake: Sendable, Equatable {
    let connection: EngineIOConnection
    let openPacket: OpenPacket
}

enum WebSocketPlan: Sendable, Equatable {
    case reject(String)
    case newSession(SessionHandshake)
    case upgradeExisting(String)
}

actor SessionStore {
    private let clock = ContinuousClock()

    private enum WebSocketState {
        case none
        case reservedForUpgrade
        case upgrading(AsyncStream<EngineIOPacket>.Continuation, probeConfirmed: Bool)
        case active(AsyncStream<EngineIOPacket>.Continuation)
    }

    private struct SessionState {
        let sid: String
        let request: HTTPRequest
        let transport: Transport
        var outboundQueue: [EngineIOPacket] = []
        var pendingPoll: CheckedContinuation<[EngineIOPacket], Never>?
        var activePost = false
        var webSocketState: WebSocketState = .none
        var upgradeNoopPending = false
        var closeAfterPollingDrain: EngineIOCloseReason?
        var heartbeatCounter: UInt64 = 0
        var outstandingHeartbeat: UInt64?
        var heartbeatDeadline: ContinuousClock.Instant?
        var heartbeatTask: Task<Void, Never>?
        var upgradeTask: Task<Void, Never>?
    }

    private let configuration: ServerConfiguration
    private var sessions: [String: SessionState] = [:]
    private var isClosed = false

    init(configuration: ServerConfiguration) {
        self.configuration = configuration
    }

    func createPollingSession(request: HTTPRequest) -> SessionHandshake? {
        guard !isClosed else { return nil }
        return createSession(transport: .polling, request: request)
    }

    func prepareWebSocketConnection(request: HTTPRequest, sid: String?) -> WebSocketPlan {
        guard !isClosed else {
            return .reject("Server is closed")
        }
        guard configuration.transports.contains(.websocket) else {
            return .reject("WebSocket transport is disabled")
        }
        guard let sid else {
            return .newSession(createSession(transport: .websocket, request: request))
        }
        guard configuration.allowUpgrades else {
            return .reject("Transport upgrades are disabled")
        }
        guard var session = sessions[sid] else {
            return .reject("Unknown session id")
        }
        guard session.transport == .polling else {
            return .reject("Session is not upgradeable")
        }
        switch session.webSocketState {
        case .none:
            session.webSocketState = .reservedForUpgrade
            session.upgradeNoopPending = true
            session.upgradeTask?.cancel()
            session.upgradeTask = makeDestroyUpgradeTask(for: sid)
            sessions[sid] = session
            return .upgradeExisting(sid)
        case .reservedForUpgrade, .upgrading, .active:
            return .reject("Duplicate websocket connection")
        }
    }

    func attachNewWebSocket(sid: String, continuation: AsyncStream<EngineIOPacket>.Continuation) {
        guard var session = sessions[sid] else { return }
        session.upgradeTask?.cancel()
        session.upgradeTask = nil
        session.webSocketState = .active(continuation)
        sessions[sid] = session
    }

    func attachWebSocketUpgrade(sid: String, continuation: AsyncStream<EngineIOPacket>.Continuation) {
        guard var session = sessions[sid] else { return }
        session.upgradeTask?.cancel()
        session.upgradeTask = makeUpgradeTimeoutTask(for: sid)
        session.webSocketState = .upgrading(continuation, probeConfirmed: false)
        if let pendingPoll = session.pendingPoll {
            session.pendingPoll = nil
            session.upgradeNoopPending = false
            pendingPoll.resume(returning: [.noop])
        }
        sessions[sid] = session
    }

    func detachWebSocket(sid: String, reason: EngineIOCloseReason) async {
        guard let session = sessions[sid] else { return }
        switch session.transport {
        case .websocket:
            await closeSession(sid: sid, sendClosePacket: false, reason: reason)
        case .polling:
            switch session.webSocketState {
            case .none:
                break
            case .reservedForUpgrade, .upgrading:
                var updated = session
                updated.upgradeTask?.cancel()
                updated.upgradeTask = nil
                updated.webSocketState = .none
                sessions[sid] = updated
            case .active:
                await closeSession(sid: sid, sendClosePacket: false, reason: reason)
            }
        default:
            break
        }
    }

    func poll(sid: String) async throws -> [EngineIOPacket] {
        guard var session = sessions[sid] else {
            throw SessionError.badRequest("Unknown session id")
        }
        if hasHeartbeatExpired(session) {
            await closeSession(sid: sid, sendClosePacket: false, reason: .heartbeatTimeout)
            throw SessionError.badRequest("Unknown session id")
        }
        guard session.transport == .polling else {
            throw SessionError.badRequest("Session is not using polling")
        }
        switch session.webSocketState {
        case .none:
            break
        case .reservedForUpgrade, .upgrading:
            if session.upgradeNoopPending {
                session.upgradeNoopPending = false
                sessions[sid] = session
                return [.noop]
            }
            throw SessionError.badRequest("Polling is no longer available for this session")
        case .active:
            throw SessionError.badRequest("Polling is no longer available for this session")
        }
        guard session.pendingPoll == nil else {
            await closeSession(
                sid: sid,
                sendClosePacket: true,
                reason: .protocolViolation("A polling GET request is already active")
            )
            throw SessionError.badRequest("A polling GET request is already active")
        }
        if !session.outboundQueue.isEmpty {
            let packets = session.outboundQueue
            if let reason = session.closeAfterPollingDrain {
                session.heartbeatTask?.cancel()
                sessions.removeValue(forKey: sid)
                await emitClose(for: sid, request: session.request, reason: reason)
            } else {
                session.outboundQueue.removeAll(keepingCapacity: true)
                sessions[sid] = session
            }
            return packets
        }
        return await withCheckedContinuation { continuation in
            session.pendingPoll = continuation
            sessions[sid] = session
        }
    }

    func beginPollingPost(sid: String) async throws {
        guard var session = sessions[sid] else {
            throw SessionError.badRequest("Unknown session id")
        }
        if hasHeartbeatExpired(session) {
            await closeSession(sid: sid, sendClosePacket: false, reason: .heartbeatTimeout)
            throw SessionError.badRequest("Unknown session id")
        }
        guard session.transport == .polling else {
            throw SessionError.badRequest("Session is not using polling")
        }
        guard case .none = session.webSocketState else {
            throw SessionError.badRequest("Polling is no longer available for this session")
        }
        guard !session.activePost else {
            await closeSession(
                sid: sid,
                sendClosePacket: true,
                reason: .protocolViolation("A polling POST request is already active")
            )
            throw SessionError.badRequest("A polling POST request is already active")
        }
        session.activePost = true
        sessions[sid] = session
    }

    func finishPollingPost(sid: String) {
        guard var session = sessions[sid] else { return }
        session.activePost = false
        sessions[sid] = session
    }

    func processIncomingPacket(sid: String, packet: EngineIOPacket, via transport: Transport) async throws -> [ReceivedMessage] {
        guard var session = sessions[sid] else {
            throw SessionError.badRequest("Unknown session id")
        }
        if hasHeartbeatExpired(session) {
            await closeSession(sid: sid, sendClosePacket: false, reason: .heartbeatTimeout)
            throw SessionError.badRequest("Unknown session id")
        }
        switch transport {
        case .polling:
            guard session.transport == .polling else {
                throw SessionError.badRequest("Unknown session id")
            }
            guard case .none = session.webSocketState else {
                throw SessionError.badRequest("Polling is no longer available for this session")
            }
        case .websocket:
            switch session.webSocketState {
            case .upgrading, .active:
                break
            case .none, .reservedForUpgrade:
                guard session.transport == .websocket else {
                    throw SessionError.badRequest("WebSocket session is not active")
                }
            }
        default:
            throw SessionError.badRequest("Unsupported transport")
        }

        switch packet {
        case .open:
            throw SessionError.badRequest("Client cannot send open packets")
        case .close:
            switch transport {
            case .polling:
                await closePollingSession(sid: sid)
            case .websocket:
                await closeSession(sid: sid, sendClosePacket: true, reason: .clientInitiated)
            default:
                await closeSession(sid: sid, sendClosePacket: false, reason: .clientInitiated)
            }
            return []
        case .ping(let payload):
            if payload == "probe" {
                guard case .upgrading(let continuation, _) = session.webSocketState else {
                    throw SessionError.badRequest("Probe ping is only valid while upgrading")
                }
                session.webSocketState = .upgrading(continuation, probeConfirmed: true)
                sessions[sid] = session
                enqueue(.pong("probe"), for: sid)
                return []
            }
            enqueue(.pong(payload), for: sid)
            return []
        case .pong(let payload):
            if payload != "probe" {
                session.outstandingHeartbeat = nil
                session.heartbeatDeadline = nil
                sessions[sid] = session
            }
            return []
        case .message(let data):
            return [.init(connection: makeConnection(sid: sid, request: session.request), data: data)]
        case .upgrade:
            guard case .upgrading(let continuation, true) = session.webSocketState else {
                throw SessionError.badRequest("WebSocket upgrade is incomplete")
            }
            session.upgradeTask?.cancel()
            session.upgradeTask = nil
            session.webSocketState = .active(continuation)
            let queuedPackets = session.outboundQueue
            session.outboundQueue.removeAll(keepingCapacity: true)
            sessions[sid] = session
            for queuedPacket in queuedPackets {
                enqueue(queuedPacket, for: sid)
            }
            return []
        case .noop:
            return []
        }
    }

    func send(_ data: EngineIOData, to sid: String) {
        guard sessions[sid] != nil else { return }
        enqueue(.message(data), for: sid)
    }

    func connection(for sid: String) -> EngineIOConnection? {
        guard let session = sessions[sid] else { return nil }
        return makeConnection(sid: sid, request: session.request)
    }

    func connections() -> [String: EngineIOConnection] {
        Dictionary(uniqueKeysWithValues: sessions.map { sid, session in
            (sid, makeConnection(sid: sid, request: session.request))
        })
    }

    func connectionCount() -> Int {
        sessions.count
    }

    func hasPendingPollRequest(sid: String) -> Bool {
        sessions[sid]?.pendingPoll != nil
    }

    func close() async {
        isClosed = true
        let sessionsToClose = sessions
        sessions.removeAll()
        for (sid, session) in sessionsToClose {
            await closeRemovedSession(
                session,
                sid: sid,
                sendClosePacket: true,
                reason: .serverInitiated
            )
        }
    }

    func closeSession(
        sid: String,
        sendClosePacket: Bool = true,
        reason: EngineIOCloseReason = .serverInitiated
    ) async {
        guard let session = sessions.removeValue(forKey: sid) else { return }
        await closeRemovedSession(session, sid: sid, sendClosePacket: sendClosePacket, reason: reason)
    }

    private func closePollingSession(sid: String) async {
        guard var session = sessions[sid] else { return }
        session.heartbeatTask?.cancel()
        session.upgradeTask?.cancel()
        if let pendingPoll = session.pendingPoll {
            session.pendingPoll = nil
            sessions.removeValue(forKey: sid)
            pendingPoll.resume(returning: [.noop])
            await emitClose(for: sid, request: session.request, reason: .clientInitiated)
            return
        }
        session.outboundQueue = [.noop]
        session.closeAfterPollingDrain = .clientInitiated
        sessions[sid] = session
    }

    private func createSession(transport: Transport, request: HTTPRequest) -> SessionHandshake {
        let sid = configuration.sessionIDGenerator()
        var session = SessionState(sid: sid, request: request, transport: transport)
        let openPacket = OpenPacket(sid: sid, configuration: configuration, transport: transport)
        session.heartbeatTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: self.configuration.pingInterval)
                } catch {
                    return
                }
                guard let heartbeatID = await self.sendHeartbeatPing(to: sid) else {
                    return
                }
                do {
                    try await Task.sleep(for: self.configuration.pingTimeout)
                } catch {
                    return
                }
                let shouldClose = await self.didHeartbeatExpire(sid: sid, heartbeatID: heartbeatID)
                if shouldClose {
                    await self.closeSession(sid: sid, sendClosePacket: true, reason: .heartbeatTimeout)
                    return
                }
            }
        }
        sessions[sid] = session
        return .init(connection: makeConnection(sid: sid, request: request), openPacket: openPacket)
    }

    private func sendHeartbeatPing(to sid: String) -> UInt64? {
        guard var session = sessions[sid] else { return nil }
        session.heartbeatCounter &+= 1
        session.outstandingHeartbeat = session.heartbeatCounter
        session.heartbeatDeadline = clock.now + configuration.pingTimeout
        sessions[sid] = session
        enqueue(.ping(nil), for: sid)
        return session.heartbeatCounter
    }

    private func didHeartbeatExpire(sid: String, heartbeatID: UInt64) -> Bool {
        guard let session = sessions[sid] else { return false }
        return session.outstandingHeartbeat == heartbeatID
    }

    private func hasHeartbeatExpired(_ session: SessionState) -> Bool {
        guard session.outstandingHeartbeat != nil, let heartbeatDeadline = session.heartbeatDeadline else {
            return false
        }
        return clock.now >= heartbeatDeadline
    }

    private func makeUpgradeTimeoutTask(for sid: String) -> Task<Void, Never> {
        Task {
            do {
                try await Task.sleep(for: configuration.upgradeTimeout)
            } catch {
                return
            }
            await cancelUpgradeIfTimedOut(sid: sid)
        }
    }

    private func makeDestroyUpgradeTask(for sid: String) -> Task<Void, Never>? {
        switch configuration.destroyUpgrade {
        case .no:
            return nil
        case .after(let timeout):
            return Task {
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                await cancelUpgradeIfTimedOut(sid: sid)
            }
        }
    }

    private func cancelUpgradeIfTimedOut(sid: String) async {
        guard var session = sessions[sid] else { return }
        let connection = makeConnection(sid: sid, request: session.request)
        switch session.webSocketState {
        case .reservedForUpgrade:
            session.upgradeTask = nil
            session.upgradeNoopPending = false
            session.webSocketState = .none
            sessions[sid] = session
            await configuration.emit(.error(.init(
                phase: .websocket,
                kind: .timeout,
                message: "Reserved websocket upgrade timed out",
                request: session.request,
                connection: connection,
                transport: .websocket,
                isTerminal: false
            )))
        case .upgrading(let continuation, _):
            session.upgradeTask = nil
            session.upgradeNoopPending = false
            session.webSocketState = .none
            sessions[sid] = session
            continuation.yield(.close)
            continuation.finish()
            await configuration.emit(.error(.init(
                phase: .websocket,
                kind: .timeout,
                message: "WebSocket upgrade timed out",
                request: session.request,
                connection: connection,
                transport: .websocket,
                isTerminal: false
            )))
        case .none, .active:
            session.upgradeTask = nil
            sessions[sid] = session
        }
    }

    private func enqueue(_ packet: EngineIOPacket, for sid: String) {
        guard var session = sessions[sid] else { return }
        switch session.webSocketState {
        case .active(let continuation):
            sessions[sid] = session
            continuation.yield(packet)
        case .upgrading(let continuation, _) where packet.isProbeResponse || packet.isClose:
            sessions[sid] = session
            continuation.yield(packet)
        default:
            if let pendingPoll = session.pendingPoll {
                session.pendingPoll = nil
                sessions[sid] = session
                pendingPoll.resume(returning: [packet])
            } else {
                session.outboundQueue.append(packet)
                sessions[sid] = session
            }
        }
    }

    private func emitClose(for sid: String, request: HTTPRequest, reason: EngineIOCloseReason) async {
        await configuration.emit(.closed(makeConnection(sid: sid, request: request), reason))
    }

    private func closeRemovedSession(
        _ session: SessionState,
        sid: String,
        sendClosePacket: Bool,
        reason: EngineIOCloseReason
    ) async {
        session.heartbeatTask?.cancel()
        session.upgradeTask?.cancel()
        if sendClosePacket {
            switch session.webSocketState {
            case .active(let continuation), .upgrading(let continuation, _):
                continuation.yield(.close)
                continuation.finish()
            case .none, .reservedForUpgrade:
                break
            }
            if let pendingPoll = session.pendingPoll {
                pendingPoll.resume(returning: [.close])
            }
        } else {
            switch session.webSocketState {
            case .active(let continuation), .upgrading(let continuation, _):
                continuation.finish()
            case .none, .reservedForUpgrade:
                break
            }
            if let pendingPoll = session.pendingPoll {
                pendingPoll.resume(returning: [])
            }
        }
        await emitClose(for: sid, request: session.request, reason: reason)
    }

    private func makeConnection(sid: String, request: HTTPRequest) -> EngineIOConnection {
        .init(
            sid: sid,
            request: request,
            sendOperation: { [store = self] data in
                await store.send(data, to: sid)
            },
            closeOperation: { [store = self] in
                await store.closeSession(sid: sid)
            }
        )
    }
}
