import Foundation

enum DatabaseStepError: LocalizedError, Equatable {
    case invalidValue(String)
    case dockerCommandFailed(action: String, details: String?)
    case localContainerAlreadyExists(String)
    case localVolumeAlreadyExists(String)
    case localDatabaseStartupTimedOut
    case databasePermissionTestFailed(String?)

    var errorDescription: String? {
        switch self {
        case .invalidValue(let message):
            message
        case .dockerCommandFailed(let action, let details):
            Self.message("Docker could not \(action).", details: details)
        case .localContainerAlreadyExists(let name):
            "A Docker container named \(name) already exists. To protect its data, the installer will not replace it automatically."
        case .localVolumeAlreadyExists(let name):
            "A Docker volume named \(name) already exists. It may contain PostgreSQL data, so the installer will not reuse or remove it automatically."
        case .localDatabaseStartupTimedOut:
            "The local PostgreSQL container did not become ready in time. It has been preserved for diagnostics."
        case .databasePermissionTestFailed(let details):
            Self.message(
                "The PostgreSQL connection or migration permission test failed.",
                details: details
            )
        }
    }

    private static func message(_ summary: String, details: String?) -> String {
        guard let details, !details.isEmpty else { return summary }
        return "\(summary) PostgreSQL reported: \(details)"
    }
}

struct DatabaseStep {
    static let postgresImage = "postgres:18"
    static let databaseName = "vernissage"

    private let console: Console
    private let commandRunner: any CommandRunning
    private let makeSchemaName: () -> String
    private let waitBeforeRetry: () -> Void
    private let readinessAttempts: Int
    private let operatingSystem: HostOperatingSystem

    init(
        console: Console,
        commandRunner: any CommandRunning,
        makeSchemaName: @escaping () -> String,
        waitBeforeRetry: @escaping () -> Void,
        readinessAttempts: Int = 30,
        operatingSystem: HostOperatingSystem
    ) {
        self.console = console
        self.commandRunner = commandRunner
        self.makeSchemaName = makeSchemaName
        self.waitBeforeRetry = waitBeforeRetry
        self.readinessAttempts = readinessAttempts
        self.operatingSystem = operatingSystem
    }

    static func live(colorsEnabled: Bool) -> DatabaseStep {
        DatabaseStep(
            console: .live(colorsEnabled: colorsEnabled),
            commandRunner: ProcessCommandRunner(),
            makeSchemaName: {
                "vernissage_installer_" + UUID().uuidString
                    .lowercased()
                    .replacingOccurrences(of: "-", with: "")
            },
            waitBeforeRetry: { Thread.sleep(forTimeInterval: 1) },
            operatingSystem: .current
        )
    }

    func run(context: InstallationContext, input: DatabaseStepInput? = nil) throws {
        console.section("PostgreSQL database")
        console.guidance(InstallationStepGuidance.database)

        let mode: DatabaseInstallationMode
        switch input {
        case .existing: mode = .existing
        case .local: mode = .localContainer
        case nil: mode = try readInstallationMode()
        }

        switch mode {
        case .existing:
            try configureExistingDatabase(context: context, input: input)
        case .localContainer:
            try installLocalDatabase(context: context, input: input)
        }
    }

    private func readInstallationMode() throws -> DatabaseInstallationMode {
        console.optionListHeader()
        console.line("  1. Use an existing PostgreSQL database (recommended)")
        console.line("  2. Install PostgreSQL in a local Docker container")

        while true {
            guard let input = console.prompt("Database option [1]:") else {
                throw DatabaseStepError.invalidValue("A database option is required.")
            }

            switch input.lowercased() {
            case "", "1", "existing", "managed":
                return .existing
            case "2", "local", "automatic":
                return .localContainer
            default:
                console.warning("Choose 1 for an existing database or 2 for a local Docker database.")
            }
        }
    }

    private func configureExistingDatabase(context: InstallationContext, input: DatabaseStepInput?) throws {
        let host: String
        let port: UInt16
        let database: String
        let username: String
        let password: Secret
        let tlsMode: DatabaseTLSMode

        if case .existing(let providedHost, let providedPort, let providedDatabase, let providedUsername, let providedPassword, let providedTLSMode) = input {
            host = providedHost
            port = providedPort
            database = providedDatabase
            username = providedUsername
            password = providedPassword
            tlsMode = providedTLSMode
        } else {
            host = try requiredValue(
                field: "database host",
                question: "PostgreSQL host:",
                validator: validateHost
            )
            port = try readPort()
            database = try requiredValue(
                field: "database name",
                question: "PostgreSQL database name:",
                validator: validateDatabaseName
            )
            username = try requiredValue(
                field: "database username",
                question: "PostgreSQL username:",
                validator: validateUsername
            )
            password = try readPassword(confirm: false)
            tlsMode = try readTLSMode()
        }

        let configuration = DatabaseConfiguration(
            mode: .existing,
            host: host,
            port: port,
            database: database,
            username: username,
            password: password,
            tlsMode: tlsMode,
            localResources: nil
        )

        console.info("Testing the PostgreSQL connection and migration permissions…")
        try testDatabase(configuration)
        context.database = configuration
        console.success("Existing PostgreSQL database is ready for Vernissage.")
    }

