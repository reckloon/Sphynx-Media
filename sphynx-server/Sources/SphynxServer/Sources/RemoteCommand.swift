import Foundation

/// Seam for shelling out to an external CLI (e.g. `curl` for FTP, `smbclient` for
/// SMB) — injectable so driver tests exercise the *parsing* with canned output
/// instead of needing the tool or a live server. Mirrors how the media-probe
/// extension shells out to `ffprobe`.
typealias CommandRunner = @Sendable (_ executable: String, _ arguments: [String]) async throws -> ProcessRunner.Output

extension ProcessRunner {
    /// The production runner: resolve the tool via `PATH` (`/usr/bin/env <tool>`),
    /// so listing works whether `curl`/`smbclient` lives in /usr/bin, Homebrew, etc.
    static let shell: CommandRunner = { executable, arguments in
        try await ProcessRunner.run("/usr/bin/env", [executable] + arguments)
    }
}
