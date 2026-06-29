import Foundation
import Testing
@testable import SphynxServer

/// The media-probe extension shells out via `ProcessRunner`; a hung `ffprobe`
/// reading a stalled remote stream must not block a worker forever, so the runner
/// enforces a hard timeout.
@Suite("ProcessRunner timeout")
struct ProcessRunnerTests {
    private func locate(_ names: [String]) -> String? {
        names.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    @Test("a process that overruns its timeout is killed and surfaces ProcessError")
    func killsOverrun() async throws {
        let sleep = try #require(locate(["/bin/sleep", "/usr/bin/sleep"]))
        // 1s budget against a 10s sleep: must throw promptly, not wait the full 10s.
        await #expect(throws: ProcessRunner.ProcessError.self) {
            _ = try await ProcessRunner.run(sleep, ["10"], timeout: 1)
        }
    }

    @Test("a fast command returns its output and exit code")
    func fastCommandSucceeds() async throws {
        let echo = try #require(locate(["/bin/echo", "/usr/bin/echo"]))
        let out = try await ProcessRunner.run(echo, ["hello"], timeout: 5)
        #expect(out.exitCode == 0)
        #expect(String(data: out.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
    }
}
