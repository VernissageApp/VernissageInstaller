import Foundation

enum RedisStepError: LocalizedError, Equatable {
    case invalidValue(String)
    case dockerCommandFailed(action: String, details: String?)
    case localContainerAlreadyExists(String)
    case localVolumeAlreadyExists(String)
    case localRedisStartupTimedOut(String?)
    case redisOperationFailed(operation: String, details: String?)
    case unexpectedResponse(operation: String, expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .invalidValue(let message):
            message
        case .dockerCommandFailed(let action, let details):
            Self.message("Docker could not \(action).", details: details)
        case .localContainerAlreadyExists(let name):
            "A Docker container named \(name) already exists. The installer will not replace it automatically."
        case .localVolumeAlreadyExists(let name):
            "A Docker volume named \(name) already exists. It may contain queued jobs, so the installer will not reuse or remove it automatically."
        case .localRedisStartupTimedOut(let details):
            Self.message("The local Redis container did not become ready in time. It was preserved for diagnostics.", details: details)
        case .redisOperationFailed(let operation, let details):
            Self.message("The Redis test could not \(operation).", details: details)
        case .unexpectedResponse(let operation, let expected, let actual):
            "Redis returned an unexpected response while testing \(operation). Expected '\(expected)', received '\(actual)'."
        }
    }

    private static func message(_ summary: String, details: String?) -> String {
        guard let details, details.isEmpty == false else { return summary }
        return "\(summary) Redis reported: \(details)"
    }
}

struct RedisStep {
    static let redisImage = "redis:8.8.1-alpine"

    private let console: Console
    private let commandRunner: any CommandRunning
    private let makeTestKey: () -> String
    private let makeTestValue: () -> String
    private let makePassword: () -> Secret
    private let waitBeforeRetry: () -> Void
    private let readinessAttempts: Int
    private let operatingSystem: HostOperatingSystem

    init(
        console: Console,
        commandRunner: any CommandRunning,
        makeTestKey: @escaping () -> String,
        makeTestValue: @escaping () -> String,
        makePassword: @escaping () -> Secret,
        waitBeforeRetry: @escaping () -> Void,
        readinessAttempts: Int = ServiceReadinessPolicy.maximumAttempts,
        operatingSystem: HostOperatingSystem
    ) {
        self.console = console
        self.commandRunner = commandRunner
        self.makeTestKey = makeTestKey
        self.makeTestValue = makeTestValue
        self.makePassword = makePassword
        self.waitBeforeRetry = waitBeforeRetry
        self.readinessAttempts = readinessAttempts
        self.operatingSystem = operatingSystem
    }

    static func live(colorsEnabled: Bool) -> RedisStep {
        RedisStep(
            console: .live(colorsEnabled: colorsEnabled),
            commandRunner: ProcessCommandRunner(),
            makeTestKey: { "vernissage:installer:test:\(UUID().uuidString.lowercased())" },
            makeTestValue: { UUID().uuidString.lowercased() },
            makePassword: {
                Secret(value: UUID().uuidString.replacingOccurrences(of: "-", with: ""))
            },
            waitBeforeRetry: { Thread.sleep(forTimeInterval: 1) },
            operatingSystem: .current
        )
    }

    func run(context: InstallationContext, input: RedisStepInput? = nil) throws {
        console.section("Redis queues")
        console.guidance(InstallationStepGuidance.redis)

        let mode: RedisInstallationMode
        switch input {
        case .local: mode = .localContainer
        case .existing: mode = .existing
        case nil: mode = try readInstallationMode()
        }

        switch mode {
        case .localContainer:
            try installLocalRedis(context: context, input: input)
        case .existing:
            try configureExistingRedis(context: context, input: input)
        }
    }

    private func readInstallationMode() throws -> RedisInstallationMode {
        console.optionListHeader()
        console.line("  1. Install Redis in a local Docker container")
        console.line("  2. Use an existing Redis service")

        while true {
            guard let input = console.prompt("Redis option [1]:") else {
                throw RedisStepError.invalidValue("A Redis option is required.")
            }

            switch input.lowercased() {
            case "", "1", "local", "automatic": return .localContainer
            case "2", "existing", "managed": return .existing
            default: console.warning("Choose 1 for a local Redis container or 2 for an existing Redis service.")
            }
        }
    }

