import Testing
@testable import VernissageCore

@Suite(.tags(.redis))
struct RedisStepTests {
    @Test
    func `Existing Redis fields are assembled tested and stored`() throws {
        let runner = RedisCommandRunner(results: successfulRedisTestResults())
        let output = RedisOutputBuffer()
        let context = InstallationContext(instanceIdentifier: "abcdefgh")
        let step = makeStep(
            input: RedisInputQueue(["2", "default", "redis.example.com", "6380", "1"]),
            secureInput: RedisInputQueue(["redis-secret"]),
            output: output,
            runner: runner
        )

        try step.run(context: context)

        let configuration = try #require(context.redis)
        #expect(configuration.mode == .existing)
        #expect(configuration.url.value == "rediss://default:redis-secret@redis.example.com:6380/0")
        #expect(configuration.username == "default")
        #expect(configuration.host == "redis.example.com")
        #expect(configuration.port == 6380)
        #expect(configuration.database == 0)
        #expect(configuration.password?.value == "redis-secret")
        #expect(configuration.usesTLS)
        #expect(configuration.localResources == nil)
        #expect(runner.invocations.count == 4)

        let ping = runner.invocations[0]
        #expect(ping.arguments.containsSequence(["-h", "redis.example.com"]))
        #expect(ping.arguments.containsSequence(["-p", "6380"]))
        #expect(ping.arguments.containsSequence(["-n", "0"]))
        #expect(ping.arguments.contains("--tls"))
        #expect(ping.environment["REDISCLI_AUTH"] == "redis-secret")
        #expect(ping.arguments.contains("redis-secret") == false)
        #expect(output.text.contains(InstallationStepGuidance.redis))
        #expect(output.text.contains("Choose your option:"))
        #expect(output.text.contains("redis-secret") == false)
    }

    @Test
    func `Redis defaults and reserved password characters produce a valid URL`() throws {
        let runner = RedisCommandRunner(results: successfulRedisTestResults())
        let output = RedisOutputBuffer()
        let context = InstallationContext(instanceIdentifier: "abcdefgh")
        let step = makeStep(
            input: RedisInputQueue(["2", "", "redis.example.com", "", ""]),
            secureInput: RedisInputQueue(["p@ss/word"]),
            output: output,
            runner: runner
        )

        try step.run(context: context)

        let configuration = try #require(context.redis)
        #expect(configuration.username == "default")
        #expect(configuration.port == 6379)
        #expect(configuration.usesTLS)
        #expect(configuration.url.value == "rediss://default:p%40ss%2Fword@redis.example.com:6379/0")
        #expect(output.text.contains("p@ss/word") == false)
        #expect(runner.invocations.allSatisfy { $0.arguments.contains("p@ss/word") == false })
    }

