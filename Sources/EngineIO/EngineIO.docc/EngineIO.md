# ``EngineIO``

Engine.IO server support for Swift applications built on top of Hummingbird.

`EngineIO` provides a server-side implementation of the Engine.IO v4 transport layer, including HTTP long-polling, WebSocket upgrades, lifecycle hooks, and handshake policy controls.

## Overview

Use ``Server`` when you want a ready-to-run Hummingbird service, or use ``EngineIOEndpoint`` when you want to install Engine.IO into an existing router and upgrade pipeline.

The library centers around:

- ``ServerConfiguration`` for routing, transport, lifecycle, CORS, and policy configuration
- ``EngineIOConnection`` for interacting with a connected client
- ``EngineIOData`` for text and binary application payloads

## Topics

### Essentials

- <doc:GettingStarted>

### Server Setup

- ``Server``
- ``EngineIOEndpoint``
- ``ServerConfiguration``

### Connection Lifecycle

- ``EngineIOConnection``
- ``EngineIOEvent``
- ``EngineIOCloseReason``
- ``EngineIOErrorContext``

### Payloads And Transport

- ``EngineIOData``
- ``Transport``
