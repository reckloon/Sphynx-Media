import Foundation

/// Runs an external command off the cooperative executor and returns its output.
/// Used by server extensions that shell out (e.g. the media-probe extension runs
/// `ffprobe`). Cross-platform (Foundation `Process` works on macOS + Linux).
///
/// The blocking work happens on a background queue; only `Sendable` values
/// (`Data`, the exit code) cross back, so the non-`Sendable` `Process`/`Pipe` stay
/// contained in the closure.
/// A tiny thread-safe boolean, set from the watchdog queue and read on the worker
/// thread — so a single shared flag survives the cross-thread hand-off cleanly.
private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

enum ProcessRunner {
    struct Output: Sendable {
        var stdout: Data
        var stderr: Data
        var exitCode: Int32
    }

    enum ProcessError: Error, CustomStringConvertible {
        case launchFailed(String)
        case timedOut(TimeInterval)
        var description: String {
            switch self {
            case .launchFailed(let m): "Failed to launch process: \(m)"
            case .timedOut(let s): "Process timed out after \(s)s"
            }
        }
    }

    /// Run `executable args…`, returning captured stdout/stderr and the exit code.
    ///
    /// A watchdog terminates a process that overruns `timeout` (default 60s) and the
    /// call then throws `ProcessError.timedOut` — so a hung `ffprobe` reading a stalled
    /// remote stream can't block a worker forever.
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 60) async throws -> Output {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Output, Error>) in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: ProcessError.launchFailed(error.localizedDescription))
                    return
                }
                // Watchdog: SIGTERM a process that overruns the timeout, which unblocks
                // the reads + waitUntilExit below. We track the kill with an explicit
                // flag rather than `terminationReason`/`isRunning` — both are unreliable
                // on swift-corelibs-foundation (Linux), where `isRunning` can read false
                // and skip the kill entirely.
                let timedOut = TimeoutFlag()
                let watchdog = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
                watchdog.schedule(deadline: .now() + timeout)
                watchdog.setEventHandler {
                    timedOut.set()
                    process.terminate()  // safe after launch (signals the pid; no-op if already exited)
                }
                watchdog.resume()
                // ffprobe's JSON output is small, so reading to EOF before waiting
                // won't deadlock the pipe buffer.
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                watchdog.cancel()
                if timedOut.value {
                    continuation.resume(throwing: ProcessError.timedOut(timeout))
                    return
                }
                continuation.resume(returning: Output(stdout: outData, stderr: errData, exitCode: process.terminationStatus))
            }
        }
    }
}
