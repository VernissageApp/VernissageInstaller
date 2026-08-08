import Testing
@testable import VernissageCore

@Suite(.tags(.networking, .web))
struct WebStepTests {
    @Test
    func `Custom image origin configures CSP and allowed hosts`() throws {
        let runner = WebCommandRunner(results: [
            .failure("container not found"),
            .success("vernissage-abcdefgh-network"),
            .success("image pulled"),
            .success("web-container-id"),
            .failure("connection refused"),
            .success("")
        ])
        let output = WebOutputBuffer()
        let retries = WebRetryCounter()
        let context = makeContext()
        let step = makeStep(
            runner: runner,
            input: WebInputQueue(["https://media.example.com/"]),
            output: output,
            waitBeforeRetry: retries.increment
        )

        try step.run(context: context)

        let configuration = try #require(context.web)
        #expect(configuration.image == "mczachurski/vernissage-web:latest")
        #expect(configuration.containerName == "vernissage-abcdefgh-web")
        #expect(configuration.networkName == "vernissage-abcdefgh-network")
        #expect(configuration.networkAlias == "vernissage-web.internal")
        #expect(configuration.allowedHosts == "social.example.com,*.social.example.com")
        #expect(configuration.cspImageSource == "https://media.example.com")
        #expect(retries.value == 1)

        let start = runner.invocations[3]
        #expect(start.arguments.first == "run")
        #expect(start.arguments.containsSequence(["--network", "vernissage-abcdefgh-network"]))
        #expect(start.arguments.containsSequence(["--network-alias", "vernissage-web.internal"]))
        #expect(start.arguments.containsSequence(["--env", "VERNISSAGE_ALLOWED_HOSTS"]))
        #expect(start.arguments.containsSequence(["--env", "VERNISSAGE_CSP_IMG"]))
        #expect(start.arguments.last == "mczachurski/vernissage-web:latest")
        #expect(start.arguments.contains("--publish") == false)
        #expect(start.arguments.contains("-p") == false)
        #expect(start.environment["VERNISSAGE_ALLOWED_HOSTS"] == "social.example.com,*.social.example.com")
        #expect(start.environment["VERNISSAGE_CSP_IMG"] == "https://media.example.com")

        let health = runner.invocations[5]
        #expect(
            health.arguments.contains {
                $0.contains("http://127.0.0.1:8080/robots.txt")
            }
        )
        #expect(output.text.contains(InstallationStepGuidance.web))
        #expect(output.text.contains("Vernissage Web is running"))
    }

    @Test
    func `Empty image origin omits CSP environment variable`() throws {
        let runner = WebCommandRunner(results: successfulResults())
        let context = makeContext()
        let step = makeStep(
            runner: runner,
            input: WebInputQueue([""]),
            output: WebOutputBuffer()
        )

        try step.run(context: context)

        let configuration = try #require(context.web)
        #expect(configuration.cspImageSource == nil)
        let start = runner.invocations[3]
        #expect(start.environment["VERNISSAGE_CSP_IMG"] == nil)
        #expect(start.arguments.contains("VERNISSAGE_CSP_IMG") == false)
        #expect(start.environment["VERNISSAGE_ALLOWED_HOSTS"] == "social.example.com,*.social.example.com")
    }

    @Test
    func `Invalid image origin is requested again`() throws {
        let runner = WebCommandRunner(results: successfulResults())
        let output = WebOutputBuffer()
        let context = makeContext()
        let step = makeStep(
            runner: runner,
            input: WebInputQueue(["media.example.com/path", "https://cdn.example.com"]),
            output: output
        )

        try step.run(context: context)

        #expect(context.web?.cspImageSource == "https://cdn.example.com")
        #expect(output.text.contains("Enter an HTTP or HTTPS origin"))
    }

    @Test
    func `Existing Web container is never replaced`() {
        let runner = WebCommandRunner(results: [.success("existing-container")])
        let context = makeContext()
        let step = makeStep(
            runner: runner,
            input: WebInputQueue([""]),
            output: WebOutputBuffer()
        )

        let error = #expect(throws: WebStepError.self) {
            try step.run(context: context)
        }

        #expect(error == .containerAlreadyExists("vernissage-abcdefgh-web"))
        #expect(context.web == nil)
        #expect(runner.invocations.count == 1)
    }

    @Test
    func `Missing server configuration performs no Docker operations`() {
        let runner = WebCommandRunner(results: [])
        let step = makeStep(
            runner: runner,
            input: WebInputQueue([]),
            output: WebOutputBuffer()
        )

        let error = #expect(throws: WebStepError.self) {
            try step.run(context: InstallationContext(instanceIdentifier: "abcdefgh"))
        }

        #expect(error == .missingConfiguration("server and domain"))
        #expect(runner.invocations.isEmpty)
    }

    @Test
    func `Unready Web container is preserved for diagnostics`() {
        let runner = WebCommandRunner(results: [
            .failure("container not found"),
            .success("vernissage-abcdefgh-network"),
            .success("image pulled"),
            .success("web-container-id"),
            .failure("connection refused"),
            .failure("connection refused")
        ])
        let context = makeContext()
        let step = makeStep(
            runner: runner,
            input: WebInputQueue([""]),
            output: WebOutputBuffer(),
            readinessAttempts: 2
        )

        let error = #expect(throws: WebStepError.self) {
            try step.run(context: context)
        }

        #expect(error == .startupTimedOut("connection refused"))
        #expect(context.web == nil)
        #expect(runner.invocations.count == 6)
        #expect(
            runner.invocations.contains {
                $0.arguments.first == "container" && $0.arguments.contains("rm")
            } == false
        )
    }

    private func makeContext() -> InstallationContext {
        let context = InstallationContext(instanceIdentifier: "abcdefgh")
        context.server = ServerConfiguration(domain: "social.example.com")
        let health = ServerHealth(
            isDatabaseHealthy: true,
            isQueueHealthy: true,
            isWebPushHealthy: false,
            isStorageHealthy: true
        )
        context.serverServices = ServerServicesConfiguration(
            image: "mczachurski/vernissage-server:latest",
            networkName: "vernissage-abcdefgh-network",
            apiContainerName: "vernissage-abcdefgh-api",
            jobsContainerName: "vernissage-abcdefgh-jobs",
            apiNetworkAlias: "vernissage-api.internal",
            jobsNetworkAlias: "vernissage-jobs.internal",
            baseAddress: "https://social.example.com",
            apiHealth: health,
            jobsHealth: health,
            databaseTables: ["Users"]
        )
        return context
    }

    private func makeStep(
        runner: WebCommandRunner,
        input: WebInputQueue,
        output: WebOutputBuffer,
        waitBeforeRetry: @escaping () -> Void = {},
        readinessAttempts: Int = 3
    ) -> WebStep {
        WebStep(
            console: Console(
                colorsEnabled: false,
                readInput: input.next,
                writeOutput: output.append
            ),
            commandRunner: runner,
            waitBeforeRetry: waitBeforeRetry,
            readinessAttempts: readinessAttempts
        )
    }

    private func successfulResults() -> [CommandResult] {
        [
            .failure("container not found"),
            .success("vernissage-abcdefgh-network"),
            .success("image pulled"),
            .success("web-container-id"),
            .success("")
        ]
    }
}

