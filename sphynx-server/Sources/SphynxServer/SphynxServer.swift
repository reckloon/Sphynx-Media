import Hummingbird
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Records an admin "Restart" request so the executable can re-exec itself once the
/// server has cleanly shut down. See `restart` in `AdminController`.
actor RestartCoordinator {
    static let shared = RestartCoordinator()
    private(set) var isRequested = false
    func request() { isRequested = true }
}

/// Executable entry point for the Sphynx reference server.
@main
struct SphynxServerCommand {
    static func main() async throws {
        let configuration = ServerConfiguration.fromEnvironment()
        let app = try await buildApplication(configuration: configuration)
        try await app.runService()
        // The admin "Restart" button sets this flag and then signals a graceful
        // shutdown; `runService()` returns once the server has stopped cleanly (its
        // listener closed and the port freed). We then re-exec this same binary in
        // place — so restart works whether or not a supervisor would relaunch us. A
        // plain `SIGTERM` alone only *stops* the process when run from source (no
        // Docker `restart:` policy / systemd to bring it back).
        if await RestartCoordinator.shared.isRequested {
            reexec()
        }
    }

    /// Replace this process image with a fresh instance of the same binary and args.
    /// Returns only if `execv` fails, after which `main` returns and the process exits.
    static func reexec() {
        let args = CommandLine.arguments
        #if os(Linux)
        let path = "/proc/self/exe"   // the kernel's canonical path to this binary
        #else
        let path = args.first ?? ""
        #endif
        var cArgs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
        cArgs.append(nil)
        execv(path, cArgs)
    }
}
