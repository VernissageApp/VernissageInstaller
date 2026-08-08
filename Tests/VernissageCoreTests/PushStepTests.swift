import Testing
@testable import VernissageCore

@Suite(.tags(.database, .networking, .push))
struct PushStepTests {
    private let secret = "0123456789abcdefghijklmnopqrstuv"

    @Test
    func `Running Push stores its private configuration in context and PostgreSQL`() throws {
        let runner = PushCommandRunner(results: successfulResults())
        let output = PushOutputBuffer()
        let context = makeContext()
        let step = makeStep(runner: runner, output: output)

        try step.run(context: context)

        let configuration = try #require(context.push)
        #expect(configuration.image == "mczachurski/vernissage-push:latest")
        #expect(configuration.containerName == "vernissage-abcdefgh-push")
        #expect(configuration.networkName == "vernissage-abcdefgh-network")
        #expect(configuration.networkAlias == "vernissage-push.internal")
        #expect(configuration.endpoint == "http://vernissage-push.internal:3000/send")
        #expect(configuration.secretKey.value == secret)
        #expect(configuration.isEnabled == false)

        let start = runner.invocations[3]
        #expect(start.arguments.containsSequence(["--network", "vernissage-abcdefgh-network"]))
        #expect(start.arguments.containsSequence(["--network-alias", "vernissage-push.internal"]))
        #expect(start.arguments.containsSequence(["--env", "VPUSH_KEY"]))
        #expect(start.arguments.last == "mczachurski/vernissage-push:latest")
        #expect(start.arguments.contains("--publish") == false)
        #expect(start.environment["VPUSH_KEY"] == secret)

        let health = runner.invocations[4]
        #expect(health.arguments.contains { $0.contains("http://127.0.0.1:3000/") })
        #expect(health.arguments.contains { $0.contains("Server is up and running...") })

        let databaseUpdate = runner.invocations[5]
        let sql = try #require(databaseUpdate.standardInput)
        #expect(databaseUpdate.arguments.contains("--command") == false)
        #expect(databaseUpdate.arguments.contains("--interactive"))
        #expect(databaseUpdate.environment["PGPASSWORD"] == "db-secret")
        #expect(databaseUpdate.environment["PGSSLMODE"] == "require")
        #expect(sql.contains("\"key\" = 'webPushSecretKey'"))
        #expect(sql.contains("\"value\" = '\(secret)'"))
        #expect(sql.contains("\"key\" = 'webPushEndpoint'"))
        #expect(sql.contains("http://vernissage-push.internal:3000/send"))
        #expect(sql.contains("\"key\" = 'isWebPushEnabled'"))
        #expect(sql.contains("\"value\" = '0'"))

        for invocation in runner.invocations {
            #expect(invocation.arguments.joined(separator: " ").contains(secret) == false)
        }
        #expect(output.text.contains(secret) == false)
        #expect(output.text.contains(InstallationStepGuidance.push))
        #expect(output.text.contains("WebPush remains disabled"))
    }

    @Test
    func `Generated shared key contains 32 portable characters`() {
        let key = PushStep.generateSecretKey()

        #expect(key.count == 32)
        #expect(key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) })
    }

    @Test
    func `Invalid generated shared key stops before Docker operations`() {
        let runner = PushCommandRunner(results: [])
        let context = makeContext()
        let step = makeStep(
            runner: runner,
            output: PushOutputBuffer(),
            makeSecretKey: { "too-short" }
        )

        let error = #expect(throws: PushStepError.self) {
            try step.run(context: context)
        }

