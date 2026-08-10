import Testing
@testable import VernissageCore

struct CleanupCommandTests {
    @Test
    func `Cleanup command parses instance identifier and destructive volume option`() throws {
        let command = try CleanupCommand.parse([
            "--instance-id", "abcdefgh",
            "--include-volumes",
            "--no-color"
        ])

        #expect(command.instanceIdentifier == "abcdefgh")
        #expect(command.includeVolumes)
        #expect(command.noColor)
    }

    @Test
    func `Full cleanup removes only existing instance resources in safe order`() throws {
        let runner = CleanupCommandRunner(
            containers: [
                "vernissage-abcdefgh-caddy",
                "vernissage-abcdefgh-api",
                "vernissage-abcdefgh-postgres"
            ],
            volumes: [
                "vernissage-abcdefgh-caddy-data",
                "vernissage-abcdefgh-postgres-data"
            ],
            networks: ["vernissage-abcdefgh-network"],
            images: ["vernissage-proxy:abcdefgh"]
        )
        let controller = InstallationCleanupController(commandRunner: runner)

        let result = try controller.cleanup(
            instanceIdentifier: "abcdefgh",
            includeVolumes: true
        )

        #expect(
            result.removedContainers == [
                "vernissage-abcdefgh-caddy",
                "vernissage-abcdefgh-api",
                "vernissage-abcdefgh-postgres"
            ]
        )
        #expect(
            result.removedVolumes == [
                "vernissage-abcdefgh-caddy-data",
                "vernissage-abcdefgh-postgres-data"
            ]
        )
        #expect(result.preservedVolumes.isEmpty)
        #expect(result.removedNetwork == "vernissage-abcdefgh-network")
        #expect(result.removedProxyImage == "vernissage-proxy:abcdefgh")
        #expect(result.foundResources)
        #expect(runner.containers.isEmpty)
        #expect(runner.volumes.isEmpty)
        #expect(runner.networks.isEmpty)
        #expect(runner.images.isEmpty)

        let removals = runner.invocations.filter { $0.arguments.contains("rm") }
        #expect(removals.count == 4)
        #expect(removals[0].arguments.prefix(3) == ["container", "rm", "--force"])
        #expect(removals[1].arguments == [
            "network", "rm", "vernissage-abcdefgh-network"
        ])
        #expect(removals[2].arguments == [
            "image", "rm", "vernissage-proxy:abcdefgh"
        ])
        #expect(removals[3].arguments.prefix(2) == ["volume", "rm"])
    }

    @Test
    func `Cleanup preserves discovered volumes unless explicitly included`() throws {
        let runner = CleanupCommandRunner(
            containers: ["vernissage-abcdefgh-api"],
            volumes: ["vernissage-abcdefgh-postgres-data"]
        )
        let controller = InstallationCleanupController(commandRunner: runner)

        let result = try controller.cleanup(
            instanceIdentifier: "abcdefgh",
            includeVolumes: false
        )

        #expect(result.removedContainers == ["vernissage-abcdefgh-api"])
        #expect(result.removedVolumes.isEmpty)
        #expect(
            result.preservedVolumes == [
                "vernissage-abcdefgh-postgres-data"
            ]
        )
        #expect(runner.volumes == ["vernissage-abcdefgh-postgres-data"])
        #expect(
            runner.invocations.contains { invocation in
                invocation.arguments.starts(with: ["volume", "rm"])
            } == false
        )
    }

    @Test
    func `Cleanup succeeds without changes when instance resources do not exist`() throws {
        let runner = CleanupCommandRunner()
        let controller = InstallationCleanupController(commandRunner: runner)

        let result = try controller.cleanup(
            instanceIdentifier: "abcdefgh",
            includeVolumes: true
        )

        #expect(result.foundResources == false)
        #expect(
            runner.invocations.contains { $0.arguments.contains("rm") } == false
        )
    }

    @Test
    func `Invalid cleanup identifier is rejected before Docker is contacted`() {
        let runner = CleanupCommandRunner()
        let controller = InstallationCleanupController(commandRunner: runner)

        let error = #expect(throws: InstallationCleanupError.self) {
            try controller.cleanup(
                instanceIdentifier: "invalid-id",
                includeVolumes: true
            )
        }

        #expect(error == .invalidInstanceIdentifier)
        #expect(runner.invocations.isEmpty)
    }

    @Test
    func `Unavailable Docker stops cleanup before resource inspection`() {
        let runner = CleanupCommandRunner(dockerAvailable: false)
        let controller = InstallationCleanupController(commandRunner: runner)

        let error = #expect(throws: InstallationCleanupError.self) {
            try controller.cleanup(
                instanceIdentifier: "abcdefgh",
                includeVolumes: true
            )
        }

        #expect(error == .dockerUnavailable("daemon unavailable"))
        #expect(runner.invocations.count == 1)
        #expect(runner.invocations[0].arguments.first == "info")
    }

    @Test
    func `Installation failure recommends diagnostics cleanup and retry in order`() throws {
        let message = InstallationFailureRecovery.message(
            error: "API failed. Inspect with docker logs vernissage-abcdefgh-api.",
            instanceIdentifier: "abcdefgh"
        )

        let diagnostics = try #require(message.range(of: "docker logs"))
        let cleanup = try #require(
            message.range(
                of: "vernissagectl cleanup --instance-id abcdefgh --include-volumes"
            )
        )
        let retry = try #require(
            message.range(of: "run your original vernissagectl install command again")
        )

        #expect(diagnostics.lowerBound < cleanup.lowerBound)
        #expect(cleanup.lowerBound < retry.lowerBound)
        #expect(message.contains("prefix the cleanup command with sudo"))
    }

    @Test
    func `Final readiness failure preserves configuration and recommends doctor before cleanup`() throws {
        let message = InstallationFailureRecovery.message(
            error: "HTTPS certificate is not ready.",
            instanceIdentifier: "abcdefgh",
            configurationPath: "/srv/vernissage/vernissage.yml",
            secretsPath: "/srv/vernissage/vernissage.secrets.yml"
        )

        let saved = try #require(message.range(of: "management files were saved"))
        let doctor = try #require(
            message.range(
                of: "vernissagectl --config /srv/vernissage/vernissage.yml doctor"
            )
        )
        let cleanup = try #require(
            message.range(
                of: "vernissagectl cleanup --instance-id abcdefgh --include-volumes"
            )
        )

        #expect(saved.lowerBound < doctor.lowerBound)
        #expect(doctor.lowerBound < cleanup.lowerBound)
        #expect(message.contains("Caddy can recover automatically"))
        #expect(message.contains("/srv/vernissage/vernissage.secrets.yml"))
    }
}

