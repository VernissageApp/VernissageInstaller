import Testing
@testable import VernissageCore

struct ImageDeliveryStepTests {
    @Test
    func `Public images URL is stored in Vernissage settings`() throws {
        let runner = ImageDeliveryCommandRunner(results: [
            .success("1"),
            .success("containers restarted"),
            .success(healthyResponse),
            .success(healthyResponse)
        ])
        let output = ImageDeliveryOutputBuffer()
        let context = makeContext(imagesURL: "https://social.example.com/static-resource/")
        let step = makeStep(runner: runner, output: output)

        try step.run(context: context)

        let databaseUpdate = try #require(runner.invocations.first)
        #expect(databaseUpdate.executable == "docker")
        #expect(databaseUpdate.arguments.containsSequence([
            "--network", "vernissage-abcdefgh-network"
        ]))
        #expect(databaseUpdate.arguments.containsSequence([
            "--host", "vernissage-abcdefgh-postgres"
        ]))
        #expect(databaseUpdate.environment["PGPASSWORD"] == "database-secret")
        #expect(databaseUpdate.arguments.contains("database-secret") == false)
        #expect(databaseUpdate.standardInput?.contains("WHERE \"key\" = 'imagesUrl'") == true)
        #expect(databaseUpdate.standardInput?.contains("https://social.example.com/static-resource/") == true)

        let restart = runner.invocations[1]
        #expect(restart.arguments == [
            "restart",
            "vernissage-abcdefgh-api",
            "vernissage-abcdefgh-jobs"
        ])

        let apiHealth = runner.invocations[2]
        #expect(apiHealth.arguments.starts(with: [
            "exec", "vernissage-abcdefgh-api", "curl"
        ]))
        let jobsHealth = runner.invocations[3]
        #expect(jobsHealth.arguments.starts(with: [
            "exec", "vernissage-abcdefgh-jobs", "curl"
        ]))
        #expect(output.text.contains("Public image delivery"))
        #expect(output.text.contains("https://social.example.com/static-resource/"))
        #expect(output.text.contains("loaded by API and Jobs"))
        #expect(output.text.contains("database-secret") == false)
    }

    @Test
    func `Default S3 image address does not overwrite settings`() throws {
        let runner = ImageDeliveryCommandRunner(results: [])
        let output = ImageDeliveryOutputBuffer()
        let step = makeStep(runner: runner, output: output)

        try step.run(context: makeContext(imagesURL: nil))

        #expect(runner.invocations.isEmpty)
        #expect(output.text.isEmpty)
    }

    @Test
    func `Database failure leaves installer with actionable error`() {
        let runner = ImageDeliveryCommandRunner(results: [
            CommandResult(
                exitCode: 1,
                standardOutput: "",
                standardError: "imagesUrl setting not found"
            )
        ])
        let step = makeStep(runner: runner, output: ImageDeliveryOutputBuffer())

        let error = #expect(throws: ImageDeliveryStepError.self) {
            try step.run(context: makeContext(imagesURL: "https://cdn.example.com/"))
        }

        #expect(error == .settingsUpdateFailed("imagesUrl setting not found"))
    }

    @Test
    func `Service restart failure stops before health checks`() {
        let runner = ImageDeliveryCommandRunner(results: [
            .success("1"),
            .failure("Docker restart failed")
        ])
        let step = makeStep(runner: runner, output: ImageDeliveryOutputBuffer())

        #expect(throws: ImageDeliveryStepError.serviceRestartFailed(
            "Docker restart failed"
        )) {
            try step.run(context: makeContext(
                imagesURL: "https://social.example.com/static-resource/"
            ))
        }
        #expect(runner.invocations.count == 2)
    }

    private func makeStep(
        runner: ImageDeliveryCommandRunner,
        output: ImageDeliveryOutputBuffer
    ) -> ImageDeliveryStep {
        ImageDeliveryStep(
            console: Console(
                colorsEnabled: false,
                readInput: { nil },
                writeOutput: output.append
            ),
            commandRunner: runner,
            waitBeforeRetry: {},
            healthAttempts: 3,
            operatingSystem: .linux
        )
    }

    private func makeContext(imagesURL: String?) -> InstallationContext {
        let context = InstallationContext(instanceIdentifier: "abcdefgh")
        context.database = DatabaseConfiguration(
            mode: .localContainer,
            host: "vernissage-abcdefgh-postgres",
            port: 5432,
            database: "vernissage",
            username: "vernissage",
            password: Secret(value: "database-secret"),
            tlsMode: .disable,
            localResources: LocalPostgreSQLResources(
                image: "postgres:18",
                containerName: "vernissage-abcdefgh-postgres",
                volumeName: "vernissage-abcdefgh-postgres-data",
                networkName: "vernissage-abcdefgh-network"
            )
        )
        context.storage = StorageConfiguration(
            provider: imagesURL?.contains("static-resource") == true ? .localMinIO : .awsS3,
            address: "http://vernissage-abcdefgh-minio:9000",
            region: nil,
            bucket: "vernissage",
            accessKeyId: "minio",
            secretAccessKey: Secret(value: "storage-secret"),
            http1OnlyMode: false,
            imagesURL: imagesURL,
            localResources: nil
        )
        context.serverServices = ServerServicesConfiguration(
            image: "mczachurski/vernissage-server:latest",
            networkName: "vernissage-abcdefgh-network",
            apiContainerName: "vernissage-abcdefgh-api",
            jobsContainerName: "vernissage-abcdefgh-jobs",
            apiNetworkAlias: "vernissage-api.internal",
            jobsNetworkAlias: "vernissage-jobs.internal",
            baseAddress: "https://social.example.com",
            apiHealth: nil,
            jobsHealth: nil,
            databaseTables: nil
        )
        return context
    }
}

private let healthyResponse = """
{"isDatabaseHealthy":true,"isQueueHealthy":true,"isWebPushHealthy":true,"isStorageHealthy":true}
"""

private struct ImageDeliveryCommandInvocation {
    let executable: String
    let arguments: [String]
    let environment: [String: String]
    let standardInput: String?
}

private enum ImageDeliveryCommandRunnerError: Error {
    case resultNotConfigured
}

private final class ImageDeliveryCommandRunner: CommandRunning {
    private var results: [CommandResult]
    private(set) var invocations: [ImageDeliveryCommandInvocation] = []

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
            ImageDeliveryCommandInvocation(
                executable: executable,
                arguments: arguments,
                environment: environment,
                standardInput: standardInput
            )
        )
        guard results.isEmpty == false else {
            throw ImageDeliveryCommandRunnerError.resultNotConfigured
        }
        return results.removeFirst()
    }
}

private final class ImageDeliveryOutputBuffer {
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
