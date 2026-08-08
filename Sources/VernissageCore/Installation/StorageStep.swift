import Foundation

enum StorageStepError: LocalizedError, Equatable {
    case invalidValue(String)
    case dockerCommandFailed(action: String, details: String?)
    case localContainerAlreadyExists(String)
    case localVolumeAlreadyExists(String)
    case minIOImageBuildFailed(String?)
    case minIOStartupTimedOut(String?)
    case storageOperationFailed(operation: String, details: String?)
    case downloadedObjectDoesNotMatch

    var errorDescription: String? {
        switch self {
        case .invalidValue(let message):
            message
        case .dockerCommandFailed(let action, let details):
            Self.message("Docker could not \(action).", details: details)
        case .localContainerAlreadyExists(let name):
            "A Docker container named \(name) already exists. The installer will not replace it automatically."
        case .localVolumeAlreadyExists(let name):
            "A Docker volume named \(name) already exists. It may contain object storage data, so the installer will not reuse or remove it automatically."
        case .minIOImageBuildFailed(let details):
            Self.message("The local MinIO image could not be built from the pinned source release.", details: details)
        case .minIOStartupTimedOut(let details):
            Self.message("MinIO did not become ready and create its bucket in time. The container was preserved for diagnostics.", details: details)
        case .storageOperationFailed(let operation, let details):
            Self.message("The S3 test could not \(operation).", details: details)
        case .downloadedObjectDoesNotMatch:
            "The object downloaded from S3 does not match the object uploaded by the installer."
        }
    }

    private static func message(_ summary: String, details: String?) -> String {
        guard let details, details.isEmpty == false else { return summary }
        return "\(summary) S3 reported: \(details)"
    }
}

struct StorageStep {
    static let awsCLIImage = "amazon/aws-cli:2.36.2"
    static let minIORelease = "RELEASE.2025-10-15T17-29-55Z"
    static let minIOImage = "vernissage/minio:\(minIORelease)"
    static let minIOBucket = "vernissage"

    private let console: Console
    private let commandRunner: any CommandRunning
    private let makeObjectKey: () -> String
    private let testPayload: String
    private let waitBeforeRetry: () -> Void
    private let readinessAttempts: Int
    private let operatingSystem: HostOperatingSystem

    init(
        console: Console,
        commandRunner: any CommandRunning,
        makeObjectKey: @escaping () -> String,
        testPayload: String,
        waitBeforeRetry: @escaping () -> Void,
        readinessAttempts: Int = 30,
        operatingSystem: HostOperatingSystem
    ) {
        self.console = console
        self.commandRunner = commandRunner
        self.makeObjectKey = makeObjectKey
        self.testPayload = testPayload
        self.waitBeforeRetry = waitBeforeRetry
        self.readinessAttempts = readinessAttempts
        self.operatingSystem = operatingSystem
    }

    static func live(colorsEnabled: Bool) -> StorageStep {
        StorageStep(
            console: .live(colorsEnabled: colorsEnabled),
            commandRunner: ProcessCommandRunner(),
            makeObjectKey: { "vernissage-installer/\(UUID().uuidString.lowercased()).txt" },
            testPayload: "vernissage-storage-permission-test",
            waitBeforeRetry: { Thread.sleep(forTimeInterval: 1) },
            operatingSystem: .current
        )
    }

    func run(context: InstallationContext, input: StorageStepInput? = nil) throws {
        console.section("S3 object storage")
        console.guidance(InstallationStepGuidance.storage)

        let provider: StorageProvider
        switch input {
        case .aws: provider = .awsS3
        case .compatible: provider = .compatible
        case .minIO: provider = .localMinIO
        case nil: provider = try readProvider()
        }

        switch provider {
        case .awsS3:
            try configureAWS(context: context, input: input)
        case .compatible:
            try configureCompatibleStorage(context: context, input: input)
        case .localMinIO:
            try installLocalMinIO(context: context, input: input)
        }
    }