    @Test
    func `Existing localhost Redis on macOS uses the Docker host gateway`() throws {
        let runner = RedisCommandRunner(results: successfulRedisTestResults())
        let step = makeExistingStep(
            host: "localhost",
            runner: runner,
            operatingSystem: .macOS
        )

        try step.run(context: InstallationContext(instanceIdentifier: "abcdefgh"))

        #expect(runner.invocations.count == 4)
        #expect(
            runner.invocations.allSatisfy {
                $0.value(after: "-h") == "host.docker.internal"
            }
        )
        #expect(runner.invocations.allSatisfy { $0.arguments.contains("--network") == false })
    }

    @Test
    func `Existing localhost Redis on Linux uses the host network`() throws {
        let runner = RedisCommandRunner(results: successfulRedisTestResults())
        let step = makeExistingStep(
            host: "localhost",
            runner: runner,
            operatingSystem: .linux
        )

        try step.run(context: InstallationContext(instanceIdentifier: "abcdefgh"))

        #expect(runner.invocations.count == 4)
        #expect(runner.invocations.allSatisfy { $0.value(after: "-h") == "localhost" })
        #expect(runner.invocations.allSatisfy { $0.value(after: "--network") == "host" })
    }

    @Test
    func `Local Redis container is configured tested and stored`() throws {
        let runner = RedisCommandRunner(results: [
            .failure("container not found"),
            .failure("volume not found"),
            .failure("network not found"),
            .success("vernissage-abcdefgh-network"),
            .success("vernissage-abcdefgh-redis-data"),
            .success("configuration written"),
            .success("container-id"),
            .success("PONG"),
            .success("PONG"),
            .success("OK"),
            .success("redis-test-value"),
            .success("1")
        ])
        let output = RedisOutputBuffer()
        let context = InstallationContext(instanceIdentifier: "abcdefgh")
        let step = makeStep(
            input: RedisInputQueue(["1"]),
            secureInput: RedisInputQueue([]),
            output: output,
            runner: runner
        )

        try step.run(context: context)

        let configuration = try #require(context.redis)
        let resources = try #require(configuration.localResources)
        #expect(configuration.mode == .localContainer)
        #expect(configuration.url.value == "redis://default:local-redis-password@vernissage-abcdefgh-redis:6379/0")
        #expect(configuration.username == "default")
        #expect(configuration.host == "vernissage-abcdefgh-redis")
        #expect(configuration.port == 6379)
        #expect(configuration.database == 0)
        #expect(configuration.password?.value == "local-redis-password")
        #expect(configuration.usesTLS == false)
        #expect(resources.image == "redis:8.8.1-alpine")
        #expect(resources.containerName == "vernissage-abcdefgh-redis")
        #expect(resources.volumeName == "vernissage-abcdefgh-redis-data")
        #expect(resources.networkName == "vernissage-abcdefgh-network")
        #expect(runner.invocations.count == 12)

        let configurationWrite = runner.invocations[5]
        #expect(configurationWrite.arguments.contains("REDIS_PASSWORD"))
        #expect(configurationWrite.arguments.contains { $0.contains("appendonly yes") })
        #expect(configurationWrite.environment["REDIS_PASSWORD"] == "local-redis-password")
        #expect(configurationWrite.arguments.contains("local-redis-password") == false)

        let containerCreation = runner.invocations[6]
        #expect(containerCreation.arguments.containsSequence(["redis-server", "/data/redis.conf"]))
        #expect(containerCreation.environment.isEmpty)

        let set = runner.invocations[9]
        #expect(
            set.arguments.containsSequence([
                "SET",
                "vernissage:installer:test:test-id",
                "redis-test-value",
                "EX",
                "60"
            ])
        )
        #expect(output.text.contains("local-redis-password") == false)
    }

    @Test
    func `Failed Redis SET stops step without storing URL`() {
        let runner = RedisCommandRunner(results: [
            .success("PONG"),
            .failure("permission denied")
        ])
        let context = InstallationContext(instanceIdentifier: "abcdefgh")
        let step = makeExistingStep(
            host: "redis.example.com",
            runner: runner
        )

        let error = #expect(throws: RedisStepError.self) {
            try step.run(context: context)
        }
        #expect(
            error == .redisOperationFailed(
                operation: "write a temporary key",
                details: "permission denied"
            )
        )
        #expect(context.redis == nil)
        #expect(runner.invocations.count == 2)
    }

    @Test
    func `Redis GET value must match the value written by installer`() {
        let runner = RedisCommandRunner(results: [
            .success("PONG"),
            .success("OK"),
            .success("different-value"),
            .success("1")
        ])
        let context = InstallationContext(instanceIdentifier: "abcdefgh")
        let step = makeExistingStep(
            host: "redis.example.com",
            runner: runner
        )

        let error = #expect(throws: RedisStepError.self) {
            try step.run(context: context)
        }
        #expect(
            error == .unexpectedResponse(
                operation: "GET",
                expected: "redis-test-value",
                actual: "different-value"
            )
        )
        #expect(context.redis == nil)
        #expect(runner.invocations.count == 4)
    }

    @Test
    func `Non-default Redis ACL username is rejected`() {
        let output = RedisOutputBuffer()
        let step = makeStep(
            input: RedisInputQueue(["2", "vernissage"]),
            secureInput: RedisInputQueue([]),
            output: output,
            runner: RedisCommandRunner(results: [])
        )

        let error = #expect(throws: RedisStepError.self) {
            try step.run(context: InstallationContext(instanceIdentifier: "abcdefgh"))
        }
        #expect(error == .invalidValue("A Redis username is required."))
        #expect(output.text.contains("supports only the default Redis ACL user"))
        #expect(output.text.contains("redis-secret") == false)
    }

    private func makeExistingStep(
        host: String,
        runner: RedisCommandRunner,
        operatingSystem: HostOperatingSystem = .macOS,
        username: String = "default",
        password: String = "redis-secret",
        port: UInt16 = 6379,
        usesTLS: Bool = false
    ) -> RedisStep {
        makeStep(
            input: RedisInputQueue([
                "2",
                username,
                host,
                String(port),
                usesTLS ? "1" : "2"
            ]),
            secureInput: RedisInputQueue([password]),
            output: RedisOutputBuffer(),
            runner: runner,
            operatingSystem: operatingSystem
        )
    }

    private func makeStep(
        input: RedisInputQueue,
        secureInput: RedisInputQueue,
        output: RedisOutputBuffer,
        runner: RedisCommandRunner,
        operatingSystem: HostOperatingSystem = .macOS
    ) -> RedisStep {
        RedisStep(
            console: Console(
                colorsEnabled: false,
                readInput: input.next,
                readSecureInput: secureInput.next,
                writeOutput: output.append
            ),
            commandRunner: runner,
            makeTestKey: { "vernissage:installer:test:test-id" },
            makeTestValue: { "redis-test-value" },
            makePassword: { Secret(value: "local-redis-password") },
            waitBeforeRetry: {},
            readinessAttempts: 3,
            operatingSystem: operatingSystem
        )
    }

    private func successfulRedisTestResults() -> [CommandResult] {
        [
            .success("PONG"),
            .success("OK"),
            .success("redis-test-value"),
            .success("1")
        ]
    }
}

private struct RedisCommandInvocation {
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

private enum RedisCommandRunnerError: Error {
    case resultNotConfigured
}

private final class RedisCommandRunner: CommandRunning {
    private var results: [CommandResult]
    private(set) var invocations: [RedisCommandInvocation] = []

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
            RedisCommandInvocation(
                executable: executable,
                arguments: arguments,
                environment: environment,
                standardInput: standardInput
            )
        )

        guard results.isEmpty == false else {
            throw RedisCommandRunnerError.resultNotConfigured
        }
        return results.removeFirst()
    }
}

private final class RedisInputQueue {
    private var values: [String]

    init(_ values: [String]) {
        self.values = values
    }

    func next() -> String? {
        guard values.isEmpty == false else { return nil }
        return values.removeFirst()
    }
}

private final class RedisOutputBuffer {
    private(set) var text = ""

    func append(_ value: String) {
        text += value
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