    private func installLocalDatabase(context: InstallationContext, input: DatabaseStepInput?) throws {
        let names = context.resourceNames
        console.warning(
            "The supplied database user will own the local Vernissage database. Store its password in a password manager."
        )

        let username: String
        let password: Secret
        if case .local(let providedUsername, let providedPassword) = input {
            username = providedUsername
            password = providedPassword
        } else {
            username = try requiredValue(
                field: "database username",
                question: "New PostgreSQL username:",
                validator: validateUsername
            )
            password = try readPassword(confirm: true)
        }

        try ensureLocalResourcesDoNotExist(names: names)
        try createNetworkIfNeeded(named: names.networkName)
        try createLocalVolume(named: names.postgresqlVolumeName)
        try createLocalContainer(
            username: username,
            password: password,
            names: names
        )
        try waitForLocalDatabase(
            username: username,
            containerName: names.postgresqlContainerName
        )

        let resources = LocalPostgreSQLResources(
            image: Self.postgresImage,
            containerName: names.postgresqlContainerName,
            volumeName: names.postgresqlVolumeName,
            networkName: names.networkName
        )
        let configuration = DatabaseConfiguration(
            mode: .localContainer,
            host: names.postgresqlContainerName,
            port: 5432,
            database: Self.databaseName,
            username: username,
            password: password,
            tlsMode: .disable,
            localResources: resources
        )

        console.info("Testing the local PostgreSQL connection and migration permissions…")
        try testDatabase(configuration, dockerNetwork: names.networkName)
        context.database = configuration
        console.success("Local PostgreSQL database is running in \(names.postgresqlContainerName).")
        console.value(label: "Database", value: Self.databaseName)
        console.value(label: "Volume", value: names.postgresqlVolumeName)
        console.value(label: "Network", value: names.networkName)
        console.warning("Configure an off-server PostgreSQL backup before making the instance public.")
    }

    private func ensureLocalResourcesDoNotExist(names: InstallationResourceNames) throws {
        let containerInspection = try runDocker([
            "container", "inspect", names.postgresqlContainerName
        ])
        if containerInspection.succeeded {
            throw DatabaseStepError.localContainerAlreadyExists(names.postgresqlContainerName)
        }

        let volumeInspection = try runDocker([
            "volume", "inspect", names.postgresqlVolumeName
        ])
        if volumeInspection.succeeded {
            throw DatabaseStepError.localVolumeAlreadyExists(names.postgresqlVolumeName)
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
            action: "create the PostgreSQL data volume"
        )
        console.success("Created persistent Docker volume: \(volumeName)")
    }

    private func createLocalContainer(
        username: String,
        password: Secret,
        names: InstallationResourceNames
    ) throws {
        console.info("Starting PostgreSQL container from \(Self.postgresImage)…")

        _ = try requireDockerSuccess(
            [
                "run", "--detach",
                "--name", names.postgresqlContainerName,
                "--restart", "unless-stopped",
                "--network", names.networkName,
                "--env", "POSTGRES_DB",
                "--env", "POSTGRES_USER",
                "--env", "POSTGRES_PASSWORD",
                "--mount", "type=volume,source=\(names.postgresqlVolumeName),target=/var/lib/postgresql",
                Self.postgresImage
            ],
            action: "start the PostgreSQL container",
            environment: [
                "POSTGRES_DB": Self.databaseName,
                "POSTGRES_USER": username,
                "POSTGRES_PASSWORD": password.value
            ]
        )
        console.success("Started Docker container: \(names.postgresqlContainerName)")
    }

    private func waitForLocalDatabase(username: String, containerName: String) throws {
        console.info("Waiting for PostgreSQL to accept connections…")

        for attempt in 0..<readinessAttempts {
            let result = try runDocker([
                "exec", containerName,
                "pg_isready",
                "--username", username,
                "--dbname", Self.databaseName
            ])

            if result.succeeded {
                console.success("PostgreSQL is accepting connections.")
                return
            }

            if attempt < readinessAttempts - 1 {
                waitBeforeRetry()
            }
        }

        throw DatabaseStepError.localDatabaseStartupTimedOut
    }