    private func configureExistingRedis(context: InstallationContext, input: RedisStepInput?) throws {
        let configuration: RedisConfiguration
        if case .existing(let username, let password, let host, let port, let usesTLS) = input {
            configuration = try makeExistingConfiguration(
                username: username,
                password: password,
                host: host,
                port: port,
                usesTLS: usesTLS
            )
        } else {
            configuration = try readExistingConfiguration()
        }

        try testRedis(configuration)
        context.redis = configuration
        console.success("Existing Redis service is ready for Vernissage queues.")
    }

    private func readExistingConfiguration() throws -> RedisConfiguration {
        let username = try readUsername()
        let password = try readPassword()
        let host = try readHost()
        let port = try readPort()
        let usesTLS = try readTLSMode()
        return try makeExistingConfiguration(
            username: username,
            password: password,
            host: host,
            port: port,
            usesTLS: usesTLS
        )
    }

    private func makeExistingConfiguration(
        username: String,
        password: Secret,
        host: String,
        port: UInt16,
        usesTLS: Bool
    ) throws -> RedisConfiguration {
        let url = try makeURL(
            username: username,
            password: password,
            host: host,
            port: port,
            database: 0,
            usesTLS: usesTLS
        )

        return RedisConfiguration(
            mode: .existing,
            url: Secret(value: url),
            username: username,
            host: host,
            port: port,
            database: 0,
            password: password,
            usesTLS: usesTLS,
            localResources: nil
        )
    }

    private func installLocalRedis(context: InstallationContext, input: RedisStepInput?) throws {
        let names = context.resourceNames
        let password: Secret
        if case .local(let providedPassword) = input {
            password = providedPassword
            console.info("Using the Redis password from the installation secrets file.")
        } else {
            console.info("The installer will generate a Redis password automatically and will not display it.")
            password = makePassword()
        }

        try ensureLocalResourcesDoNotExist(names: names)
        try createNetworkIfNeeded(named: names.networkName)
        try createLocalVolume(named: names.redisVolumeName)
        try writeLocalConfiguration(
            password: password,
            volumeName: names.redisVolumeName
        )
        try createLocalContainer(names: names)

        let configuration = RedisConfiguration(
            mode: .localContainer,
            url: Secret(value: makeLocalURL(
                password: password,
                containerName: names.redisContainerName
            )),
            username: "default",
            host: names.redisContainerName,
            port: 6379,
            database: 0,
            password: password,
            usesTLS: false,
            localResources: LocalRedisResources(
                image: Self.redisImage,
                containerName: names.redisContainerName,
                volumeName: names.redisVolumeName,
                networkName: names.networkName
            )
        )

        try waitForLocalRedis(
            configuration,
            containerName: names.redisContainerName
        )
        try testRedis(configuration, dockerNetwork: names.networkName)
        context.redis = configuration
        console.success("Local Redis is running in \(names.redisContainerName).")
        console.value(label: "Volume", value: names.redisVolumeName)
        console.value(label: "Network", value: names.networkName)
    }

