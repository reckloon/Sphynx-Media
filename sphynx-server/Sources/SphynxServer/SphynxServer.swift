import Hummingbird
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Executable entry point for the Sphynx reference server.
@main
struct SphynxServerCommand {
    static func main() async throws {
        let configuration = ServerConfiguration.fromEnvironment()
        let app = try await buildApplication(configuration: configuration)
        try await app.runService()
    }

    /// Restart the server **in place**: replace this process image with a fresh
    /// instance of the same binary + args. Called by the admin "Restart" endpoint
    /// (from a detached task, just after the `202` is sent).
    ///
    /// This deliberately does NOT go through a graceful `SIGTERM` shutdown: in a
    /// container the background tasks (auto-refresh, backfills) keep the process
    /// alive after the HTTP listener closes, so `SIGTERM` left it half-dead — HTTP
    /// down but the process running, which Docker sees as "Up" and never restarts.
    /// `execv` atomically swaps the whole process (all threads), so it doesn't depend
    /// on any of that. Inherited descriptors above stdio — including the open
    /// listening socket — are closed first so the fresh process can re-`bind` the
    /// port. If `execv` fails, we `exit` non-zero so a supervisor (Docker's
    /// `restart:` policy / systemd) relaunches us.
    static func reexec() -> Never {
        // SQLite (WAL) is durable per-transaction, so an abrupt swap is safe; only
        // in-flight requests are lost, which is expected for a restart.
        for fd in Int32(3) ..< 1024 { close(fd) }   // EBADF on unopened fds is harmless

        let args = CommandLine.arguments
        #if os(Linux)
        let path = "/proc/self/exe"   // the kernel's canonical path to this binary
        #else
        let path = args.first ?? ""
        #endif
        let cArgs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        execv(path, cArgs)
        exit(EXIT_FAILURE)            // only reached if execv failed
    }
}
