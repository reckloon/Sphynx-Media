import Foundation
import HTTPTypes
import Hummingbird
import NIOCore

/// Implements the additive **server→client event stream**: `GET /v1/events`
/// (Server-Sent Events). Behind `AuthMiddleware`; the connection is scoped to the
/// authenticated subject, and per-event delivery further honours library read
/// access via `EventBus`.
///
/// SSE (not WebSocket) is the deliberate choice: the need is one-way
/// server→client, and SSE is plain HTTP — proxy-friendly, auto-reconnecting on
/// the client (`EventSource`), and adds no dependency. Clients still *push*
/// progress via `POST /v1/playstate/...`; this stream only carries updates down.
/// The stream is purely additive — a client that ignores it (or a server with
/// `capabilities.events == false`) keeps working by polling.
struct EventsController: Sendable {
    let bus: EventBus
    /// Seconds between keep-alive comment pings.
    let heartbeat: Double

    func addRoutes(to group: RouterGroup<SphynxRequestContext>) {
        group.get("events", use: stream)
    }

    @Sendable
    func stream(_ request: Request, context: SphynxRequestContext) async throws -> Response {
        let identity = try context.requireIdentity()
        let (events, subscription) = await bus.subscribe(identity: identity)
        let bus = self.bus
        let heartbeat = self.heartbeat

        var headers = HTTPFields()
        headers[.contentType] = "text/event-stream"
        headers[.cacheControl] = "no-cache"
        // Disable response buffering in reverse proxies (nginx) so events flush.
        if let accel = HTTPField.Name("X-Accel-Buffering") {
            headers[accel] = "no"
        }

        let body = ResponseBody(contentLength: nil) { writer in
            // One background ticker funnels keep-alives through the SAME stream, so
            // there is exactly one writer — no concurrent writes to serialise.
            let pinger = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(heartbeat))
                    if Task.isCancelled { break }
                    await bus.heartbeat(subscription, ts: Date().timeIntervalSince1970)
                }
            }
            defer { pinger.cancel() }

            do {
                // Prelude so the client's EventSource fires `open` immediately.
                try await writer.write(ByteBuffer(string: ": connected\n\n"))
                for await event in events {
                    try await writer.write(ByteBuffer(string: Self.render(event)))
                }
            } catch {
                // A failed write means the client went away; fall through to clean up.
            }

            await bus.unsubscribe(subscription)
            try? await writer.finish(nil)
        }

        return Response(status: .ok, headers: headers, body: body)
    }

    /// Render one event as an SSE frame. Heartbeats are comment lines (`:` …) so
    /// they keep the connection warm without firing the client's message handler.
    static func render(_ event: ServerEvent) -> String {
        if event.type == "heartbeat" { return ": ping\n\n" }
        guard let data = try? JSONEncoder().encode(event),
              let json = String(data: data, encoding: .utf8) else {
            return ": encode-error\n\n"
        }
        return "event: \(event.type)\ndata: \(json)\n\n"
    }
}
