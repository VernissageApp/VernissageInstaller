import Testing
@testable import VernissageCore

@Suite(.tags(.storage))
struct StorageStepTests {
    @Test
    func `AWS S3 configuration is tested and stored`() throws {
        let runner = StorageCommandRunner(results: successfulStorageTestResults())
        let output = StorageOutputBuffer()
        let context = InstallationContext(instanceIdentifier: "abcdefgh")
        let step = makeStep(
            input: StorageInputQueue([
                "1",
                "eu-central-1",
                "vernissage-media",
                "AKIAEXAMPLE",
                "https://cdn.example.com/vernissage"
            ]),
            secureInput: StorageInputQueue(["aws-secret"]),
            output: output,
            runner: runner
        )

        try step.run(context: context)

        let configuration = try #require(context.storage)
        #expect(configuration.provider == .awsS3)
        #expect(configuration.address == "https://s3.eu-central-1.amazonaws.com")
        #expect(configuration.region == "eu-central-1")
        #expect(configuration.bucket == "vernissage-media")
        #expect(configuration.accessKeyId == "AKIAEXAMPLE")
        #expect(configuration.secretAccessKey.value == "aws-secret")
        #expect(configuration.http1OnlyMode)
        #expect(configuration.imagesURL == "https://cdn.example.com/vernissage/")
        #expect(configuration.localResources == nil)
        #expect(runner.invocations.count == 4)

        let upload = runner.invocations[1]
        #expect(upload.arguments.containsSequence(["s3", "cp", "-", "s3://vernissage-media/test-object.txt"]))
        #expect(upload.environment["AWS_DEFAULT_REGION"] == "eu-central-1")
        #expect(upload.environment["AWS_SECRET_ACCESS_KEY"] == "aws-secret")
        #expect(upload.standardInput == "storage-test-payload")
        #expect(upload.arguments.contains("--endpoint-url") == false)
        #expect(runner.invocations.allSatisfy { $0.arguments.contains("aws-secret") == false })
        #expect(output.text.contains(InstallationStepGuidance.storage))
        #expect(output.text.contains("Choose your option:"))
        #expect(output.text.contains("aws-secret") == false)
    }

