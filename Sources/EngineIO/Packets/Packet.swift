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

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Hummingbird
import HummingbirdWebSocket

enum PacketDecodingError: Error {
    case invalidPacket(String)
}

enum PacketType: Int, Equatable {
    case open = 0
    case close
    case ping
    case pong
    case message
    case upgrade
    case noop

    var prefix: String { String(rawValue) }
}

enum EngineIOPacket: Equatable {
    case open(OpenPacket)
    case close
    case ping(String?)
    case pong(String?)
    case message(EngineIOData)
    case upgrade
    case noop

    var type: PacketType {
        switch self {
        case .open: .open
        case .close: .close
        case .ping: .ping
        case .pong: .pong
        case .message: .message
        case .upgrade: .upgrade
        case .noop: .noop
        }
    }

    var isClose: Bool {
        if case .close = self {
            return true
        }
        return false
    }

    var isProbeResponse: Bool {
        if case .pong(let payload) = self {
            return payload == "probe"
        }
        return false
    }

    func encodeForPolling() throws -> String {
        switch self {
        case .message(.binary(let buffer)):
            let data = Data(buffer.readableBytesView)
            return "b\(data.base64EncodedString())"
        default:
            return try encodeAsText()
        }
    }

    func encodeAsText() throws -> String {
        switch self {
        case .open(let packet):
            let data = try JSONEncoder.engineIO.encode(packet)
            return PacketType.open.prefix + String(decoding: data, as: UTF8.self)
        case .close:
            return PacketType.close.prefix
        case .ping(let payload):
            return PacketType.ping.prefix + (payload ?? "")
        case .pong(let payload):
            return PacketType.pong.prefix + (payload ?? "")
        case .message(.text(let payload)):
            return PacketType.message.prefix + payload
        case .message(.binary):
            throw PacketDecodingError.invalidPacket("Binary packets cannot be encoded as websocket text")
        case .upgrade:
            return PacketType.upgrade.prefix
        case .noop:
            return PacketType.noop.prefix
        }
    }

    static func decodePollingPayload(_ buffer: ByteBuffer) throws -> [EngineIOPacket] {
        let string = String(buffer: buffer)
        guard !string.isEmpty else {
            return []
        }
        return try string.split(separator: "\u{1e}", omittingEmptySubsequences: false).map {
            try decodePollingPacket(String($0))
        }
    }

    static func decodePollingPacket(_ value: String) throws -> EngineIOPacket {
        guard !value.isEmpty else {
            throw PacketDecodingError.invalidPacket("Empty polling packet")
        }
        if value.first == "b" {
            let encoded = String(value.dropFirst())
            guard let data = Data(base64Encoded: encoded) else {
                throw PacketDecodingError.invalidPacket("Invalid base64 payload")
            }
            return .message(.binary(.init(bytes: data)))
        }
        return try decodeTextPacket(value)
    }

    static func decodeTextPacket(_ value: String) throws -> EngineIOPacket {
        guard let typeCharacter = value.first, let rawType = Int(String(typeCharacter)), let type = PacketType(rawValue: rawType) else {
            throw PacketDecodingError.invalidPacket("Unknown packet type")
        }
        let payload = String(value.dropFirst())
        switch type {
        case .open:
            throw PacketDecodingError.invalidPacket("Client cannot send open packets")
        case .close:
            return .close
        case .ping:
            return .ping(payload.isEmpty ? nil : payload)
        case .pong:
            return .pong(payload.isEmpty ? nil : payload)
        case .message:
            return .message(.text(payload))
        case .upgrade:
            return .upgrade
        case .noop:
            return .noop
        }
    }

    static func decode(webSocketMessage: WebSocketMessage) throws -> EngineIOPacket {
        switch webSocketMessage {
        case .text(let text):
            return try decodeTextPacket(text)
        case .binary(let buffer):
            return .message(.binary(buffer))
        }
    }
}

extension JSONEncoder {
    static let engineIO: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }()
}
