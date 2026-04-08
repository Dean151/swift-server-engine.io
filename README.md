# swift-server-engine.io

[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FDean151%2Fswift-server-engine.io%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/Dean151/swift-server-engine.io)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FDean151%2Fswift-server-engine.io%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/Dean151/swift-server-engine.io)

Engine.IO server implementation in Swift, built on top of Hummingbird.

This package provides:

- `EngineIO`: the server library
- `EngineIOTestApp`: a small echo server used for protocol testing

## Status

The project currently focuses on Engine.IO transport behavior, including:

- HTTP long-polling
- WebSocket upgrades
- Engine.IO v4 packet encoding and decoding
- Protocol test-suite compatibility via Docker

## Installation

Add the package dependency to your `Package.swift`:

```swift
.package(url: "https://github.com/thomasauger/swift-server-engine.io.git", exact: "4.0.0-beta.2")
```

Then depend on the `EngineIO` product:

```swift
.product(name: "EngineIO", package: "swift-server-engine.io")
```

## Quick Start

```swift
import EngineIO

@main
struct App {
    static func main() async throws {
        let server = Server(
            port: 3000,
            configuration: .init(
                heartbeat: .init(
                    pingTimeout: .milliseconds(200),
                    pingInterval: .milliseconds(300)
                ),
                transport: .init(maxPayload: 1_000_000),
                lifecycle: .init(
                    onMessage: { connection, data in
                        await connection.send(data)
                    },
                    onError: { error in
                        print("Engine.IO error:", error.message)
                    }
                )
            )
        )

        try await server.run()
    }
}
```

The demo executable in [`Demo/EngineIO/App.swift`](./Demo/EngineIO/App.swift) uses the same setup.

If you want to embed Engine.IO into an existing Hummingbird app, use `EngineIOEndpoint`:

```swift
import EngineIO
import Hummingbird
import HummingbirdWebSocket

let endpoint = EngineIOEndpoint(configuration: .init())
let router = Router()
endpoint.install(into: router)

let app = Application(
    router: router,
    server: .http1WebSocketUpgrade(configuration: endpoint.webSocketConfiguration) { request, _, logger in
        await endpoint.shouldUpgrade(request: request, logger: logger)
    }
)
```

## Development

Run the Swift test suite:

```bash
swift test
```

Run the Engine.IO protocol tests:

```bash
docker compose run --build --rm engine-test
```

Run both:

```bash
make test
```

## References

- Engine.IO protocol repository: <https://github.com/socketio/engine.io-protocol>
- Socket.IO website: <https://socket.io/>
