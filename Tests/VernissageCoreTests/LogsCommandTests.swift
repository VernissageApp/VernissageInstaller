import Testing
@testable import VernissageCore

struct LogsCommandTests {
    @Test
    func `Service logs are streamed from the selected Docker container`() throws {
        let runner = LogsStreamingRunner(results: [
            StreamingCommandResult(exitCode: 0)
        ])
        let containers = managedContainers()

        let selected = try ContainerLogsController(
            commandRunner: runner
        ).showLogs(
            for: "api",
            follow: false,
            containers: containers
        )

        #expect(selected == containers[1])
        #expect(runner.invocations == [
            LogsStreamingInvocation(
                executable: "docker",
                arguments: [
                    "container", "logs", "vernissage-abcdefgh-api"
                ]
            )
        ])
    }

    @Test
    func `Follow streams new Docker logs until the process is interrupted`() throws {
        let runner = LogsStreamingRunner(results: [
            StreamingCommandResult(exitCode: 0)
        ])

        _ = try ContainerLogsController(
            commandRunner: runner
        ).showLogs(
            for: "jobs",
            follow: true,
            containers: managedContainers()
        )

        #expect(runner.invocations[0].arguments == [
            "container", "logs", "--follow", "vernissage-abcdefgh-jobs"
        ])
    }

    @Test(
        arguments: [
            (selector: "postgres", service: "PostgreSQL"),
            (selector: "postgresql", service: "PostgreSQL"),
            (selector: "caddy", service: "HTTPS"),
            (selector: "https", service: "HTTPS")
        ]
    )
    func `Service aliases select the managed log source`(
        selector: String,
        service: String
    ) throws {
        let runner = LogsStreamingRunner(results: [
            StreamingCommandResult(exitCode: 0)
        ])

        let selected = try ContainerLogsController(
            commandRunner: runner
        ).showLogs(
            for: selector,
            follow: false,
            containers: managedContainers()
        )

        #expect(selected.service == service)
    }

    @Test
    func `External service cannot be used as a Docker log source`() {
        let runner = LogsStreamingRunner(results: [])
        let containers = managedContainers().filter {
            $0.service != "PostgreSQL"
        }

        let error = #expect(throws: ContainerLogsError.self) {
            try ContainerLogsController(commandRunner: runner).showLogs(
                for: "postgres",
                follow: false,
                containers: containers
            )
        }

        #expect(error == .serviceNotManaged(
            target: "postgres",
            available: ["api", "jobs", "https"]
        ))
        #expect(runner.invocations.isEmpty)
    }

    @Test
    func `Unknown service reports available managed log sources`() {
        let runner = LogsStreamingRunner(results: [])

        let error = #expect(throws: ContainerLogsError.self) {
            try ContainerLogsController(commandRunner: runner).showLogs(
                for: "mail",
                follow: false,
                containers: managedContainers()
            )
        }

        #expect(error == .unknownService(
            target: "mail",
            available: ["postgresql", "api", "jobs", "https"]
        ))
        #expect(runner.invocations.isEmpty)
    }

    @Test
    func `Docker log exit failure is reported`() {
        let runner = LogsStreamingRunner(results: [
            StreamingCommandResult(exitCode: 1)
        ])

        #expect(throws: ContainerLogsError.dockerExited(1)) {
            try ContainerLogsController(commandRunner: runner).showLogs(
                for: "api",
                follow: false,
                containers: managedContainers()
            )
        }
    }

    @Test
    func `Control C interruption finishes log streaming without an error`() throws {
        let runner = LogsStreamingRunner(results: [
            StreamingCommandResult(exitCode: 2, wasInterrupted: true)
        ])
        let containers = managedContainers()

        let selected = try ContainerLogsController(
            commandRunner: runner
        ).showLogs(
            for: "api",
            follow: true,
            containers: containers
        )

        #expect(selected == containers[1])
        #expect(runner.invocations == [
            LogsStreamingInvocation(
                executable: "docker",
                arguments: [
                    "container", "logs", "--follow",
                    "vernissage-abcdefgh-api"
                ]
            )
        ])
    }

    @Test
    func `Docker log launch failure is reported`() {
        let runner = LogsStreamingRunner(
            results: [],
            error: LogsStreamingRunnerError.unavailable
        )

        let error = #expect(throws: ContainerLogsError.self) {
            try ContainerLogsController(commandRunner: runner).showLogs(
                for: "api",
                follow: false,
                containers: managedContainers()
            )
        }

        #expect(error?.localizedDescription.contains(
            "Docker logs could not be started"
        ) == true)
    }

    @Test
    func `Logs command parses service configuration and follow option`() throws {
        let parsed = try VernissageCommand.parseAsRoot([
            "--config", "/srv/vernissage/vernissage.yml",
            "logs", "push", "--follow"
        ])
        let command = try #require(parsed as? LogsCommand)

        #expect(command.service == "push")
        #expect(command.follow)
        #expect(
            command.configurationOptions.configPath
                == "/srv/vernissage/vernissage.yml"
        )
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
                service: "Jobs",
                name: "vernissage-abcdefgh-jobs",
                expectedImage: "server:latest"
            ),
            ManagedContainer(
                service: "HTTPS",
                name: "vernissage-abcdefgh-caddy",
                expectedImage: "caddy:latest"
            )
        ]
    }
}

private struct LogsStreamingInvocation: Equatable {
    let executable: String
    let arguments: [String]
}

private enum LogsStreamingRunnerError: Error {
    case unavailable
    case resultNotConfigured
}

private final class LogsStreamingRunner: StreamingCommandRunning {
    private var results: [StreamingCommandResult]
    private let error: LogsStreamingRunnerError?
    private(set) var invocations: [LogsStreamingInvocation] = []

    init(
        results: [StreamingCommandResult],
        error: LogsStreamingRunnerError? = nil
    ) {
        self.results = results
        self.error = error
    }

    func runStreaming(
        _ executable: String,
        arguments: [String],
        environment: [String: String]
    ) throws -> StreamingCommandResult {
        invocations.append(
            LogsStreamingInvocation(
                executable: executable,
                arguments: arguments
            )
        )
        if let error {
            throw error
        }
        guard results.isEmpty == false else {
            throw LogsStreamingRunnerError.resultNotConfigured
        }
        return results.removeFirst()
    }
}