    private func readProvider() throws -> StorageProvider {
        console.optionListHeader()
        console.line("  1. AWS S3 (recommended)")
        console.line("  2. Another S3-compatible service")
        console.line("  3. Install local MinIO")

        while true {
            guard let input = console.prompt("Storage option [1]:") else {
                throw StorageStepError.invalidValue("A storage option is required.")
            }

            switch input.lowercased() {
            case "", "1", "aws", "s3": return .awsS3
            case "2", "compatible", "custom": return .compatible
            case "3", "minio", "local": return .localMinIO
            default: console.warning("Choose 1 for AWS S3, 2 for another S3-compatible service, or 3 for local MinIO.")
            }
        }
    }

    private func configureAWS(context: InstallationContext, input: StorageStepInput?) throws {
        let region: String
        let bucket: String
        let accessKeyId: String
        let secretAccessKey: Secret
        if case .aws(let providedRegion, let providedBucket, let providedAccessKeyID, let providedSecret) = input {
            region = providedRegion
            bucket = providedBucket
            accessKeyId = providedAccessKeyID
            secretAccessKey = providedSecret
        } else {
            region = try requiredValue(
                field: "AWS region",
                question: "AWS region (for example, eu-central-1):",
                validator: validateRegion
            )
            bucket = try readBucket()
            accessKeyId = try readAccessKey(question: "AWS access key ID:")
            secretAccessKey = try readSecret(question: "AWS secret access key:")
        }
        let configuration = StorageConfiguration(
            provider: .awsS3,
            address: "https://s3.\(region).amazonaws.com",
            region: region,
            bucket: bucket,
            accessKeyId: accessKeyId,
            secretAccessKey: secretAccessKey,
            http1OnlyMode: true,
            localResources: nil
        )

        try testStorage(configuration)
        context.storage = configuration
        console.success("AWS S3 storage is ready for Vernissage.")
    }

    private func configureCompatibleStorage(context: InstallationContext, input: StorageStepInput?) throws {
        let address: String
        let bucket: String
        let accessKeyId: String
        let secretAccessKey: Secret
        let http1OnlyMode: Bool
        if case .compatible(let providedAddress, let providedBucket, let providedAccessKeyID, let providedSecret, let providedHTTP1Only) = input {
            address = providedAddress
            bucket = providedBucket
            accessKeyId = providedAccessKeyID
            secretAccessKey = providedSecret
            http1OnlyMode = providedHTTP1Only
        } else {
            address = try requiredValue(
                field: "S3 address",
                question: "S3-compatible service address:",
                validator: validateAddress
            )
            bucket = try readBucket()
            accessKeyId = try readAccessKey(question: "S3 access key ID:")
            secretAccessKey = try readSecret(question: "S3 secret access key:")
            http1OnlyMode = try readHTTP1OnlyMode()
        }
        let configuration = StorageConfiguration(
            provider: .compatible,
            address: address,
            region: nil,
            bucket: bucket,
            accessKeyId: accessKeyId,
            secretAccessKey: secretAccessKey,
            http1OnlyMode: http1OnlyMode,
            localResources: nil
        )

        try testStorage(configuration)
        context.storage = configuration
        console.success("S3-compatible storage is ready for Vernissage.")
    }

