# Getting Started

Set up `EngineIO` when you need the Engine.IO transport layer in a Swift server. The package handles polling, WebSocket upgrades, heartbeat timeouts, and event delivery, while leaving your application message handling in Swift.

## Create A Server

For a standalone server, create ``Server`` with a ``ServerConfiguration`` and run it:

```swift
import EngineIO

@main
struct App {
    static func main() async throws {
        let server = Server(
            port: 3000,
            configuration: .init(
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

This configuration creates an echo server that sends each received payload back to the client.

## Embed In An Existing Hummingbird App

If you already have a Hummingbird application, install ``EngineIOEndpoint`` into the router and forward upgrade requests using ``EngineIOEndpoint/webSocketConfiguration`` and ``EngineIOEndpoint/shouldUpgrade(request:logger:)``.

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

## Customize Behavior

Use ``ServerConfiguration`` to tune how the server behaves:

- Adjust routing with ``ServerConfiguration/Routing``
- Configure heartbeat timeouts with ``ServerConfiguration/Heartbeat``
- Enable cookies, compression, and initial packets with ``ServerConfiguration/TransportConfiguration``
- Observe lifecycle events with ``ServerConfiguration/Lifecycle``
- Enforce admission rules with ``ServerConfiguration/Policy``

## Next Steps

- Explore ``ServerConfiguration`` to tailor routing, transport, and policy behavior
- Use ``EngineIOConnection`` to send data or close sessions from server code
- Inspect ``EngineIOEvent`` and ``EngineIOErrorContext`` to integrate with your logging and metrics