        #expect(error == .invalidGeneratedSecret)
        #expect(context.push == nil)
        #expect(runner.invocations.isEmpty)
    }

    @Test
    func `Unavailable Push endpoint is retried before settings are saved`() throws {
        let runner = PushCommandRunner(results: [
            .failure("container not found"),
            .success("vernissage-abcdefgh-network"),
            .success("image pulled"),
            .success("push-container-id"),
            .failure("connection refused"),
            .success(""),
            .success("3")
        ])
        let retries = PushRetryCounter()
        let context = makeContext()
        let step = makeStep(
            runner: runner,
            output: PushOutputBuffer(),
            waitBeforeRetry: retries.increment
        )

        try step.run(context: context)

        #expect(retries.value == 1)
        #expect(context.push != nil)
        #expect(runner.invocations.count == 7)
    }

    @Test
    func `Database failure preserves running Push container for diagnostics`() {
        let runner = PushCommandRunner(results: [
            .failure("container not found"),
            .success("vernissage-abcdefgh-network"),
            .success("image pulled"),
            .success("push-container-id"),
            .success(""),
            .failure("setting was not found")
        ])
        let context = makeContext()
        let step = makeStep(runner: runner, output: PushOutputBuffer())

        let error = #expect(throws: PushStepError.self) {
            try step.run(context: context)
        }

        #expect(error == .settingsUpdateFailed("setting was not found"))
        #expect(context.push == nil)
        #expect(
            runner.invocations.contains {
                $0.arguments.first == "container" && $0.arguments.contains("rm")
            } == false
        )
    }

    @Test
    func `Existing Push container is never replaced`() {
        let runner = PushCommandRunner(results: [.success("existing-container")])
        let context = makeContext()
        let step = makeStep(runner: runner, output: PushOutputBuffer())

        let error = #expect(throws: PushStepError.self) {
            try step.run(context: context)
        }

        #expect(error == .containerAlreadyExists("vernissage-abcdefgh-push"))
        #expect(context.push == nil)
        #expect(runner.invocations.count == 1)
    }

    @Test
    func `Localhost PostgreSQL on macOS uses Docker host gateway`() throws {
        let runner = PushCommandRunner(results: successfulResults())
        let context = makeContext(databaseHost: "localhost")
        let step = makeStep(
            runner: runner,
            output: PushOutputBuffer(),
            operatingSystem: .macOS
        )

        try step.run(context: context)

        let databaseUpdate = runner.invocations[5]
        #expect(databaseUpdate.value(after: "--host") == "host.docker.internal")
        #expect(databaseUpdate.arguments.contains("--network") == false)
    }

    @Test
    func `Localhost PostgreSQL on Linux uses host network`() throws {
        let runner = PushCommandRunner(results: successfulResults())
        let context = makeContext(databaseHost: "localhost")
        let step = makeStep(runner: runner, output: PushOutputBuffer())

        try step.run(context: context)

        let databaseUpdate = runner.invocations[5]
        #expect(databaseUpdate.value(after: "--network") == "host")
        #expect(databaseUpdate.value(after: "--host") == "localhost")
    }

    @Test
    func `Missing database configuration performs no Docker operations`() {
        let runner = PushCommandRunner(results: [])
        let step = makeStep(runner: runner, output: PushOutputBuffer())

        let error = #expect(throws: PushStepError.self) {
            try step.run(context: InstallationContext(instanceIdentifier: "abcdefgh"))
        }

        #expect(error == .missingConfiguration("PostgreSQL database"))
        #expect(runner.invocations.isEmpty)
    }

    private func makeStep(
        runner: PushCommandRunner,
        output: PushOutputBuffer,
        waitBeforeRetry: @escaping () -> Void = {},
        readinessAttempts: Int = 3,
        operatingSystem: HostOperatingSystem = .linux,
        makeSecretKey: @escaping () -> String = { "0123456789abcdefghijklmnopqrstuv" }
    ) -> PushStep {
        PushStep(
            console: Console(
                colorsEnabled: false,
                readInput: { nil },
                writeOutput: output.append
            ),
            commandRunner: runner,
            waitBeforeRetry: waitBeforeRetry,
            readinessAttempts: readinessAttempts,
            operatingSystem: operatingSystem,
            makeSecretKey: makeSecretKey
        )
    }

    private func makeContext(databaseHost: String = "db.example.com") -> InstallationContext {
        let context = InstallationContext(instanceIdentifier: "abcdefgh")
        context.database = DatabaseConfiguration(
            mode: .existing,
            host: databaseHost,
            port: 5432,
            database: "vernissage",
            username: "vernissage",
            password: Secret(value: "db-secret"),
            tlsMode: .require,
            localResources: nil
        )
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
            databaseTables: ["Settings"]
        )
        return context
    }

    private func successfulResults() -> [CommandResult] {
        [
            .failure("container not found"),
            .success("vernissage-abcdefgh-network"),
            .success("image pulled"),
            .success("push-container-id"),
            .success(""),
            .success("3")
        ]
    }
}

private struct PushCommandInvocation {
    let executable: String
    let arguments: [String]
    let environment: [String: String]
    let standardInput: String?

    func value(after option: String) -> String? {
        guard let index = arguments.firstIndex(of: option),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}

private enum PushCommandRunnerError: Error {
    case resultNotConfigured
}

private final class PushCommandRunner: CommandRunning {
    private var results: [CommandResult]
    private(set) var invocations: [PushCommandInvocation] = []

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
            PushCommandInvocation(
                executable: executable,
                arguments: arguments,
                environment: environment,
                standardInput: standardInput
            )
        )
        guard results.isEmpty == false else {
            throw PushCommandRunnerError.resultNotConfigured
        }
        return results.removeFirst()
    }
}

private final class PushOutputBuffer {
    private(set) var text = ""

    func append(_ value: String) {
        text += value
    }
}

private final class PushRetryCounter {
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
