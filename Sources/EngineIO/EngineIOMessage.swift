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
import Hummingbird

/// A payload exchanged over an Engine.IO connection.
public enum EngineIOData: Sendable, Equatable {
    /// A UTF-8 text payload.
    case text(String)
    /// A binary payload.
    case binary(ByteBuffer)
}

/// A handle used to interact with a connected Engine.IO client.
public struct EngineIOConnection: Sendable, Equatable {
    /// The Engine.IO session identifier.
    public let sid: String
    /// The request that established this connection.
    public let request: HTTPRequest

    private let sendOperation: @Sendable (EngineIOData) async -> Void
    private let closeOperation: @Sendable () async -> Void

    init(
        sid: String,
        request: HTTPRequest,
        sendOperation: @escaping @Sendable (EngineIOData) async -> Void,
        closeOperation: @escaping @Sendable () async -> Void
    ) {
        self.sid = sid
        self.request = request
        self.sendOperation = sendOperation
        self.closeOperation = closeOperation
    }

    /// Sends a payload to the connected client.
    ///
    /// - Parameter data: The payload to send.
    public func send(_ data: EngineIOData) async {
        await self.sendOperation(data)
    }

    /// Closes the connection from the server side.
    public func close() async {
        await self.closeOperation()
    }

    /// Returns whether two connection handles point at the same Engine.IO session.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sid == rhs.sid
    }
}
