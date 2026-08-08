import Foundation

enum PrerequisitesError: LocalizedError, Equatable {
    case dockerCLIUnavailable(String?)
    case dockerDaemonUnavailable(String?)
    case dockerComposeUnavailable(String?)

    var errorDescription: String? {
        switch self {
        case .dockerCLIUnavailable(let details):
            message(
                "Docker CLI is not available. Install Docker before running the Vernissage installer again.",
                details: details
            )
        case .dockerDaemonUnavailable(let details):
            message(
                "Cannot connect to the Docker daemon. Start Docker and make sure the current user has permission to access it. If Docker works without sudo, run vernissagectl without sudo as well.",
                details: details
            )
        case .dockerComposeUnavailable(let details):
            message(
                "Docker Compose is not available. Install the Docker Compose plugin before running the Vernissage installer again.",
                details: details
            )
        }
    }

    private func message(_ summary: String, details: String?) -> String {
        guard let details, !details.isEmpty else {
            return summary
        }

        return "\(summary) Docker reported: \(details)"
    }
}

struct PrerequisitesStep {
    private let console: Console
    private let commandRunner: any CommandRunning

    init(console: Console, commandRunner: any CommandRunning) {
        self.console = console
        self.commandRunner = commandRunner
    }

    static func live(colorsEnabled: Bool) -> PrerequisitesStep {
        PrerequisitesStep(
            console: .live(colorsEnabled: colorsEnabled),
            commandRunner: ProcessCommandRunner()
        )
    }

    func run(context: InstallationContext) throws {
        console.section("Prerequisites")
        console.guidance(InstallationStepGuidance.prerequisites)

        let client = try runDocker(
            arguments: ["--version"],
            error: PrerequisitesError.dockerCLIUnavailable
        )
        console.success("Docker CLI: \(client.standardOutput)")

        let daemon = try runDocker(
            arguments: ["info", "--format", "{{.ServerVersion}}"],
            error: PrerequisitesError.dockerDaemonUnavailable
        )
        console.success("Docker daemon: \(daemon.standardOutput)")

        let compose = try runDocker(
            arguments: ["compose", "version"],
            error: PrerequisitesError.dockerComposeUnavailable
        )
        console.success("Docker Compose: \(compose.standardOutput)")

        context.docker = DockerEnvironment(
            clientVersion: client.standardOutput,
            serverVersion: daemon.standardOutput,
            composeVersion: compose.standardOutput
        )
    }

    private func runDocker(
        arguments: [String],
        error makeError: (String?) -> PrerequisitesError
    ) throws -> CommandResult {
        let result: CommandResult

        do {
            result = try commandRunner.run("docker", arguments: arguments)
        } catch {
            throw makeError(error.localizedDescription)
        }

        guard result.succeeded, !result.standardOutput.isEmpty else {
            let details = result.standardError.isEmpty
                ? result.standardOutput
                : result.standardError
            throw makeError(details.isEmpty ? nil : details)
        }

        return result
    }
}