private struct CleanupCommandInvocation {
    let executable: String
    let arguments: [String]
}

private final class CleanupCommandRunner: CommandRunning {
    var containers: Set<String>
    var volumes: Set<String>
    var networks: Set<String>
    var images: Set<String>
    private let dockerAvailable: Bool
    private(set) var invocations: [CleanupCommandInvocation] = []

    init(
        dockerAvailable: Bool = true,
        containers: Set<String> = [],
        volumes: Set<String> = [],
        networks: Set<String> = [],
        images: Set<String> = []
    ) {
        self.dockerAvailable = dockerAvailable
        self.containers = containers
        self.volumes = volumes
        self.networks = networks
        self.images = images
    }

    func run(
        _ executable: String,
        arguments: [String],
        environment: [String: String],
        standardInput: String?
    ) throws -> CommandResult {
        invocations.append(
            CleanupCommandInvocation(
                executable: executable,
                arguments: arguments
            )
        )

        guard arguments.first != "info" || dockerAvailable else {
            return .cleanupFailure("daemon unavailable")
        }
        if arguments.first == "info" {
            return .cleanupSuccess("29.0.0")
        }
        if arguments.count >= 3, arguments[1] == "inspect" {
            return resources(for: arguments[0]).contains(arguments[2])
                ? .cleanupSuccess("resource")
                : .cleanupFailure("No such \(arguments[0]): \(arguments[2])")
        }
        if arguments.count >= 2, arguments[1] == "rm" {
            remove(arguments: arguments)
            return .cleanupSuccess("removed")
        }

        return .cleanupFailure("unexpected Docker invocation")
    }

    private func resources(for kind: String) -> Set<String> {
        switch kind {
        case "container": containers
        case "volume": volumes
        case "network": networks
        case "image": images
        default: []
        }
    }

    private func remove(arguments: [String]) {
        switch arguments[0] {
        case "container":
            containers.subtract(arguments.dropFirst(3))
        case "volume":
            volumes.subtract(arguments.dropFirst(2))
        case "network":
            networks.subtract(arguments.dropFirst(2))
        case "image":
            images.subtract(arguments.dropFirst(2))
        default:
            break
        }
    }
}

private extension CommandResult {
    static func cleanupSuccess(_ output: String) -> CommandResult {
        CommandResult(
            exitCode: 0,
            standardOutput: output,
            standardError: ""
        )
    }

    static func cleanupFailure(_ error: String) -> CommandResult {
        CommandResult(
            exitCode: 1,
            standardOutput: "",
            standardError: error
        )
    }
}
