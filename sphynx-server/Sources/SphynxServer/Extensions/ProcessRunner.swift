import Foundation

/// Runs an external command off the cooperative executor and returns its output.
/// Used by server extensions that shell out (e.g. the media-probe extension runs
/// `ffprobe`). Cross-platform (Foundation `Process` works on macOS + Linux).
///
/// The blocking work happens on a background queue; only `Sendable` values
/// (`Data`, the exit code) cross back, so the non-`Sendable` `Process`/`Pipe` stay
/// contained in the closure.
enum ProcessRunner {
    struct Output: Sendable {
        var stdout: Data
        var stderr: Data
        var exitCode: Int32
    }

    enum ProcessError: Error, CustomStringConvertible {
        case launchFailed(String)
        var description: String {
            switch self {
            case .launchFailed(let m): "Failed to launch process: \(m)"
            }
        }
    }

    /// Run `executable args…`, returning captured stdout/stderr and the exit code.
    static func run(_ executable: String, _ arguments: [String]) async throws -> Output {
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
                // ffprobe's JSON output is small, so reading to EOF before waiting
                // won't deadlock the pipe buffer.
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: Output(stdout: outData, stderr: errData, exitCode: process.terminationStatus))
            }
        }
    }
}
