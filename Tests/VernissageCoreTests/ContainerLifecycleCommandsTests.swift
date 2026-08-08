import Testing
@testable import VernissageCore

struct ContainerLifecycleCommandsTests {
    @Test
    func `Start changes only the selected managed service`() throws {
        let runner = LifecycleCommandRunner(results: [
            .success("/vernissage-abcdefgh-api"),
            .success("vernissage-abcdefgh-api")
        ])
        let containers = managedContainers()

        let changed = try ContainerLifecycleController(
            commandRunner: runner
        ).perform(
            action: .start,
            target: "API",
            containers: containers
        )

        #expect(changed == [containers[1]])
        #expect(runner.invocations == [
            LifecycleDockerInvocation(
                executable: "docker",
                arguments: [
                    "container", "inspect", "--format", "{{.Name}}",
                    "vernissage-abcdefgh-api"
                ]
            ),
            LifecycleDockerInvocation(
                executable: "docker",
                arguments: [
                    "container", "start", "vernissage-abcdefgh-api"
                ]
            )
        ])
    }

    @Test
    func `Stop all uses reverse dependency order`() throws {
        let runner = LifecycleCommandRunner(results: [
            .success("verified"),
            .success("stopped")
        ])
        let containers = managedContainers()

        let changed = try ContainerLifecycleController(
            commandRunner: runner
        ).perform(
            action: .stop,
            target: "all",
            containers: containers
        )

        let expected = Array(containers.reversed())
        #expect(changed == expected)
        #expect(runner.invocations[0].arguments == [
            "container", "inspect", "--format", "{{.Name}}"
        ] + expected.map(\.name))
        #expect(runner.invocations[1].arguments == [
            "container", "stop"
        ] + expected.map(\.name))
    }

    @Test
    func `Restart all keeps infrastructure before applications`() throws {
        let runner = LifecycleCommandRunner(results: [
            .success("verified"),
            .success("restarted")
        ])
        let containers = managedContainers()

        let changed = try ContainerLifecycleController(
            commandRunner: runner
        ).perform(
            action: .restart,
            target: "ALL",
            containers: containers
        )

        #expect(changed == containers)
        #expect(runner.invocations[1].arguments == [
            "container", "restart"
        ] + containers.map(\.name))
    }

    @Test(
        arguments: [
            (selector: "postgres", service: "PostgreSQL"),
            (selector: "postgresql", service: "PostgreSQL"),
            (selector: "caddy", service: "HTTPS"),
            (selector: "https", service: "HTTPS")
        ]
    )
    func `Service aliases select installer-managed container`(
        selector: String,
        service: String
    ) throws {
        let runner = LifecycleCommandRunner(results: [
            .success("verified"),
            .success("started")
        ])

        let changed = try ContainerLifecycleController(
            commandRunner: runner
        ).perform(
            action: .start,
            target: selector,
            containers: managedContainers()
        )

        #expect(changed.map(\.service) == [service])
    }

    @Test
    func `Known external service cannot be changed`() {
        let runner = LifecycleCommandRunner(results: [])
        let containers = managedContainers().filter { $0.service != "PostgreSQL" }

        let error = #expect(throws: ContainerLifecycleError.self) {
            try ContainerLifecycleController(commandRunner: runner).perform(
                action: .start,
                target: "postgres",
                containers: containers
            )
        }

        #expect(
            error == .serviceNotManaged(
                target: "postgres",
                available: ["api", "web", "https"]
            )
        )
        #expect(runner.invocations.isEmpty)
    }

    @Test
    func `Unknown service reports available managed selectors`() {
        let runner = LifecycleCommandRunner(results: [])

        let error = #expect(throws: ContainerLifecycleError.self) {
            try ContainerLifecycleController(commandRunner: runner).perform(
                action: .stop,
                target: "mail",
                containers: managedContainers()
            )
        }

        #expect(
            error == .unknownService(
                target: "mail",
                available: ["postgresql", "api", "web", "https"]
            )
        )
        #expect(error?.localizedDescription.contains("all") == true)
        #expect(runner.invocations.isEmpty)
    }

    @Test
    func `Missing container prevents lifecycle action`() {
        let runner = LifecycleCommandRunner(results: [
            CommandResult(
                exitCode: 1,
                standardOutput: "",
                standardError: "No such container: vernissage-abcdefgh-web"
            )
        ])

        let error = #expect(throws: ContainerLifecycleError.self) {
            try ContainerLifecycleController(commandRunner: runner).perform(
                action: .restart,
                target: "all",
                containers: managedContainers()
            )
        }

        #expect(
            error == .inspectionFailed(
                "No such container: vernissage-abcdefgh-web"
            )
        )
        #expect(runner.invocations.count == 1)
    }

    @Test
    func `Docker lifecycle failure is reported after successful verification`() {
        let runner = LifecycleCommandRunner(results: [
            .success("verified"),
            CommandResult(
                exitCode: 1,
                standardOutput: "",
                standardError: "permission denied"
            )
        ])

        let error = #expect(throws: ContainerLifecycleError.self) {
            try ContainerLifecycleController(commandRunner: runner).perform(
                action: .stop,
                target: "web",
                containers: managedContainers()
            )
        }

        #expect(
            error == .actionFailed(action: .stop, details: "permission denied")
        )
        #expect(runner.invocations.count == 2)
    }

    @Test
    func `Start command parses service global configuration and color option`() throws {
        let parsed = try VernissageCommand.parseAsRoot([
            "--config", "/srv/vernissage/vernissage.yml",
            "start", "api", "--no-color"
        ])
        let command = try #require(parsed as? StartCommand)

        #expect(command.service == "api")
        #expect(command.configurationOptions.configPath == "/srv/vernissage/vernissage.yml")
        #expect(command.noColor)
    }

    @Test
    func `Stop command parses service and subcommand configuration`() throws {
        let parsed = try VernissageCommand.parseAsRoot([
            "stop", "all", "--config", "/srv/vernissage/vernissage.yml"
        ])
        let command = try #require(parsed as? StopCommand)

        #expect(command.service == "all")
        #expect(command.configurationOptions.configPath == "/srv/vernissage/vernissage.yml")
    }

    @Test
    func `Restart command parses service selector`() throws {
        let parsed = try VernissageCommand.parseAsRoot(["restart", "push"])
        let command = try #require(parsed as? RestartCommand)

        #expect(command.service == "push")
    }

    private func managedContainers() -> [ManagedContainer] {
        [
            ManagedContainer(
                service: "PostgreSQL",
                name: "vernissage-abcdefgh-postgres",
                expectedImage: "postgres:18"
            ),
            ManagedContainer(
                service: "API",
                name: "vernissage-abcdefgh-api",
                expectedImage: "server:latest"
            ),
            ManagedContainer(
                service: "Web",
                name: "vernissage-abcdefgh-web",
                expectedImage: "web:latest"
            ),
            ManagedContainer(
                service: "HTTPS",
                name: "vernissage-abcdefgh-caddy",
                expectedImage: "caddy:latest"
            )
        ]
    }
}

private struct LifecycleDockerInvocation: Equatable {
    let executable: String
    let arguments: [String]
}

private enum LifecycleCommandRunnerError: Error {
    case resultNotConfigured
}

private final class LifecycleCommandRunner: CommandRunning {
    private var results: [CommandResult]
    private(set) var invocations: [LifecycleDockerInvocation] = []

    init(results: [CommandResult]) {
        self.results = results
    }

    func run(
        _ executable: String,
        arguments: [String],
        environment: [String: String],
        standardInput: String?
    ) throws -> CommandResult {
        invocations.append(
            LifecycleDockerInvocation(
                executable: executable,
                arguments: arguments
            )
        )
        guard results.isEmpty == false else {
            throw LifecycleCommandRunnerError.resultNotConfigured
        }
        return results.removeFirst()
    }
}

private extension CommandResult {
    static func success(_ output: String) -> CommandResult {
        CommandResult(exitCode: 0, standardOutput: output, standardError: "")
    }
}
