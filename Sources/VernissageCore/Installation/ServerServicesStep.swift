import Foundation

enum ServerServicesStepError: LocalizedError, Equatable {
    case missingConfiguration(String)
    case invalidGeneratedConfiguration(String)
    case containerAlreadyExists(String)
    case dockerCommandFailed(action: String, details: String?)
    case serviceStartupTimedOut(service: String, details: String?)
    case databaseTableInspectionFailed(String?)
    case vernissageTablesNotFound

    var errorDescription: String? {
        switch self {
        case .missingConfiguration(let name):
            "The \(name) configuration is missing. Complete all previous installer steps first."
        case .invalidGeneratedConfiguration(let name):
            "The installer could not generate a valid \(name) configuration."
        case .containerAlreadyExists(let name):
            "A Docker container named \(name) already exists. The installer will not replace it automatically."
        case .dockerCommandFailed(let action, let details):
            Self.message("Docker could not \(action).", details: details)
        case .serviceStartupTimedOut(let service, let details):
            Self.message(
                "The Vernissage \(service) service did not become healthy in time. The container was preserved for diagnostics.",
                details: details
            )
        case .databaseTableInspectionFailed(let details):
            Self.message("The installer could not list the Vernissage database tables.", details: details)
        case .vernissageTablesNotFound:
            "The API health endpoint responded, but the required Vernissage Users table was not found."
        }
    }

    private static func message(_ summary: String, details: String?) -> String {
        guard let details, details.isEmpty == false else { return summary }
        return "\(summary) Details: \(details)"
    }
}

struct ServerServicesStep {
    static let serverImage = "mczachurski/vernissage-server:latest"
    static let apiNetworkAlias = "vernissage-api.internal"
    static let jobsNetworkAlias = "vernissage-jobs.internal"
    static let postgresImage = "postgres:18"

    private let console: Console
    private let commandRunner: any CommandRunning
    private let waitBeforeRetry: () -> Void
    private let healthAttempts: Int
    private let operatingSystem: HostOperatingSystem

    init(
        console: Console,
        commandRunner: any CommandRunning,
        waitBeforeRetry: @escaping () -> Void,
        healthAttempts: Int = ServiceReadinessPolicy.maximumAttempts,
        operatingSystem: HostOperatingSystem
    ) {
        self.console = console
        self.commandRunner = commandRunner
        self.waitBeforeRetry = waitBeforeRetry
        self.healthAttempts = healthAttempts
        self.operatingSystem = operatingSystem
    }

    static func live(colorsEnabled: Bool) -> ServerServicesStep {
        ServerServicesStep(
            console: .live(colorsEnabled: colorsEnabled),
            commandRunner: ProcessCommandRunner(),
            waitBeforeRetry: { Thread.sleep(forTimeInterval: 1) },
            operatingSystem: .current
        )
    }

    func run(context: InstallationContext) throws {
        let names = context.resourceNames
        console.section("Vernissage API and Jobs")
        console.guidance(InstallationStepGuidance.serverServices)

        let collected = try collectedConfiguration(from: context)
        let runtime = try makeRuntimeConfiguration(collected)

        try ensureContainersDoNotExist(names: names)
        try createNetworkIfNeeded(named: names.networkName)
        try pullServerImage()

        try startContainer(
            name: names.apiContainerName,
            networkName: names.networkName,
            networkAlias: Self.apiNetworkAlias,
            environment: runtime.environment(
                disableQueueJobs: true,
                disableScheduledJobs: true
            )
        )
        let apiHealth = try waitForHealthyService(
            named: "API",
            containerName: names.apiContainerName
        )

        let tables = try inspectDatabaseTables(
            collected.database,
            defaultNetworkName: names.networkName
        )

        try startContainer(
            name: names.jobsContainerName,
            networkName: names.networkName,
            networkAlias: Self.jobsNetworkAlias,
            environment: runtime.environment(
                disableQueueJobs: false,
                disableScheduledJobs: false
            )
        )
        let jobsHealth = try waitForHealthyService(
            named: "Jobs",
            containerName: names.jobsContainerName
        )

        context.serverServices = ServerServicesConfiguration(
            image: Self.serverImage,
            networkName: names.networkName,
            apiContainerName: names.apiContainerName,
            jobsContainerName: names.jobsContainerName,
            apiNetworkAlias: Self.apiNetworkAlias,
            jobsNetworkAlias: Self.jobsNetworkAlias,
            baseAddress: runtime.baseAddress,
            apiHealth: apiHealth,
            jobsHealth: jobsHealth,
            databaseTables: tables
        )
        console.success("Vernissage API and Jobs services are running.")
    }