private struct WebCommandInvocation {
    let executable: String
    let arguments: [String]
    let environment: [String: String]
}

private enum WebCommandRunnerError: Error {
    case resultNotConfigured
}

private final class WebCommandRunner: CommandRunning {
    private var results: [CommandResult]
    private(set) var invocations: [WebCommandInvocation] = []

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
            WebCommandInvocation(
                executable: executable,
                arguments: arguments,
                environment: environment
            )
        )
        guard results.isEmpty == false else {
            throw WebCommandRunnerError.resultNotConfigured
        }
        return results.removeFirst()
    }
}

private final class WebInputQueue {
    private var values: [String]

    init(_ values: [String]) {
        self.values = values
    }

    func next() -> String? {
        guard values.isEmpty == false else { return nil }
        return values.removeFirst()
    }
}

private final class WebOutputBuffer {
    private(set) var text = ""

    func append(_ value: String) {
        text += value
    }
}

private final class WebRetryCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private extension Array where Element == String {
    func containsSequence(_ sequence: [String]) -> Bool {
        guard sequence.isEmpty == false, sequence.count <= count else { return false }
        return indices.contains { index in
            let end = index + sequence.count
            guard end <= count else { return false }
            return Array(self[index..<end]) == sequence
        }
    }
}

private extension CommandResult {
    static func success(_ output: String) -> CommandResult {
        CommandResult(exitCode: 0, standardOutput: output, standardError: "")
    }

    static func failure(_ error: String) -> CommandResult {
        CommandResult(exitCode: 1, standardOutput: "", standardError: error)
    }
}
