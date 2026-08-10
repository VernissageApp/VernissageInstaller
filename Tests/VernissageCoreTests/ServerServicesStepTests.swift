import Testing
@testable import VernissageCore

@Suite(.tags(.serverServices))
struct ServerServicesStepTests {
    @Test
    func `API and Jobs share configuration and use correct worker flags`() throws {
        let runner = ServerCommandRunner(results: [
            .failure("API container not found"),
            .failure("Jobs container not found"),
            .success("vernissage-abcdefgh-network"),
            .success("image pulled"),
            .success("api-container-id"),
            .failure("connection refused"),
            .success(healthyResponse),
            .success("Events\nUsers\n_fluent_migrations"),
            .success("jobs-container-id"),
            .success(healthyResponse)
        ])
        let output = ServerOutputBuffer()
        let retries = RetryCounter()
        let context = makeContext()
        let step = makeStep(
            runner: runner,
            output: output,
            waitBeforeRetry: retries.increment,
            operatingSystem: .linux
        )

        try step.run(context: context)

        let configuration = try #require(context.serverServices)
        let apiHealth = try #require(configuration.apiHealth)
        let jobsHealth = try #require(configuration.jobsHealth)
        #expect(configuration.image == "mczachurski/vernissage-server:latest")
        #expect(configuration.apiContainerName == "vernissage-abcdefgh-api")
        #expect(configuration.jobsContainerName == "vernissage-abcdefgh-jobs")
        #expect(configuration.baseAddress == "https://social.example.com")
        #expect(configuration.databaseTables == ["Events", "Users", "_fluent_migrations"])
        #expect(apiHealth.isWebPushHealthy == false)
        #expect(jobsHealth.isWebPushHealthy == false)
        #expect(retries.value == 1)
        #expect(runner.invocations.count == 10)

        let apiStart = runner.invocations[4]
        let jobsStart = runner.invocations[8]
        #expect(apiStart.environment["VERNISSAGE_DISABLEQUEUEJOBS"] == "true")
        #expect(apiStart.environment["VERNISSAGE_DISABLESCHEDULEDJOBS"] == "true")
        #expect(jobsStart.environment["VERNISSAGE_DISABLEQUEUEJOBS"] == "false")
        #expect(jobsStart.environment["VERNISSAGE_DISABLESCHEDULEDJOBS"] == "false")

        let sharedKeys = [
            "VERNISSAGE_BASEADDRESS",
            "VERNISSAGE_CONNECTIONSTRING",
            "VERNISSAGE_QUEUEURL",
            "VERNISSAGE_S3ADDRESS",
            "VERNISSAGE_S3REGION",
            "VERNISSAGE_S3BUCKET",
            "VERNISSAGE_S3ACCESSKEYID",
            "VERNISSAGE_S3SECRETACCESSKEY",
            "VERNISSAGE_S3HTTP1ONLYMODE"
        ]
        for key in sharedKeys {
            #expect(apiStart.environment[key] == jobsStart.environment[key])
        }
        #expect(apiStart.environment["VERNISSAGE_BASEADDRESS"] == "https://social.example.com")
        #expect(
            apiStart.environment["VERNISSAGE_CONNECTIONSTRING"] ==
                "postgres://vernissage:db%2Fp%40ss@db.example.com:5432/vernissage?tlsmode=require"
        )
        #expect(
            apiStart.environment["VERNISSAGE_QUEUEURL"] ==
                "rediss://default:redis%40secret@redis.example.com:6380/0"
        )
        #expect(apiStart.environment["VERNISSAGE_S3HTTP1ONLYMODE"] == "true")
        #expect(apiStart.arguments.containsSequence(["--network-alias", "vernissage-api.internal"]))
        #expect(jobsStart.arguments.containsSequence(["--network-alias", "vernissage-jobs.internal"]))
        #expect(apiStart.arguments.containsSequence(["--add-host", "host.docker.internal:host-gateway"]))

        let secrets = ["db/p@ss", "redis@secret", "s3-secret"]
        for invocation in runner.invocations {
            for secret in secrets {
                #expect(invocation.arguments.contains(secret) == false)
            }
        }

        let tableInspection = runner.invocations[7]
        #expect(tableInspection.environment["PGPASSWORD"] == "db/p@ss")
        #expect(tableInspection.arguments.contains("postgres:18"))
        #expect(output.text.contains(InstallationStepGuidance.serverServices))
        #expect(output.text.contains("• Users"))
        #expect(output.text.contains("WebPush is not healthy yet"))
    }

    @Test
    func `Loopback dependencies use Docker host gateway on Linux`() throws {
        let runner = ServerCommandRunner(results: successfulResults())
        let context = makeContext(
            databaseHost: "localhost",
            redisHost: "127.0.0.1",
            storageAddress: "http://localhost:9000",
            storageProvider: .compatible,
            storageRegion: nil
        )
        let step = makeStep(
            runner: runner,
            output: ServerOutputBuffer(),
            operatingSystem: .linux
        )

        try step.run(context: context)

        let apiStart = runner.invocations[4]
        let jobsStart = runner.invocations[7]
        #expect(
            apiStart.environment["VERNISSAGE_CONNECTIONSTRING"]?.contains("@host.docker.internal:5432/") == true
        )
        #expect(
            apiStart.environment["VERNISSAGE_QUEUEURL"]?.contains("@host.docker.internal:6379/") == true
        )
        #expect(apiStart.environment["VERNISSAGE_S3ADDRESS"] == "http://host.docker.internal:9000")
        #expect(apiStart.arguments.containsSequence(["--add-host", "host.docker.internal:host-gateway"]))
        #expect(jobsStart.arguments.containsSequence(["--add-host", "host.docker.internal:host-gateway"]))

        let tableInspection = runner.invocations[6]
        #expect(tableInspection.value(after: "--network") == "host")
        #expect(tableInspection.value(after: "--host") == "localhost")
    }

    @Test
    func `API and Jobs listen on IPv4 inside Docker network`() throws {
        let runner = ServerCommandRunner(results: successfulResults())
        let step = makeStep(
            runner: runner,
            output: ServerOutputBuffer(),
            operatingSystem: .linux
        )

        try step.run(context: makeContext())

        let apiStart = try #require(
            runner.invocations.first { $0.value(after: "--name") == "vernissage-abcdefgh-api" }
        )
        let jobsStart = try #require(
            runner.invocations.first { $0.value(after: "--name") == "vernissage-abcdefgh-jobs" }
        )
        let expectedCommand = [
            "mczachurski/vernissage-server:latest",
            "serve",
            "--env", "production",
            "--hostname", "0.0.0.0",
            "--port", "8080"
        ]

        #expect(Array(apiStart.arguments.suffix(expectedCommand.count)) == expectedCommand)
        #expect(Array(jobsStart.arguments.suffix(expectedCommand.count)) == expectedCommand)
    }

    @Test
    func `Unhealthy API stops before Jobs container is created`() {
        let unhealthyResponse = """
        {"isDatabaseHealthy":true,"isQueueHealthy":true,"isWebPushHealthy":false,"isStorageHealthy":false}
        """
        let runner = ServerCommandRunner(results: [
            .failure("API container not found"),
            .failure("Jobs container not found"),
            .success("vernissage-abcdefgh-network"),
            .success("image pulled"),
            .success("api-container-id"),
            .success(unhealthyResponse),
            .success(unhealthyResponse)
        ])
        let context = makeContext()
        let step = makeStep(
            runner: runner,
            output: ServerOutputBuffer(),
            healthAttempts: 2
        )

        let error = #expect(throws: ServerServicesStepError.self) {
            try step.run(context: context)
        }
        let expectedDetails = """
        database=true, queue=true, webPush=false, storage=false
        Inspect the container logs with:
          docker logs --tail 200 vernissage-abcdefgh-api
        If Docker requires elevated permissions:
          sudo docker logs --tail 200 vernissage-abcdefgh-api
        """
        #expect(
            error == .serviceStartupTimedOut(
                service: "API",
                details: expectedDetails
            )
        )
        #expect(context.serverServices == nil)
        #expect(runner.invocations.count == 7)
        #expect(
            runner.invocations.contains {
                $0.arguments.contains("vernissage-abcdefgh-jobs") && $0.arguments.first == "run"
            } == false
        )
    }

    @Test
    func `Missing previous configuration performs no Docker operations`() {
        let runner = ServerCommandRunner(results: [])
        let step = makeStep(runner: runner, output: ServerOutputBuffer())

        let error = #expect(throws: ServerServicesStepError.self) {
            try step.run(context: InstallationContext(instanceIdentifier: "abcdefgh"))
        }
        #expect(error == .missingConfiguration("server and domain"))
        #expect(runner.invocations.isEmpty)
    }

    @Test
    func `Existing API container is never replaced`() {
        let runner = ServerCommandRunner(results: [.success("existing-api")])
        let context = makeContext()
        let step = makeStep(runner: runner, output: ServerOutputBuffer())

        let error = #expect(throws: ServerServicesStepError.self) {
            try step.run(context: context)
        }
        #expect(error == .containerAlreadyExists("vernissage-abcdefgh-api"))
        #expect(context.serverServices == nil)
        #expect(runner.invocations.count == 1)
    }

    @Test
    func `API must create Vernissage database tables`() {
        let runner = ServerCommandRunner(results: [
            .failure("API container not found"),
            .failure("Jobs container not found"),
            .success("vernissage-abcdefgh-network"),
            .success("image pulled"),
            .success("api-container-id"),
            .success(healthyResponse),
            .success("Events\nStatuses")
        ])
        let context = makeContext()
        let step = makeStep(runner: runner, output: ServerOutputBuffer())

        let error = #expect(throws: ServerServicesStepError.self) {
            try step.run(context: context)
        }
        #expect(error == .vernissageTablesNotFound)
        #expect(context.serverServices == nil)
        #expect(runner.invocations.count == 7)
    }

    private var healthyResponse: String {
        """
        {"isDatabaseHealthy":true,"isQueueHealthy":true,"isWebPushHealthy":false,"isStorageHealthy":true}
        """
    }

    private func successfulResults() -> [CommandResult] {
        [
            .failure("API container not found"),
            .failure("Jobs container not found"),
            .success("vernissage-abcdefgh-network"),
            .success("image pulled"),
            .success("api-container-id"),
            .success(healthyResponse),
            .success("Events\nUsers"),
            .success("jobs-container-id"),
            .success(healthyResponse)
        ]
    }

    private func makeContext(
        databaseHost: String = "db.example.com",
        redisHost: String = "redis.example.com",
        storageAddress: String = "https://s3.eu-central-1.amazonaws.com",
        storageProvider: StorageProvider = .awsS3,
        storageRegion: String? = "eu-central-1"
    ) -> InstallationContext {
        let context = InstallationContext(instanceIdentifier: "abcdefgh")
        context.server = ServerConfiguration(domain: "social.example.com")
        context.database = DatabaseConfiguration(
            mode: .existing,
            host: databaseHost,
            port: 5432,
            database: "vernissage",
            username: "vernissage",
            password: Secret(value: "db/p@ss"),
            tlsMode: .require,
            localResources: nil
        )
        context.redis = RedisConfiguration(
            mode: .existing,
            url: Secret(
                value: "rediss://default:redis%40secret@\(redisHost):\(redisHost == "127.0.0.1" ? 6379 : 6380)/0"
            ),
            username: "default",
            host: redisHost,
            port: redisHost == "127.0.0.1" ? 6379 : 6380,
            database: 0,
            password: Secret(value: "redis@secret"),
            usesTLS: true,
            localResources: nil
        )
        context.storage = StorageConfiguration(
            provider: storageProvider,
            address: storageAddress,
            region: storageRegion,
            bucket: "vernissage-media",
            accessKeyId: "s3-key",
            secretAccessKey: Secret(value: "s3-secret"),
            http1OnlyMode: storageProvider == .awsS3,
            localResources: nil
        )
        return context
    }

    private func makeStep(
        runner: ServerCommandRunner,
        output: ServerOutputBuffer,
        waitBeforeRetry: @escaping () -> Void = {},
        healthAttempts: Int = 3,
        operatingSystem: HostOperatingSystem = .macOS
    ) -> ServerServicesStep {
        ServerServicesStep(
            console: Console(
                colorsEnabled: false,
                writeOutput: output.append
            ),
            commandRunner: runner,
            waitBeforeRetry: waitBeforeRetry,
            healthAttempts: healthAttempts,
            operatingSystem: operatingSystem
        )
    }
}

private struct ServerCommandInvocation {
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

private enum ServerCommandRunnerError: Error {
    case resultNotConfigured
}

private final class ServerCommandRunner: CommandRunning {
    private var results: [CommandResult]
    private(set) var invocations: [ServerCommandInvocation] = []

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
            ServerCommandInvocation(
                executable: executable,
                arguments: arguments,
                environment: environment,
                standardInput: standardInput
            )
        )
        guard results.isEmpty == false else {
            throw ServerCommandRunnerError.resultNotConfigured
        }
        return results.removeFirst()
    }
}

private final class ServerOutputBuffer {
    private(set) var text = ""

    func append(_ value: String) {
        text += value
    }
}

private final class RetryCounter {
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