    private func collectedConfiguration(from context: InstallationContext) throws -> CollectedConfiguration {
        guard let server = context.server else {
            throw ServerServicesStepError.missingConfiguration("server and domain")
        }
        guard let database = context.database else {
            throw ServerServicesStepError.missingConfiguration("PostgreSQL database")
        }
        guard let redis = context.redis else {
            throw ServerServicesStepError.missingConfiguration("Redis")
        }
        guard let storage = context.storage else {
            throw ServerServicesStepError.missingConfiguration("S3 object storage")
        }
        return CollectedConfiguration(
            server: server,
            database: database,
            redis: redis,
            storage: storage
        )
    }

    private func makeRuntimeConfiguration(
        _ collected: CollectedConfiguration
    ) throws -> ServerRuntimeConfiguration {
        let baseAddress = "https://\(collected.server.domain)"
        let connectionString = try makePostgreSQLURL(collected.database)
        let queueURL = try makeRedisURL(collected.redis)
        let storageAddress = try makeStorageAddress(collected.storage.address)

        return ServerRuntimeConfiguration(
            baseAddress: baseAddress,
            sharedEnvironment: [
                "VERNISSAGE_BASEADDRESS": baseAddress,
                "VERNISSAGE_CONNECTIONSTRING": connectionString,
                "VERNISSAGE_QUEUEURL": queueURL,
                "VERNISSAGE_S3ADDRESS": storageAddress,
                "VERNISSAGE_S3REGION": collected.storage.region ?? "",
                "VERNISSAGE_S3BUCKET": collected.storage.bucket,
                "VERNISSAGE_S3ACCESSKEYID": collected.storage.accessKeyId,
                "VERNISSAGE_S3SECRETACCESSKEY": collected.storage.secretAccessKey.value,
                "VERNISSAGE_S3HTTP1ONLYMODE": String(collected.storage.http1OnlyMode)
            ]
        )
    }

    private func makePostgreSQLURL(_ configuration: DatabaseConfiguration) throws -> String {
        var components = URLComponents()
        components.scheme = "postgres"
        components.host = containerHost(for: configuration.host)
        components.port = Int(configuration.port)
        components.user = configuration.username
        components.password = configuration.password.value
        components.path = "/\(configuration.database)"
        components.queryItems = [
            URLQueryItem(name: "tlsmode", value: configuration.tlsMode.rawValue)
        ]

        guard let value = components.string else {
            throw ServerServicesStepError.invalidGeneratedConfiguration("PostgreSQL connection")
        }
        return value
    }

    private func makeRedisURL(_ configuration: RedisConfiguration) throws -> String {
        guard var components = URLComponents(string: configuration.url.value) else {
            throw ServerServicesStepError.invalidGeneratedConfiguration("Redis connection")
        }
        components.host = containerHost(for: configuration.host)
        guard let value = components.string else {
            throw ServerServicesStepError.invalidGeneratedConfiguration("Redis connection")
        }
        return value
    }

    private func makeStorageAddress(_ address: String) throws -> String {
        guard var components = URLComponents(string: address), let host = components.host else {
            throw ServerServicesStepError.invalidGeneratedConfiguration("S3 address")
        }
        components.host = containerHost(for: host)
        guard let value = components.string else {
            throw ServerServicesStepError.invalidGeneratedConfiguration("S3 address")
        }
        return value
    }

