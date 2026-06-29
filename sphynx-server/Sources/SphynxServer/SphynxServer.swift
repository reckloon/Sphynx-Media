import Hummingbird

/// Executable entry point for the Sphynx reference server.
@main
struct SphynxServerCommand {
    static func main() async throws {
        let configuration = ServerConfiguration.fromEnvironment()
        let app = try await buildApplication(configuration: configuration)
        try await app.runService()
    }
}