    private func ensureLocalResourcesDoNotExist(names: InstallationResourceNames) throws {
        let containerInspection = try runDocker(["container", "inspect", names.redisContainerName])
        if containerInspection.succeeded {
            throw RedisStepError.localContainerAlreadyExists(names.redisContainerName)
        }

        let volumeInspection = try runDocker(["volume", "inspect", names.redisVolumeName])
        if volumeInspection.succeeded {
            throw RedisStepError.localVolumeAlreadyExists(names.redisVolumeName)
        }
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
            action: "create the Redis data volume"
        )
        console.success("Created persistent Docker volume: \(volumeName)")
    }

    private func writeLocalConfiguration(password: Secret, volumeName: String) throws {
        _ = try requireDockerSuccess(
            [
                "run", "--rm",
                "--env", "REDIS_PASSWORD",
                "--mount", "type=volume,source=\(volumeName),target=/data",
                "--entrypoint", "sh",
                Self.redisImage,
                "-c", Self.localConfigurationScript
            ],
            action: "write the local Redis configuration",
            environment: ["REDIS_PASSWORD": password.value]
        )
        console.success("Configured Redis authentication and append-only persistence.")
    }

    private func createLocalContainer(names: InstallationResourceNames) throws {
        _ = try requireDockerSuccess(
            [
                "run", "--detach",
                "--name", names.redisContainerName,
                "--restart", "unless-stopped",
                "--network", names.networkName,
                "--mount", "type=volume,source=\(names.redisVolumeName),target=/data",
                Self.redisImage,
                "redis-server", "/data/redis.conf"
            ],
            action: "start the Redis container"
        )
        console.success("Started Docker container: \(names.redisContainerName)")
    }

    private func waitForLocalRedis(
        _ configuration: RedisConfiguration,
        containerName: String
    ) throws {
        console.info("Waiting for Redis to accept authenticated connections…")
        var lastDetails: String?

        for attempt in 0..<readinessAttempts {
            let result = try runRedisCLI(
                ["PING"],
                configuration: configuration,
                dockerNetwork: configuration.localResources?.networkName
            )
            if result.succeeded, result.standardOutput == "PONG" {
                console.success("Redis is accepting connections.")
                return
            }

            lastDetails = details(from: result)
            if attempt < readinessAttempts - 1 {
                waitBeforeRetry()
            }
        }

        throw RedisStepError.localRedisStartupTimedOut(
            DockerContainerDiagnostics.startupFailureDetails(
                lastDetails,
                containerName: containerName
            )
        )
    }

    private func testRedis(
        _ configuration: RedisConfiguration,
        dockerNetwork: String? = nil
    ) throws {
        console.info("Testing Redis PING, SET, GET, and DEL operations…")
        let key = makeTestKey()
        let value = makeTestValue()

        let ping = try requireRedisSuccess(
            ["PING"],
            operation: "execute PING",
            configuration: configuration,
            dockerNetwork: dockerNetwork
        )
        try requireResponse(ping, operation: "PING", expected: "PONG")

        var keyWasSet = false
        defer {
            if keyWasSet {
                _ = try? runRedisCLI(
                    ["DEL", key],
                    configuration: configuration,
                    dockerNetwork: dockerNetwork
                )
            }
        }

        let set = try requireRedisSuccess(
            ["SET", key, value, "EX", "60"],
            operation: "write a temporary key",
            configuration: configuration,
            dockerNetwork: dockerNetwork
        )
        keyWasSet = true
        try requireResponse(set, operation: "SET", expected: "OK")

        let get = try requireRedisSuccess(
            ["GET", key],
            operation: "read the temporary key",
            configuration: configuration,
            dockerNetwork: dockerNetwork
        )

        let delete = try requireRedisSuccess(
            ["DEL", key],
            operation: "delete the temporary key",
            configuration: configuration,
            dockerNetwork: dockerNetwork
        )
        try requireResponse(delete, operation: "DEL", expected: "1")
        keyWasSet = false

        try requireResponse(get, operation: "GET", expected: value)
        console.success("Redis PING, SET, GET, value verification, and DEL tests passed.")
    }

    private func readUsername() throws -> String {
        while true {
            guard let input = console.prompt("Redis username [default]:") else {
                throw RedisStepError.invalidValue("A Redis username is required.")
            }

            let username = input.trimmingCharacters(in: .whitespacesAndNewlines)
            if username.isEmpty || username == "default" {
                return "default"
            }

            console.warning(
                "Vernissage currently supports only the default Redis ACL user. Enter 'default' or press Return."
            )
        }
    }

    private func readPassword() throws -> Secret {
        while true {
            guard let input = console.securePrompt("Redis password:") else {
                throw RedisStepError.invalidValue("A Redis password is required.")
            }

            guard input.isEmpty == false else {
                console.warning("The Redis password cannot be empty.")
                continue
            }
            return Secret(value: input)
        }
    }

    private func readHost() throws -> String {
        while true {
            guard let input = console.prompt("Redis host:") else {
                throw RedisStepError.invalidValue("A Redis host is required.")
            }

            let host = input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard host.isEmpty == false,
                  host.count <= 253,
                  host.contains(where: { $0.isWhitespace || $0.isNewline }) == false,
                  host.contains("://") == false,
                  host.contains("/") == false else {
                console.warning("Enter a Redis hostname or IP address without a scheme, port, or path.")
                continue
            }
            return host
        }
    }

    private func readPort() throws -> UInt16 {
        while true {
            guard let input = console.prompt("Redis port [6379]:") else {
                throw RedisStepError.invalidValue("A Redis port is required.")
            }

            if input.isEmpty { return 6379 }
            if let port = UInt16(input), port > 0 { return port }
            console.warning("Enter a port number between 1 and 65535.")
        }
    }

    private func readTLSMode() throws -> Bool {
        console.line("  1. Enable TLS (recommended)")
        console.line("  2. Disable TLS")

        while true {
            guard let input = console.prompt("TLS option [1]:") else {
                throw RedisStepError.invalidValue("A TLS option is required.")
            }

            switch input.lowercased() {
            case "", "1", "enable", "enabled", "yes": return true
            case "2", "disable", "disabled", "no": return false
            default: console.warning("Choose 1 to enable TLS or 2 to disable it.")
            }
        }
    }

    private func makeURL(
        username: String,
        password: Secret,
        host: String,
        port: UInt16,
        database: Int,
        usesTLS: Bool
    ) throws -> String {
        var components = URLComponents()
        components.scheme = usesTLS ? "rediss" : "redis"
        components.host = host
        components.port = Int(port)
        components.user = username
        components.password = password.value
        components.path = "/\(database)"

        guard let url = components.string else {
            throw RedisStepError.invalidValue("The Redis connection URL could not be generated.")
        }
        return url
    }

    private func makeLocalURL(password: Secret, containerName: String) -> String {
        var components = URLComponents()
        components.scheme = "redis"
        components.host = containerName
        components.port = 6379
        components.user = "default"
        components.password = password.value
        components.path = "/0"
        return components.string ?? ""
    }

    private func requireRedisSuccess(
        _ command: [String],
        operation: String,
        configuration: RedisConfiguration,
        dockerNetwork: String?
    ) throws -> CommandResult {
        let result = try runRedisCLI(
            command,
            configuration: configuration,
            dockerNetwork: dockerNetwork
        )
        guard result.succeeded else {
            throw RedisStepError.redisOperationFailed(
                operation: operation,
                details: details(from: result)
            )
        }
        return result
    }

    private func requireResponse(
        _ result: CommandResult,
        operation: String,
        expected: String
    ) throws {
        guard result.standardOutput == expected else {
            throw RedisStepError.unexpectedResponse(
                operation: operation,
                expected: expected,
                actual: result.standardOutput
            )
        }
    }

    private func runRedisCLI(
        _ command: [String],
        configuration: RedisConfiguration,
        dockerNetwork: String? = nil
    ) throws -> CommandResult {
        let target = redisCommandTarget(for: configuration, dockerNetwork: dockerNetwork)
        var arguments = ["run", "--rm"]
        if let network = target.dockerNetwork {
            arguments += ["--network", network]
        }

        var environment: [String: String] = [:]
        if let password = configuration.password {
            arguments += ["--env", "REDISCLI_AUTH"]
            environment["REDISCLI_AUTH"] = password.value
        }

        arguments += [
            Self.redisImage,
            "redis-cli",
            "-h", target.host,
            "-p", String(configuration.port),
            "-n", String(configuration.database),
            "--raw",
            "--no-auth-warning"
        ]
        if configuration.usesTLS {
            arguments.append("--tls")
        }
        arguments += command

        return try runDocker(arguments, environment: environment)
    }

    private func redisCommandTarget(
        for configuration: RedisConfiguration,
        dockerNetwork: String?
    ) -> RedisCommandTarget {
        var host = configuration.host
        var resolvedNetwork = dockerNetwork

        if dockerNetwork == nil, isLoopbackHost(host) {
            switch operatingSystem {
            case .macOS:
                host = "host.docker.internal"
            case .linux:
                resolvedNetwork = "host"
            }
        }

        return RedisCommandTarget(host: host, dockerNetwork: resolvedNetwork)
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
        environment: [String: String] = [:]
    ) throws -> CommandResult {
        do {
            return try commandRunner.run(
                "docker",
                arguments: arguments,
                environment: environment,
                standardInput: nil
            )
        } catch {
            throw RedisStepError.dockerCommandFailed(
                action: "run a Redis setup command",
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
            throw RedisStepError.dockerCommandFailed(
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

    private static let localConfigurationScript = """
    set -eu
    umask 077
    printf 'appendonly yes\nappendfsync everysec\nrequirepass %s\n' "$REDIS_PASSWORD" > /data/redis.conf
    chown redis:redis /data/redis.conf
    """
}

private struct RedisCommandTarget {
    let host: String
    let dockerNetwork: String?
}