    private func ensureContainersDoNotExist(names: InstallationResourceNames) throws {
        for name in [names.apiContainerName, names.jobsContainerName] {
            let inspection = try runDocker(["container", "inspect", name])
            if inspection.succeeded {
                throw ServerServicesStepError.containerAlreadyExists(name)
            }
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

    private func pullServerImage() throws {
        console.info("Pulling \(Self.serverImage)…")
        _ = try requireDockerSuccess(
            ["pull", Self.serverImage],
            action: "pull the Vernissage Server image"
        )
        console.success("Vernissage Server image is available.")
    }

    private func startContainer(
        name: String,
        networkName: String,
        networkAlias: String,
        environment: [String: String]
    ) throws {
        var arguments = [
            "run", "--detach",
            "--name", name,
            "--restart", "unless-stopped",
            "--network", networkName,
            "--network-alias", networkAlias
        ]
        if operatingSystem == .linux {
            arguments += ["--add-host", "host.docker.internal:host-gateway"]
        }
        for key in environment.keys.sorted() {
            arguments += ["--env", key]
        }
        arguments += [
            Self.serverImage,
            "serve",
            "--env", "production",
            "--hostname", "0.0.0.0",
            "--port", "8080"
        ]

        _ = try requireDockerSuccess(
            arguments,
            action: "start the \(name) container",
            environment: environment
        )
        console.success("Started Docker container: \(name)")
    }

    private func waitForHealthyService(
        named service: String,
        containerName: String
    ) throws -> ServerHealth {
        console.info(
            "Waiting up to \(ServiceReadinessPolicy.timeoutDescription) for the Vernissage \(service) health endpoint. The check is retried automatically…"
        )
        var lastDetails: String?

        for attempt in 0..<healthAttempts {
            if attempt > 0 {
                waitBeforeRetry()
            }

            let result = try runDocker([
                "exec", containerName,
                "curl", "--fail", "--silent", "--show-error", "--max-time", "5",
                "http://127.0.0.1:8080/api/v1/health"
            ])

            guard result.succeeded else {
                lastDetails = details(from: result)
                continue
            }

            do {
                let health = try JSONDecoder().decode(
                    ServerHealth.self,
                    from: Data(result.standardOutput.utf8)
                )
                guard health.isDatabaseHealthy,
                      health.isQueueHealthy,
                      health.isStorageHealthy else {
                    lastDetails = healthSummary(health)
                    continue
                }

                printHealth(health, service: service)
                return health
            } catch {
                lastDetails = "Invalid health response: \(error.localizedDescription)"
            }
        }

        throw ServerServicesStepError.serviceStartupTimedOut(
            service: service,
            details: DockerContainerDiagnostics.startupFailureDetails(
                lastDetails,
                containerName: containerName
            )
        )
    }

    private func printHealth(_ health: ServerHealth, service: String) {
        console.success("\(service): PostgreSQL is healthy.")
        console.success("\(service): Redis queues are healthy.")
        console.success("\(service): S3 storage is healthy.")
        if health.isWebPushHealthy {
            console.success("\(service): WebPush is healthy.")
        } else {
            console.warning("\(service): WebPush is not healthy yet; this is expected until the WebPush service is installed.")
        }
    }

    private func healthSummary(_ health: ServerHealth) -> String {
        "database=\(health.isDatabaseHealthy), queue=\(health.isQueueHealthy), webPush=\(health.isWebPushHealthy), storage=\(health.isStorageHealthy)"
    }

    private func inspectDatabaseTables(
        _ configuration: DatabaseConfiguration,
        defaultNetworkName: String
    ) throws -> [String] {
        console.info("Reading tables created by Vernissage migrations…")
        let target = databaseCommandTarget(
            for: configuration,
            defaultNetworkName: defaultNetworkName
        )
        var arguments = ["run", "--rm"]
        if let network = target.dockerNetwork {
            arguments += ["--network", network]
        }
        arguments += [
            "--env", "PGPASSWORD",
            "--env", "PGSSLMODE",
            Self.postgresImage,
            "psql",
            "--host", target.host,
            "--port", String(configuration.port),
            "--username", configuration.username,
            "--dbname", configuration.database,
            "--no-password",
            "--tuples-only",
            "--no-align",
            "--command", "SELECT tablename FROM pg_catalog.pg_tables WHERE schemaname = 'public' ORDER BY tablename;"
        ]

        let result = try runDocker(
            arguments,
            environment: [
                "PGPASSWORD": configuration.password.value,
                "PGSSLMODE": configuration.tlsMode.rawValue
            ]
        )
        guard result.succeeded else {
            throw ServerServicesStepError.databaseTableInspectionFailed(details(from: result))
        }

        let tables = result.standardOutput
            .split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
        guard tables.contains("Users") else {
            throw ServerServicesStepError.vernissageTablesNotFound
        }

        console.success("Vernissage database migrations created \(tables.count) tables:")
        for table in tables {
            console.line("  • \(table)")
        }
        return tables
    }

    private func databaseCommandTarget(
        for configuration: DatabaseConfiguration,
        defaultNetworkName: String
    ) -> DatabaseCommandTarget {
        if configuration.mode == .localContainer {
            return DatabaseCommandTarget(
                host: configuration.host,
                dockerNetwork: configuration.localResources?.networkName ?? defaultNetworkName
            )
        }

        guard isLoopbackHost(configuration.host) else {
            return DatabaseCommandTarget(host: configuration.host, dockerNetwork: nil)
        }
        switch operatingSystem {
        case .macOS:
            return DatabaseCommandTarget(host: "host.docker.internal", dockerNetwork: nil)
        case .linux:
            return DatabaseCommandTarget(host: configuration.host, dockerNetwork: "host")
        }
    }

    private func containerHost(for host: String) -> String {
        isLoopbackHost(host) ? "host.docker.internal" : host
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
            throw ServerServicesStepError.dockerCommandFailed(
                action: "run a Vernissage Server setup command",
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
            throw ServerServicesStepError.dockerCommandFailed(
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
}

private struct CollectedConfiguration {
    let server: ServerConfiguration
    let database: DatabaseConfiguration
    let redis: RedisConfiguration
    let storage: StorageConfiguration
}

private struct ServerRuntimeConfiguration {
    let baseAddress: String
    let sharedEnvironment: [String: String]

    func environment(
        disableQueueJobs: Bool,
        disableScheduledJobs: Bool
    ) -> [String: String] {
        var values = sharedEnvironment
        values["VERNISSAGE_DISABLEQUEUEJOBS"] = String(disableQueueJobs)
        values["VERNISSAGE_DISABLESCHEDULEDJOBS"] = String(disableScheduledJobs)
        return values
    }
}

private struct DatabaseCommandTarget {
    let host: String
    let dockerNetwork: String?
}