    private func installLocalMinIO(context: InstallationContext, input: StorageStepInput?) throws {
        let names = context.resourceNames
        console.warning(
            "MinIO Community no longer publishes maintained official container images. The installer will build the last security-fixed source release locally and pin it for this installation."
        )
        console.warning(
            "This storage remains on this server. A Docker volume is persistent, but it is not a backup; keep regular off-server copies of all media."
        )

        let accessKeyId: String
        let secretAccessKey: Secret
        if case .minIO(let providedUsername, let providedPassword) = input {
            accessKeyId = providedUsername
            secretAccessKey = providedPassword
        } else {
            accessKeyId = try requiredValue(
                field: "MinIO root username",
                question: "MinIO root username:",
                validator: validateMinIOUsername
            )
            secretAccessKey = try readSecret(
                question: "MinIO root password:",
                confirm: true,
                minimumLength: 8
            )
        }

        try ensureLocalResourcesDoNotExist(names: names)
        try buildMinIOImageIfNeeded()
        try createNetworkIfNeeded(named: names.networkName)
        try createLocalVolume(named: names.minIOVolumeName)
        try createMinIOContainer(
            accessKeyId: accessKeyId,
            secretAccessKey: secretAccessKey,
            names: names
        )

        let configuration = StorageConfiguration(
            provider: .localMinIO,
            address: "http://\(names.minIOContainerName):9000",
            region: nil,
            bucket: Self.minIOBucket,
            accessKeyId: accessKeyId,
            secretAccessKey: secretAccessKey,
            http1OnlyMode: false,
            localResources: LocalMinIOResources(
                image: Self.minIOImage,
                containerName: names.minIOContainerName,
                volumeName: names.minIOVolumeName,
                networkName: names.networkName
            )
        )

        try createMinIOBucket(configuration)
        try testStorage(configuration, dockerNetwork: names.networkName)
        context.storage = configuration
        console.success("Local MinIO storage is running in \(names.minIOContainerName).")
        console.value(label: "Bucket", value: Self.minIOBucket)
        console.value(label: "Volume", value: names.minIOVolumeName)
        console.value(label: "Network", value: names.networkName)
        console.warning("Configure an off-server media backup before making the instance public.")
    }

    private func ensureLocalResourcesDoNotExist(names: InstallationResourceNames) throws {
        let containerInspection = try runDocker(["container", "inspect", names.minIOContainerName])
        if containerInspection.succeeded {
            throw StorageStepError.localContainerAlreadyExists(names.minIOContainerName)
        }

        let volumeInspection = try runDocker(["volume", "inspect", names.minIOVolumeName])
        if volumeInspection.succeeded {
            throw StorageStepError.localVolumeAlreadyExists(names.minIOVolumeName)
        }
    }

    private func buildMinIOImageIfNeeded() throws {
        let inspection = try runDocker(["image", "inspect", Self.minIOImage])
        guard inspection.succeeded == false else {
            console.success("Local MinIO image is available: \(Self.minIOImage)")
            return
        }

        console.info("Building MinIO \(Self.minIORelease) from its official source…")
        let result = try runDocker(
            ["build", "--quiet", "--tag", Self.minIOImage, "-"],
            standardInput: Self.minIODockerfile
        )
        guard result.succeeded else {
            throw StorageStepError.minIOImageBuildFailed(details(from: result))
        }
        console.success("Built local MinIO image: \(Self.minIOImage)")
    }

    private func createNetworkIfNeeded(named networkName: String) throws {
        let inspection = try runDocker(["network", "inspect", networkName])
        guard inspection.succeeded == false else {
            console.success("Docker network already exists: \(networkName)")
            return
        }

        _ = try requireDockerSuccess(
            ["network", "create", networkName],
            action: "create the Vernissage network"
        )
        console.success("Created Docker network: \(networkName)")
    }

    private func createLocalVolume(named volumeName: String) throws {
        _ = try requireDockerSuccess(
            ["volume", "create", volumeName],
            action: "create the MinIO data volume"
        )
        console.success("Created persistent Docker volume: \(volumeName)")
    }

    private func createMinIOContainer(
        accessKeyId: String,
        secretAccessKey: Secret,
        names: InstallationResourceNames
    ) throws {
        _ = try requireDockerSuccess(
            [
                "run", "--detach",
                "--name", names.minIOContainerName,
                "--restart", "unless-stopped",
                "--network", names.networkName,
                "--env", "MINIO_ROOT_USER",
                "--env", "MINIO_ROOT_PASSWORD",
                "--mount", "type=volume,source=\(names.minIOVolumeName),target=/data",
                Self.minIOImage,
                "server", "/data", "--console-address", ":9001"
            ],
            action: "start the MinIO container",
            environment: [
                "MINIO_ROOT_USER": accessKeyId,
                "MINIO_ROOT_PASSWORD": secretAccessKey.value
            ]
        )
        console.success("Started Docker container: \(names.minIOContainerName)")
    }

