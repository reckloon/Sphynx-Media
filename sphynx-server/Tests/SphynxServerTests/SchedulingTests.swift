import Foundation
import Hummingbird
import HummingbirdTesting
import SphynxProtocol
import Testing
@testable import SphynxServer

@Suite("Scheduling: ScheduleCenter + extension intervals")
struct SchedulingTests {

    // MARK: ScheduleCenter

    @Test("entries report interval / next run / manual-only in a stable order")
    func scheduleCenter() async throws {
        let center = ScheduleCenter()
        let now = 1_000_000.0
        await center.scheduled(ScheduledTask.enrich.name, label: ScheduledTask.enrich.label,
                               interval: 3600, nextRunAt: now + 1800)
        await center.manualOnly(ScheduledTask.blurhash.name, label: ScheduledTask.blurhash.label)
        await center.nextRun(ScheduledTask.index.name, label: ScheduledTask.index.label, at: now + 60)

        let views = (await center.snapshot()).map { ScheduleView($0, now: now) }
        // Stable display order: enrich, index, blurhash, (mediaProbe absent here).
        #expect(views.map(\.name) == ["enrich", "index", "blurhash"])

        let enrich = try #require(views.first { $0.name == "enrich" })
        #expect(enrich.intervalSeconds == 3600)
        #expect(enrich.nextRunInSeconds == 1800)        // relative, clamped ≥ 0
        #expect(enrich.running == false)

        // manual-only ⇒ no next run, no interval.
        let blur = try #require(views.first { $0.name == "blurhash" })
        #expect(blur.nextRunInSeconds == nil)
        #expect(blur.intervalSeconds == nil)
    }

    @Test("running + lastRun bookkeeping")
    func runningState() async throws {
        let center = ScheduleCenter()
        await center.started(ScheduledTask.blurhash.name, label: ScheduledTask.blurhash.label)
        var view = ScheduleView((await center.snapshot())[0], now: 2_000_000)
        #expect(view.running)

        await center.finished(ScheduledTask.blurhash.name, at: 1_999_990)
        view = ScheduleView((await center.snapshot())[0], now: 2_000_000)
        #expect(view.running == false)
        #expect(view.lastRunSecondsAgo == 10)
    }

    // MARK: Extension interval config (HTTP)

    @Test("placeholders interval round-trips, preserving fractional seconds")
    func placeholderInterval() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            let token = try await adminToken(client)
            // A sub-second interval must survive verbatim (not floored to 0).
            let updated: PlaceholderConfig = try await client.execute(
                uri: "/v1/admin/extensions/placeholders", method: .patch, headers: jsonHeaders(bearer: token),
                body: try jsonBody(PlaceholderConfigUpdate(mode: nil, intervalSeconds: 0.2))
            ) { try $0.decoded() }
            #expect(updated.intervalSeconds == 0.2)

            let reread: PlaceholderConfig = try await client.execute(
                uri: "/v1/admin/extensions/placeholders", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            #expect(reread.intervalSeconds == 0.2)

            // A negative interval is rejected.
            try await client.execute(
                uri: "/v1/admin/extensions/placeholders", method: .patch, headers: jsonHeaders(bearer: token),
                body: try jsonBody(PlaceholderConfigUpdate(mode: nil, intervalSeconds: -1))
            ) { #expect($0.status == .badRequest) }
        }
    }

    @Test("media-probe interval round-trips; run-pass is 400 until enabled")
    func mediaProbeIntervalAndRun() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            let token = try await adminToken(client)
            let updated: MediaProbeConfig = try await client.execute(
                uri: "/v1/admin/extensions/media-probe", method: .patch, headers: jsonHeaders(bearer: token),
                body: try jsonBody(MediaProbeConfigUpdate(enabled: nil, ffprobePath: nil, intervalSeconds: 30))
            ) { try $0.decoded() }
            #expect(updated.intervalSeconds == 30)
            #expect(updated.enabled == false)  // opt-in: still off until enabled

            // Disabled ⇒ the background "Run now" pass is rejected.
            try await client.execute(
                uri: "/v1/admin/extensions/media-probe/run", method: .post, headers: jsonHeaders(bearer: token),
                body: try jsonBody(EmptyBody())
            ) { #expect($0.status == .badRequest) }
        }
    }

    private struct EmptyBody: Codable, Sendable {}

    private func adminToken(_ client: some TestClientProtocol) async throws -> String {
        try await client.execute(
            uri: "/v1/auth/login", method: .post, headers: jsonHeaders(),
            body: try jsonBody(LoginRequest(username: "admin", password: "test-password"))
        ) { try $0.decoded(TokenResponse.self).accessToken }
    }
}