    @Test
    func `Compatible S3 localhost on macOS uses the Docker host gateway`() throws {
        let runner = StorageCommandRunner(results: successfulStorageTestResults())
        let context = InstallationContext(instanceIdentifier: "abcdefgh")
        let step = makeStep(
            input: StorageInputQueue([
                "2",
                "http://localhost:9000",
                "vernissage-media",
                "custom-key",
                "2"
            ]),
            secureInput: StorageInputQueue(["custom-secret"]),
            output: StorageOutputBuffer(),
            runner: runner,
            operatingSystem: .macOS
        )

        try step.run(context: context)

        let configuration = try #require(context.storage)
        #expect(configuration.provider == .compatible)
        #expect(configuration.address == "http://localhost:9000")
        #expect(configuration.region == nil)
        #expect(configuration.http1OnlyMode)
        #expect(runner.invocations.count == 4)
        #expect(
            runner.invocations.allSatisfy {
                $0.value(after: "--endpoint-url") == "http://host.docker.internal:9000"
            }
        )
        #expect(runner.invocations.allSatisfy { $0.arguments.contains("--network") == false })
    }

    @Test
    func `Compatible S3 localhost on Linux uses the host network`() throws {
        let runner = StorageCommandRunner(results: successfulStorageTestResults())
        let step = makeStep(
            input: StorageInputQueue([
                "2",
                "http://localhost:9000",
                "vernissage-media",
                "custom-key",
                ""
            ]),
            secureInput: StorageInputQueue(["custom-secret"]),
            output: StorageOutputBuffer(),
            runner: runner,
            operatingSystem: .linux
        )

        try step.run(context: InstallationContext(instanceIdentifier: "abcdefgh"))

        #expect(runner.invocations.count == 4)
        #expect(runner.invocations.allSatisfy { $0.value(after: "--network") == "host" })
        #expect(
            runner.invocations.allSatisfy {
                $0.value(after: "--endpoint-url") == "http://localhost:9000"
            }
        )
    }

    @Test
    func `Local MinIO is built created tested and stored`() throws {
        let runner = StorageCommandRunner(results: [
            .failure("container not found"),
            .failure("volume not found"),
            .failure("image not found"),
            .success("image built"),
            .failure("network not found"),
            .success("vernissage-abcdefgh-network"),
            .success("vernissage-abcdefgh-minio-data"),
            .success("container-id"),
            .success("bucket created"),
            .success("bucket policy configured"),
            .success("bucket exists"),
            .success("uploaded"),
            .success("storage-test-payload"),
            .success("storage-test-payload"),
            .success("deleted")
        ])
        let output = StorageOutputBuffer()
        let context = InstallationContext(instanceIdentifier: "abcdefgh")
        context.server = ServerConfiguration(domain: "social.example.com")
        let step = makeStep(
            input: StorageInputQueue(["3", "minioadmin"]),
            secureInput: StorageInputQueue(["minio-secret", "minio-secret"]),
            output: output,
            runner: runner
        )

        try step.run(context: context)

        let configuration = try #require(context.storage)
        let resources = try #require(configuration.localResources)
        #expect(configuration.provider == .localMinIO)
        #expect(configuration.address == "http://vernissage-abcdefgh-minio:9000")
        #expect(configuration.region == nil)
        #expect(configuration.bucket == "vernissage")
        #expect(configuration.accessKeyId == "minioadmin")
        #expect(configuration.secretAccessKey.value == "minio-secret")
        #expect(configuration.http1OnlyMode == false)
        #expect(configuration.imagesURL == "https://social.example.com/static-resource/")
        #expect(resources.image == "vernissage/minio:RELEASE.2025-10-15T17-29-55Z")
        #expect(resources.containerName == "vernissage-abcdefgh-minio")
        #expect(resources.volumeName == "vernissage-abcdefgh-minio-data")
        #expect(resources.networkName == "vernissage-abcdefgh-network")
        #expect(runner.invocations.count == 15)

        let imageBuild = runner.invocations[3]
        #expect(imageBuild.arguments.starts(with: ["build", "--quiet", "--tag"]))
        #expect(imageBuild.standardInput?.contains("go install github.com/minio/minio@RELEASE.2025-10-15T17-29-55Z") == true)

        let containerCreation = runner.invocations[7]
        #expect(containerCreation.arguments.contains("MINIO_ROOT_USER"))
        #expect(containerCreation.arguments.contains("MINIO_ROOT_PASSWORD"))
        #expect(containerCreation.environment["MINIO_ROOT_USER"] == "minioadmin")
        #expect(containerCreation.environment["MINIO_ROOT_PASSWORD"] == "minio-secret")
        #expect(containerCreation.arguments.contains("minio-secret") == false)

        let bucketCreation = runner.invocations[8]
        #expect(bucketCreation.arguments.containsSequence(["s3api", "create-bucket", "--bucket", "vernissage"]))
        #expect(bucketCreation.value(after: "--network") == "vernissage-abcdefgh-network")

        let bucketPolicy = runner.invocations[9]
        #expect(bucketPolicy.arguments.containsSequence([
            "s3api", "put-bucket-policy", "--bucket", "vernissage"
        ]))
        let policy = try #require(bucketPolicy.value(after: "--policy"))
        #expect(policy.contains("\"Action\":[\"s3:GetObject\"]"))
        #expect(policy.contains("arn:aws:s3:::vernissage/*"))
        #expect(policy.contains("s3:PutObject") == false)
        #expect(policy.contains("s3:ListBucket") == false)

        let anonymousDownload = runner.invocations[13]
        #expect(anonymousDownload.arguments.contains("--no-sign-request"))
        #expect(anonymousDownload.arguments.containsSequence([
            "s3", "cp", "s3://vernissage/test-object.txt", "-"
        ]))
        #expect(output.text.contains("downloaded publicly"))
        #expect(output.text.contains("minio-secret") == false)
    }

    @Test
    func `Failed S3 upload stops storage step without storing credentials`() {
        let runner = StorageCommandRunner(results: [
            .success("bucket exists"),
            .failure("access denied")
        ])
        let context = InstallationContext(instanceIdentifier: "abcdefgh")
        let step = makeStep(
            input: StorageInputQueue([
                "1",
                "eu-central-1",
                "vernissage-media",
                "AKIAEXAMPLE"
            ]),
            secureInput: StorageInputQueue(["aws-secret"]),
            output: StorageOutputBuffer(),
            runner: runner
        )

        let error = #expect(throws: StorageStepError.self) {
            try step.run(context: context)
        }
        #expect(
            error == .storageOperationFailed(
                operation: "upload a test object",
                details: "access denied"
            )
        )
        #expect(context.storage == nil)
        #expect(runner.invocations.count == 2)
    }

    @Test
    func `Downloaded S3 object must match uploaded content`() {
        let runner = StorageCommandRunner(results: [
            .success("bucket exists"),
            .success("uploaded"),
            .success("different payload"),
            .success("deleted")
        ])
        let context = InstallationContext(instanceIdentifier: "abcdefgh")
        let step = makeStep(
            input: StorageInputQueue([
                "1",
                "eu-central-1",
                "vernissage-media",
                "AKIAEXAMPLE"
            ]),
            secureInput: StorageInputQueue(["aws-secret"]),
            output: StorageOutputBuffer(),
            runner: runner
        )

        let error = #expect(throws: StorageStepError.self) {
            try step.run(context: context)
        }
        #expect(error == .downloadedObjectDoesNotMatch)
        #expect(context.storage == nil)
        #expect(runner.invocations.count == 4)
    }

    private func makeStep(
        input: StorageInputQueue,
        secureInput: StorageInputQueue,
        output: StorageOutputBuffer,
        runner: StorageCommandRunner,
        operatingSystem: HostOperatingSystem = .macOS
    ) -> StorageStep {
        StorageStep(
            console: Console(
                colorsEnabled: false,
                readInput: input.next,
                readSecureInput: secureInput.next,
                writeOutput: output.append
            ),
            commandRunner: runner,
            makeObjectKey: { "test-object.txt" },
            testPayload: "storage-test-payload",
            waitBeforeRetry: {},
            readinessAttempts: 3,
            operatingSystem: operatingSystem
        )
    }

    private func successfulStorageTestResults() -> [CommandResult] {
        [
            .success("bucket exists"),
            .success("uploaded"),
            .success("storage-test-payload"),
            .success("deleted")
        ]
    }
}

private struct StorageCommandInvocation {
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

private enum StorageCommandRunnerError: Error {
    case resultNotConfigured
}

private final class StorageCommandRunner: CommandRunning {
    private var results: [CommandResult]
    private(set) var invocations: [StorageCommandInvocation] = []

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
            StorageCommandInvocation(
                executable: executable,
                arguments: arguments,
                environment: environment,
                standardInput: standardInput
            )
        )

        guard results.isEmpty == false else {
            throw StorageCommandRunnerError.resultNotConfigured
        }
        return results.removeFirst()
    }
}

private final class StorageInputQueue {
    private var values: [String]

    init(_ values: [String]) {
        self.values = values
    }

    func next() -> String? {
        guard values.isEmpty == false else { return nil }
        return values.removeFirst()
    }
}

private final class StorageOutputBuffer {
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