    private func createMinIOBucket(_ configuration: StorageConfiguration) throws {
        console.info("Waiting for MinIO and creating bucket \(Self.minIOBucket)…")
        var lastDetails: String?

        for attempt in 0..<readinessAttempts {
            let result = try runAWSCLI(
                ["s3api", "create-bucket", "--bucket", Self.minIOBucket],
                configuration: configuration,
                dockerNetwork: configuration.localResources?.networkName
            )
            if result.succeeded {
                console.success("Created MinIO bucket: \(Self.minIOBucket)")
                return
            }

            lastDetails = details(from: result)
            if attempt < readinessAttempts - 1 {
                waitBeforeRetry()
            }
        }

        throw StorageStepError.minIOStartupTimedOut(lastDetails)
    }

    private func testStorage(
        _ configuration: StorageConfiguration,
        dockerNetwork: String? = nil
    ) throws {
        console.info("Testing bucket access and object upload, download, and deletion…")
        let objectKey = makeObjectKey()
        let objectURI = "s3://\(configuration.bucket)/\(objectKey)"

        _ = try requireStorageSuccess(
            ["s3api", "head-bucket", "--bucket", configuration.bucket],
            operation: "access bucket \(configuration.bucket)",
            configuration: configuration,
            dockerNetwork: dockerNetwork
        )

        var objectWasUploaded = false
        defer {
            if objectWasUploaded {
                _ = try? runAWSCLI(
                    ["s3api", "delete-object", "--bucket", configuration.bucket, "--key", objectKey],
                    configuration: configuration,
                    dockerNetwork: dockerNetwork
                )
            }
        }

        _ = try requireStorageSuccess(
            ["s3", "cp", "-", objectURI, "--acl", "public-read", "--only-show-errors"],
            operation: "upload a test object",
            configuration: configuration,
            dockerNetwork: dockerNetwork,
            standardInput: testPayload
        )
        objectWasUploaded = true

        let download = try requireStorageSuccess(
            ["s3", "cp", objectURI, "-", "--only-show-errors"],
            operation: "download the test object",
            configuration: configuration,
            dockerNetwork: dockerNetwork
        )

        _ = try requireStorageSuccess(
            ["s3api", "delete-object", "--bucket", configuration.bucket, "--key", objectKey],
            operation: "delete the test object",
            configuration: configuration,
            dockerNetwork: dockerNetwork
        )
        objectWasUploaded = false

        guard download.standardOutput == testPayload else {
            throw StorageStepError.downloadedObjectDoesNotMatch
        }

        console.success("Bucket access, upload, download, integrity, and deletion tests passed.")
    }

    private func readBucket() throws -> String {
        try requiredValue(
            field: "S3 bucket",
            question: "S3 bucket name:",
            validator: validateBucket
        )
    }

    private func readAccessKey(question: String) throws -> String {
        try requiredValue(
            field: "S3 access key ID",
            question: question,
            validator: validateAccessKey
        )
    }

    private func readHTTP1OnlyMode() throws -> Bool {
        console.info("Force HTTP/1 only when your S3-compatible provider requires it.")
        console.line("  1. Automatic HTTP version (recommended)")
        console.line("  2. Force HTTP/1")

        while true {
            guard let input = console.prompt("HTTP version option [1]:") else {
                throw StorageStepError.invalidValue("An HTTP version option is required.")
            }

            switch input.lowercased() {
            case "", "1", "automatic", "no", "false": return false
            case "2", "http1", "yes", "true": return true
            default: console.warning("Choose 1 for automatic HTTP negotiation or 2 to force HTTP/1.")
            }
        }
    }