    private func testDatabase(
        _ configuration: DatabaseConfiguration,
        dockerNetwork: String? = nil
    ) throws {
        let schema = makeSchemaName()
        let sql = """
        BEGIN;
        SELECT 1;
        CREATE SCHEMA \(schema) AUTHORIZATION CURRENT_USER;
        CREATE TABLE \(schema).migration_permission_test (id BIGINT PRIMARY KEY);
        DROP TABLE \(schema).migration_permission_test;
        DROP SCHEMA \(schema);
        COMMIT;
        """

        var arguments = ["run", "--rm", "--interactive"]
        var connectionHost = configuration.host

        if let dockerNetwork {
            arguments += ["--network", dockerNetwork]
        } else if isLoopbackHost(configuration.host) {
            switch operatingSystem {
            case .macOS:
                connectionHost = "host.docker.internal"
            case .linux:
                arguments += ["--network", "host"]
            }
        }

        arguments += [
            "--env", "PGPASSWORD",
            "--env", "PGSSLMODE",
            Self.postgresImage,
            "psql",
            "--host", connectionHost,
            "--port", String(configuration.port),
            "--username", configuration.username,
            "--dbname", configuration.database,
            "--no-password",
            "--set", "ON_ERROR_STOP=1"
        ]

        let result = try runDocker(
            arguments,
            environment: [
                "PGPASSWORD": configuration.password.value,
                "PGSSLMODE": configuration.tlsMode.rawValue
            ],
            standardInput: sql
        )

        guard result.succeeded else {
            throw DatabaseStepError.databasePermissionTestFailed(details(from: result))
        }

        console.success("SELECT, CREATE TABLE, and DROP TABLE completed in a temporary schema.")
    }

    private func isLoopbackHost(_ host: String) -> Bool {
        let normalizedHost = host.lowercased()
        return normalizedHost == "localhost" ||
            normalizedHost == "localhost." ||
            normalizedHost.hasPrefix("127.") ||
            normalizedHost == "::1" ||
            normalizedHost == "0:0:0:0:0:0:0:1"
    }

    private func readPort() throws -> UInt16 {
        while true {
            guard let input = console.prompt("PostgreSQL port [5432]:") else {
                throw DatabaseStepError.invalidValue("A PostgreSQL port is required.")
            }

            if input.isEmpty { return 5432 }
            if let port = UInt16(input), port > 0 { return port }
            console.warning("Enter a port number between 1 and 65535.")
        }
    }

    private func readTLSMode() throws -> DatabaseTLSMode {
        console.line("  1. Require TLS (recommended)")
        console.line("  2. Disable TLS")

        while true {
            guard let input = console.prompt("TLS option [1]:") else {
                throw DatabaseStepError.invalidValue("A TLS option is required.")
            }

            switch input.lowercased() {
            case "", "1", "require", "required", "yes": return .require
            case "2", "disable", "disabled", "no": return .disable
            default: console.warning("Choose 1 to require TLS or 2 to disable it.")
            }
        }
    }

    private func readPassword(confirm: Bool) throws -> Secret {
        while true {
            guard let value = console.securePrompt("PostgreSQL password:") else {
                throw DatabaseStepError.invalidValue("A PostgreSQL password is required.")
            }

            do {
                let password = try validatePassword(value)
                guard confirm else { return password }

                guard let confirmation = console.securePrompt("Confirm PostgreSQL password:") else {
                    throw DatabaseStepError.invalidValue("Password confirmation is required.")
                }
                guard value == confirmation else {
                    console.warning("The passwords do not match.")
                    continue
                }
                return password
            } catch let error as DatabaseStepError {
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
                throw DatabaseStepError.invalidValue("A \(field) is required.")
            }

            do {
                return try validator(input)
            } catch {
                console.warning(error.localizedDescription)
            }
        }
    }

    private func validateHost(_ input: String) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.count <= 253,
              !value.contains(where: { $0.isWhitespace || $0.isNewline }),
              !value.contains("://"),
              !value.contains("/") else {
            throw DatabaseStepError.invalidValue("Enter a PostgreSQL hostname or IP address without a scheme or path.")
        }
        return value
    }

    private func validateDatabaseName(_ input: String) throws -> String {
        try validatePostgreSQLName(input, label: "database name")
    }

    private func validateUsername(_ input: String) throws -> String {
        try validatePostgreSQLName(input, label: "database username")
    }

    private func validatePostgreSQLName(_ input: String, label: String) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...63).contains(value.count),
              value.utf8.allSatisfy({ byte in
                  (byte >= 65 && byte <= 90) ||
                  (byte >= 97 && byte <= 122) ||
                  (byte >= 48 && byte <= 57) ||
                  byte == 45 || byte == 95
              }) else {
            throw DatabaseStepError.invalidValue(
                "The \(label) must contain 1–63 ASCII letters, digits, hyphens, or underscores."
            )
        }
        return value
    }

    private func validatePassword(_ input: String) throws -> Secret {
        guard !input.isEmpty,
              input.count <= 256,
              !input.contains(where: { $0.isNewline }) else {
            throw DatabaseStepError.invalidValue(
                "The PostgreSQL password is required, cannot contain a newline, and cannot exceed 256 characters."
            )
        }
        return Secret(value: input)
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
            throw DatabaseStepError.dockerCommandFailed(
                action: "run a PostgreSQL setup command",
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
            throw DatabaseStepError.dockerCommandFailed(
                action: action,
                details: details(from: result)
            )
        }
        return result
    }

    private func details(from result: CommandResult) -> String? {
        if !result.standardError.isEmpty { return result.standardError }
        if !result.standardOutput.isEmpty { return result.standardOutput }
        return nil
    }
}
