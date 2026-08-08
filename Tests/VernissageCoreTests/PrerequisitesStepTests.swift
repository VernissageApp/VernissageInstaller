import Testing
@testable import VernissageCore

struct PrerequisitesStepTests {
    @Test
    func `Available docker environment is stored in context`() throws {
        let runner = StubCommandRunner(results: [
            CommandResult(
                exitCode: 0,
                standardOutput: "Docker version 28.3.3",
                standardError: ""
            ),
            CommandResult(
                exitCode: 0,
                standardOutput: "28.3.3",
                standardError: ""
            ),
            CommandResult(
                exitCode: 0,
                standardOutput: "Docker Compose version v2.39.1",
                standardError: ""
            )
        ])
        let output = PrerequisitesOutputBuffer()
        let context = InstallationContext(instanceIdentifier: "abcdefgh")
        let step = PrerequisitesStep(
            console: Console(
                colorsEnabled: false,
                writeOutput: output.append
            ),
            commandRunner: runner
        )

        try step.run(context: context)

        #expect(
            context.docker == DockerEnvironment(
                clientVersion: "Docker version 28.3.3",
                serverVersion: "28.3.3",
                composeVersion: "Docker Compose version v2.39.1"
            )
        )
        #expect(runner.invocations == [
            DockerInvocation(executable: "docker", arguments: ["--version"]),
            DockerInvocation(
                executable: "docker",
                arguments: ["info", "--format", "{{.ServerVersion}}"]
            ),
            DockerInvocation(executable: "docker", arguments: ["compose", "version"])
        ])
        #expect(output.text.contains(InstallationStepGuidance.prerequisites))
        #expect(output.text.contains("Docker daemon: 28.3.3"))
    }

    @Test
    func `Missing Docker CLI stops installer`() {
        let runner = StubCommandRunner(results: [
            CommandResult(
                exitCode: 127,
                standardOutput: "",
                standardError: "docker: command not found"
            )
        ])
        let context = InstallationContext(instanceIdentifier: "abcdefgh")
        let step = makeStep(runner: runner)

        let error = #expect(throws: PrerequisitesError.self) {
            try step.run(context: context)
        }
        #expect(error == .dockerCLIUnavailable("docker: command not found"))
        #expect(context.docker == nil)
    }

    @Test
    func `Unavailable Docker daemon stops installer`() {
        let runner = StubCommandRunner(results: [
            CommandResult(
                exitCode: 0,
                standardOutput: "Docker version 28.3.3",
                standardError: ""
            ),
            CommandResult(
                exitCode: 1,
                standardOutput: "",
                standardError: "Cannot connect to the Docker daemon"
            )
        ])
        let context = InstallationContext(instanceIdentifier: "abcdefgh")
        let step = makeStep(runner: runner)

        let error = #expect(throws: PrerequisitesError.self) {
            try step.run(context: context)
        }
        #expect(error == .dockerDaemonUnavailable("Cannot connect to the Docker daemon"))
        #expect(context.docker == nil)
    }

    @Test
    func `Missing Docker Compose stops installer`() {
        let runner = StubCommandRunner(results: [
            CommandResult(
                exitCode: 0,
                standardOutput: "Docker version 28.3.3",
                standardError: ""
            ),
            CommandResult(
                exitCode: 0,
                standardOutput: "28.3.3",
                standardError: ""
            ),
            CommandResult(
                exitCode: 1,
                standardOutput: "",
                standardError: "docker: 'compose' is not a docker command"
            )
        ])
        let context = InstallationContext(instanceIdentifier: "abcdefgh")
        let step = makeStep(runner: runner)

        let error = #expect(throws: PrerequisitesError.self) {
            try step.run(context: context)
        }
        #expect(error == .dockerComposeUnavailable("docker: 'compose' is not a docker command"))
        #expect(context.docker == nil)
    }

    private func makeStep(runner: StubCommandRunner) -> PrerequisitesStep {
        PrerequisitesStep(
            console: Console(
                colorsEnabled: false,
                writeOutput: { _ in }
            ),
            commandRunner: runner
        )
    }
}

private struct DockerInvocation: Equatable {
    let executable: String
    let arguments: [String]
    let environment: [String: String]
    let standardInput: String?

    init(
        executable: String,
        arguments: [String],
        environment: [String: String] = [:],
        standardInput: String? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.standardInput = standardInput
    }
}

private enum StubCommandRunnerError: Error {
    case resultNotConfigured
}

private final class StubCommandRunner: CommandRunning {
    private var results: [CommandResult]
    private(set) var invocations: [DockerInvocation] = []

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
            DockerInvocation(
                executable: executable,
                arguments: arguments,
                environment: environment,
                standardInput: standardInput
            )
        )

        guard results.isEmpty == false else {
            throw StubCommandRunnerError.resultNotConfigured
        }

        return results.removeFirst()
    }
}

private final class PrerequisitesOutputBuffer {
    private(set) var text = ""

    func append(_ value: String) {
        text += value
    }
}