    private func readSecret(
        question: String,
        confirm: Bool = false,
        minimumLength: Int = 1
    ) throws -> Secret {
        while true {
            guard let value = console.securePrompt(question) else {
                throw StorageStepError.invalidValue("An S3 secret access key is required.")
            }

            do {
                let secret = try validateSecret(value, minimumLength: minimumLength)
                guard confirm else { return secret }

                guard let confirmation = console.securePrompt("Confirm MinIO root password:") else {
                    throw StorageStepError.invalidValue("MinIO password confirmation is required.")
                }
                guard value == confirmation else {
                    console.warning("The passwords do not match.")
                    continue
                }
                return secret
            } catch let error as StorageStepError {
                console.warning(error.localizedDescription)
            }
        }
    }

    private func requiredValue(
        field: String,
        question: String,
        validator: (String) throws -> String
    ) throws -> String {
        while true {
            guard let input = console.prompt(question) else {
                throw StorageStepError.invalidValue("A \(field) is required.")
            }

            do {
                return try validator(input)
            } catch {
                console.warning(error.localizedDescription)
            }
        }
    }

    private func validateAddress(_ input: String) throws -> String {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }

        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw StorageStepError.invalidValue(
                "Enter a complete HTTP or HTTPS S3 address without credentials, query parameters, or a fragment."
            )
        }
        return value
    }

    private func validateRegion(_ input: String) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard (3...63).contains(value.count),
              value.utf8.allSatisfy({ byte in
                  (byte >= 97 && byte <= 122) ||
                  (byte >= 48 && byte <= 57) ||
                  byte == 45
              }),
              value.first != "-",
              value.last != "-" else {
            throw StorageStepError.invalidValue("Enter a valid AWS region such as eu-central-1.")
        }
        return value
    }

    private func validateBucket(_ input: String) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (3...63).contains(value.count),
              value.utf8.allSatisfy({ byte in
                  (byte >= 97 && byte <= 122) ||
                  (byte >= 48 && byte <= 57) ||
                  byte == 45 || byte == 46
              }),
              value.first?.isLetter == true || value.first?.isNumber == true,
              value.last?.isLetter == true || value.last?.isNumber == true,
              value.contains("..") == false else {
            throw StorageStepError.invalidValue(
                "The bucket name must contain 3–63 lowercase letters, digits, dots, or hyphens and start and end with a letter or digit."
            )
        }
        return value
    }

    private func validateAccessKey(_ input: String) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...256).contains(value.count),
              value.contains(where: { $0.isWhitespace || $0.isNewline }) == false else {
            throw StorageStepError.invalidValue("The S3 access key ID is required and cannot contain whitespace.")
        }
        return value
    }

    private func validateMinIOUsername(_ input: String) throws -> String {
        let value = try validateAccessKey(input)
        guard value.count >= 3 else {
            throw StorageStepError.invalidValue("The MinIO root username must contain at least 3 characters.")
        }
        return value
    }

    private func validateSecret(_ input: String, minimumLength: Int) throws -> Secret {
        guard (minimumLength...512).contains(input.count),
              input.contains(where: { $0.isNewline }) == false else {
            throw StorageStepError.invalidValue(
                "The secret is required, must contain at least \(minimumLength) characters, cannot contain a newline, and cannot exceed 512 characters."
            )
        }
        return Secret(value: input)
    }

    private func runAWSCLI(
        _ command: [String],
        configuration: StorageConfiguration,
        dockerNetwork: String? = nil,
        standardInput: String? = nil
    ) throws -> CommandResult {
        let target = s3CommandTarget(for: configuration, dockerNetwork: dockerNetwork)
        var arguments = ["run", "--rm", "--interactive"]
        if let network = target.dockerNetwork {
            arguments += ["--network", network]
        }
        arguments += [
            "--env", "AWS_ACCESS_KEY_ID",
            "--env", "AWS_SECRET_ACCESS_KEY",
            "--env", "AWS_DEFAULT_REGION",
            "--env", "AWS_EC2_METADATA_DISABLED",
            "--env", "AWS_PAGER",
            Self.awsCLIImage,
            "--no-cli-pager",
            "--color", "off"
        ]
        if let endpoint = target.endpoint {
            arguments += ["--endpoint-url", endpoint]
        }
        arguments += command

        return try runDocker(
            arguments,
            environment: [
                "AWS_ACCESS_KEY_ID": configuration.accessKeyId,
                "AWS_SECRET_ACCESS_KEY": configuration.secretAccessKey.value,
                "AWS_DEFAULT_REGION": configuration.region ?? "us-east-1",
                "AWS_EC2_METADATA_DISABLED": "true",
                "AWS_PAGER": ""
            ],
            standardInput: standardInput
        )
    }

    private func requireStorageSuccess(
        _ command: [String],
        operation: String,
        configuration: StorageConfiguration,
        dockerNetwork: String?,
        standardInput: String? = nil
    ) throws -> CommandResult {
        let result = try runAWSCLI(
            command,
            configuration: configuration,
            dockerNetwork: dockerNetwork,
            standardInput: standardInput
        )
        guard result.succeeded else {
            throw StorageStepError.storageOperationFailed(
                operation: operation,
                details: details(from: result)
            )
        }
        return result
    }

    private func s3CommandTarget(
        for configuration: StorageConfiguration,
        dockerNetwork: String?
    ) -> S3CommandTarget {
        guard configuration.provider != .awsS3 else {
            return S3CommandTarget(endpoint: nil, dockerNetwork: dockerNetwork)
        }

        var endpoint = configuration.address
        var resolvedNetwork = dockerNetwork

        if dockerNetwork == nil,
           let host = URLComponents(string: endpoint)?.host,
           isLoopbackHost(host) {
            switch operatingSystem {
            case .macOS:
                endpoint = replacingHost(in: endpoint, with: "host.docker.internal")
            case .linux:
                resolvedNetwork = "host"
            }
        }

        return S3CommandTarget(endpoint: endpoint, dockerNetwork: resolvedNetwork)
    }

    private func replacingHost(in address: String, with host: String) -> String {
        guard var components = URLComponents(string: address) else { return address }
        components.host = host
        return components.string ?? address
    }

    private func isLoopbackHost(_ host: String) -> Bool {
        let normalizedHost = host.lowercased()
        return normalizedHost == "localhost" ||
            normalizedHost == "localhost." ||
            normalizedHost.hasPrefix("127.") ||
            normalizedHost == "::1" ||
            normalizedHost == "0:0:0:0:0:0:0:1"
    }

    private func runDocker(
        _ arguments: [String],
        environment: [String: String] = [:],
        standardInput: String? = nil
    ) throws -> CommandResult {
        do {
            return try commandRunner.run(
                "docker",
                arguments: arguments,
                environment: environment,
                standardInput: standardInput
            )
        } catch {
            throw StorageStepError.dockerCommandFailed(
                action: "run an object storage setup command",
                details: error.localizedDescription
            )
        }
    }

    private func requireDockerSuccess(
        _ arguments: [String],
        action: String,
        environment: [String: String] = [:]
    ) throws -> CommandResult {
        let result = try runDocker(arguments, environment: environment)
        guard result.succeeded else {
            throw StorageStepError.dockerCommandFailed(
                action: action,
                details: details(from: result)
            )
        }
        return result
    }

    private func details(from result: CommandResult) -> String? {
        if result.standardError.isEmpty == false { return result.standardError }
        if result.standardOutput.isEmpty == false { return result.standardOutput }
        return nil
    }

    static let minIODockerfile = """
    FROM golang:1.24.8-alpine AS build
    RUN apk add --no-cache ca-certificates git
    RUN CGO_ENABLED=0 GOBIN=/out go install github.com/minio/minio@\(minIORelease)

    FROM alpine:3.22
    RUN apk add --no-cache ca-certificates
    COPY --from=build /out/minio /usr/local/bin/minio
    VOLUME ["/data"]
    EXPOSE 9000 9001
    ENTRYPOINT ["minio"]
    """
}

private struct S3CommandTarget {
    let endpoint: String?
    let dockerNetwork: String?
}
