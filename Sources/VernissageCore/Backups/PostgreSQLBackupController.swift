import Foundation

struct PostgreSQLBackupResult: Equatable {
    let archivePath: String
    let archiveSize: UInt64
    let manifest: PostgreSQLBackupManifest
}

struct PostgreSQLRestoreResult: Equatable {
    let archivePath: String
    let databaseName: String
    let restartedServices: [String]
    let retainedDatabaseName: String?
}

enum PostgreSQLBackupControllerError: LocalizedError, Equatable {
    case missingConfiguration(String)
    case externalDatabaseUnsupported
    case postgresContainerNotRunning(String)
    case outputAlreadyExists(String)
    case backupNotFound(String)
    case fileOperationFailed(action: String, details: String)
    case dockerCommandFailed(action: String, details: String)
    case invalidPostgresVersion(String)
    case invalidDatabaseDump(String)
    case incompatibleBackup(field: String, expected: String, found: String)
    case restoreCancelled
    case restoreFailed(details: String, rollbackDetails: String?)

    var errorDescription: String? {
        switch self {
        case .missingConfiguration(let component):
            return "The Vernissage configuration is missing \(component)."
        case .externalDatabaseUnsupported:
            return "PostgreSQL backup and restore are currently supported only for a local database managed by the Vernissage installer. Use the backup or snapshot tools provided by the external PostgreSQL administrator."
        case .postgresContainerNotRunning(let container):
            return "The installer-managed PostgreSQL container '\(container)' is not running. Start it before using backup or restore."
        case .outputAlreadyExists(let path):
            return "The backup destination '\(path)' already exists. Choose another path; existing files are never overwritten."
        case .backupNotFound(let path):
            return "The backup file '\(path)' does not exist or is not a regular file."
        case .fileOperationFailed(let action, let details):
            return "The installer could not \(action). Details: \(details)"
        case .dockerCommandFailed(let action, let details):
            return "Docker could not \(action). Details: \(details)"
        case .invalidPostgresVersion(let value):
            return "PostgreSQL returned an invalid server version '\(value)'."
        case .invalidDatabaseDump(let details):
            return "The backup does not contain a valid PostgreSQL custom-format dump. Details: \(details)"
        case .incompatibleBackup(let field, let expected, let found):
            return "The backup is not compatible with this installation: \(field) must be '\(expected)', but the backup contains '\(found)'."
        case .restoreCancelled:
            return "Database restore was cancelled. No database was changed."
        case .restoreFailed(let details, let rollbackDetails):
            if let rollbackDetails {
                return "The database restore failed and automatic rollback was incomplete. Details: \(details). Rollback: \(rollbackDetails)"
            }
            return "The database restore failed. The original database remains active. Details: \(details)"
        }
    }
}

struct PostgreSQLBackupController {
    private struct Installation {
        let context: InstallationContext
        let server: ServerConfiguration
        let database: DatabaseConfiguration
        let resources: LocalPostgreSQLResources
        let services: ServerServicesConfiguration
    }

    private struct ApplicationState {
        let runningContainers: [String]
    }

    private let commandRunner: any CommandRunning
    private let archive: any PostgreSQLBackupArchiving
    private let fileManager: FileManager
    private let now: () -> Date
    private let makeToken: () -> String
    private let waitBeforeHealthRetry: () -> Void
    private let healthAttempts: Int

    init(
        commandRunner: any CommandRunning,
        archive: any PostgreSQLBackupArchiving = PostgreSQLBackupArchive(),
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        makeToken: @escaping () -> String = {
            String(
                UUID().uuidString
                    .lowercased()
                    .replacingOccurrences(of: "-", with: "")
                    .prefix(8)
            )
        },
        waitBeforeHealthRetry: @escaping () -> Void = {
            Thread.sleep(forTimeInterval: 1)
        },
        healthAttempts: Int = 30
    ) {
        self.commandRunner = commandRunner
        self.archive = archive
        self.fileManager = fileManager
        self.now = now
        self.makeToken = makeToken
        self.waitBeforeHealthRetry = waitBeforeHealthRetry
        self.healthAttempts = healthAttempts
    }

    static func live() -> PostgreSQLBackupController {
        PostgreSQLBackupController(commandRunner: ProcessCommandRunner())
    }

    func backup(
        context: InstallationContext,
        outputPath: String?,
        workingDirectory: URL
    ) throws -> PostgreSQLBackupResult {
        let installation = try localInstallation(from: context)
        try requirePostgreSQLRunning(installation.resources.containerName)

        let createdAt = now()
        let destination = try backupDestination(
            context: context,
            outputPath: outputPath,
            workingDirectory: workingDirectory,
            createdAt: createdAt
        )
        try requireDestinationAvailable(destination)
        let workDirectory = try makeWorkDirectory(
            parent: destination.deletingLastPathComponent(),
            purpose: "backup"
        )
        defer { try? fileManager.removeItem(at: workDirectory) }

        let databaseDump = workDirectory.appendingPathComponent("database.dump")
        let partialArchive = workDirectory.appendingPathComponent("archive.partial")
        let containerDump = "/tmp/vernissage-backup-\(safeToken()).dump"
        defer {
            removeContainerFile(
                containerDump,
                container: installation.resources.containerName
            )
        }

        let majorVersion = try postgresMajorVersion(installation)
        try createDatabaseDump(
            installation: installation,
            containerPath: containerDump
        )
        try copyFromContainer(
            container: installation.resources.containerName,
            containerPath: containerDump,
            destination: databaseDump
        )

        let dumpSize = try fileSize(databaseDump)
        guard dumpSize > 0 else {
            throw PostgreSQLBackupArchiveError.emptyDatabaseDump
        }
        let manifest = PostgreSQLBackupManifest(
            instanceIdentifier: context.instanceIdentifier,
            domain: installation.server.domain,
            createdAt: iso8601(createdAt),
            databaseName: installation.database.database,
            postgresMajorVersion: majorVersion,
            dumpSize: dumpSize
        )

        var archiveInstalled = false
        do {
            try archive.write(
                manifest: manifest,
                databaseDumpURL: databaseDump,
                archiveURL: partialArchive
            )
            try fileManager.moveItem(at: partialArchive, to: destination)
            archiveInstalled = true
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: destination.path
            )
        } catch {
            if archiveInstalled {
                try? fileManager.removeItem(at: destination)
            }
            throw PostgreSQLBackupControllerError.fileOperationFailed(
                action: "create the backup file at '\(destination.path)'",
                details: error.localizedDescription
            )
        }

        return PostgreSQLBackupResult(
            archivePath: destination.path,
            archiveSize: try fileSize(destination),
            manifest: manifest
        )
    }

    func restore(
        context: InstallationContext,
        backupPath: String,
        workingDirectory: URL,
        confirm: () -> Bool
    ) throws -> PostgreSQLRestoreResult {
        let installation = try localInstallation(from: context)
        try requirePostgreSQLRunning(installation.resources.containerName)
        let source = resolve(path: backupPath, relativeTo: workingDirectory)
        try requireBackupFile(source)

        let workDirectory = try makeWorkDirectory(
            parent: fileManager.temporaryDirectory,
            purpose: "restore"
        )
        defer { try? fileManager.removeItem(at: workDirectory) }
        let databaseDump = workDirectory.appendingPathComponent("database.dump")

        let manifest: PostgreSQLBackupManifest
        do {
            manifest = try archive.extract(
                archiveURL: source,
                databaseDumpURL: databaseDump
            )
        } catch {
            throw PostgreSQLBackupControllerError.invalidDatabaseDump(
                error.localizedDescription
            )
        }

        let currentMajorVersion = try postgresMajorVersion(installation)
        try validate(
            manifest: manifest,
            installation: installation,
            currentMajorVersion: currentMajorVersion
        )

        let token = safeToken()
        let containerDump = "/tmp/vernissage-restore-\(token).dump"
        defer {
            removeContainerFile(
                containerDump,
                container: installation.resources.containerName
            )
        }
        try copyToContainer(
            source: databaseDump,
            container: installation.resources.containerName,
            containerPath: containerDump
        )
        try validateDatabaseDump(
            installation: installation,
            containerPath: containerDump
        )

        let applicationState = try inspectApplicationState(installation.services)
        guard confirm() else {
            throw PostgreSQLBackupControllerError.restoreCancelled
        }

        let temporaryDatabase = "vernissage_restore_\(token)"
        let previousDatabase = "vernissage_previous_\(token)"
        try createDatabase(
            temporaryDatabase,
            owner: installation.database.username,
            installation: installation
        )

        do {
            try restoreDatabaseDump(
                installation: installation,
                containerPath: containerDump,
                databaseName: temporaryDatabase
            )
            try verifyRestoredDatabase(
                temporaryDatabase,
                installation: installation
            )
        } catch {
            dropDatabaseBestEffort(temporaryDatabase, installation: installation)
            throw PostgreSQLBackupControllerError.restoreFailed(
                details: error.localizedDescription,
                rollbackDetails: nil
            )
        }

        do {
            try stopContainers(applicationState.runningContainers)
            try terminateConnections(
                databaseName: installation.database.database,
                installation: installation
            )
            try renameDatabase(
                installation.database.database,
                to: previousDatabase,
                installation: installation
            )
        } catch {
            dropDatabaseBestEffort(temporaryDatabase, installation: installation)
            let restart = startContainersBestEffort(
                applicationState.runningContainers
            )
            throw PostgreSQLBackupControllerError.restoreFailed(
                details: error.localizedDescription,
                rollbackDetails: restart
            )
        }

        do {
            try renameDatabase(
                temporaryDatabase,
                to: installation.database.database,
                installation: installation
            )
        } catch {
            let rollback = restoreOriginalDatabaseName(
                previousDatabase: previousDatabase,
                originalDatabase: installation.database.database,
                temporaryDatabase: temporaryDatabase,
                installation: installation,
                applicationState: applicationState
            )
            throw PostgreSQLBackupControllerError.restoreFailed(
                details: error.localizedDescription,
                rollbackDetails: rollback
            )
        }

        do {
            try startContainers(applicationState.runningContainers)
            try waitForApplicationHealth(applicationState.runningContainers)
        } catch {
            let rollback = rollbackDatabaseSwap(
                currentDatabase: installation.database.database,
                previousDatabase: previousDatabase,
                failedDatabase: temporaryDatabase,
                installation: installation,
                applicationState: applicationState
            )
            throw PostgreSQLBackupControllerError.restoreFailed(
                details: error.localizedDescription,
                rollbackDetails: rollback
            )
        }

        let retainedDatabase: String?
        do {
            try dropDatabase(previousDatabase, installation: installation)
            retainedDatabase = nil
        } catch {
            retainedDatabase = previousDatabase
        }

        return PostgreSQLRestoreResult(
            archivePath: source.path,
            databaseName: installation.database.database,
            restartedServices: applicationState.runningContainers,
            retainedDatabaseName: retainedDatabase
        )
    }

    private func restoreOriginalDatabaseName(
        previousDatabase: String,
        originalDatabase: String,
        temporaryDatabase: String,
        installation: Installation,
        applicationState: ApplicationState
    ) -> String? {
        var failures: [String] = []
        do {
            try renameDatabase(
                previousDatabase,
                to: originalDatabase,
                installation: installation
            )
        } catch {
            failures.append("restore original database name: \(error.localizedDescription)")
        }
        if let failure = startContainersBestEffort(applicationState.runningContainers) {
            failures.append("restart original services: \(failure)")
        }
        dropDatabaseBestEffort(temporaryDatabase, installation: installation)
        return failures.isEmpty ? nil : failures.joined(separator: "; ")
    }

    private func localInstallation(
        from context: InstallationContext
    ) throws -> Installation {
        guard let server = context.server else {
            throw PostgreSQLBackupControllerError.missingConfiguration(
                "server and domain settings"
            )
        }
        guard let database = context.database else {
            throw PostgreSQLBackupControllerError.missingConfiguration(
                "PostgreSQL settings"
            )
        }
        guard database.mode == .localContainer,
              let resources = database.localResources else {
            throw PostgreSQLBackupControllerError.externalDatabaseUnsupported
        }
        guard let services = context.serverServices else {
            throw PostgreSQLBackupControllerError.missingConfiguration(
                "API and Jobs settings"
            )
        }
        return Installation(
            context: context,
            server: server,
            database: database,
            resources: resources,
            services: services
        )
    }

    private func requirePostgreSQLRunning(_ container: String) throws {
        let result = try runDocker(
            ["container", "inspect", "--format", "{{.State.Running}}", container],
            action: "inspect the PostgreSQL container"
        )
        guard result.standardOutput == "true" else {
            throw PostgreSQLBackupControllerError.postgresContainerNotRunning(
                container
            )
        }
    }

    private func postgresMajorVersion(_ installation: Installation) throws -> Int {
        let result = try runPostgreSQL(
            installation: installation,
            databaseName: "postgres",
            arguments: [
                "--tuples-only", "--no-align",
                "--command", "SHOW server_version_num;"
            ],
            action: "read the PostgreSQL server version"
        )
        let value = result.standardOutput.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard let version = Int(value), version > 0 else {
            throw PostgreSQLBackupControllerError.invalidPostgresVersion(value)
        }
        return version >= 100_000 ? version / 10_000 : version / 100
    }

    private func createDatabaseDump(
        installation: Installation,
        containerPath: String
    ) throws {
        _ = try runDocker(
            postgresExecPrefix(installation) + [
                "pg_dump",
                "--host", "127.0.0.1",
                "--port", String(installation.database.port),
                "--username", installation.database.username,
                "--dbname", installation.database.database,
                "--no-password",
                "--format", "custom",
                "--no-owner",
                "--no-acl",
                "--file", containerPath
            ],
            environment: postgresEnvironment(installation),
            action: "create the PostgreSQL database dump"
        )
    }

    private func validateDatabaseDump(
        installation: Installation,
        containerPath: String
    ) throws {
        do {
            _ = try runDocker(
                [
                    "container", "exec", installation.resources.containerName,
                    "pg_restore", "--list", containerPath
                ],
                action: "validate the PostgreSQL database dump"
            )
        } catch {
            throw PostgreSQLBackupControllerError.invalidDatabaseDump(
                error.localizedDescription
            )
        }
    }

    private func restoreDatabaseDump(
        installation: Installation,
        containerPath: String,
        databaseName: String
    ) throws {
        _ = try runDocker(
            postgresExecPrefix(installation) + [
                "pg_restore",
                "--host", "127.0.0.1",
                "--port", String(installation.database.port),
                "--username", installation.database.username,
                "--dbname", databaseName,
                "--no-password",
                "--exit-on-error",
                "--single-transaction",
                "--no-owner",
                "--no-acl",
                containerPath
            ],
            environment: postgresEnvironment(installation),
            action: "restore the PostgreSQL dump into a temporary database"
        )
    }

    private func createDatabase(
        _ databaseName: String,
        owner: String,
        installation: Installation
    ) throws {
        try executeMaintenanceSQL(
            "CREATE DATABASE \(sqlIdentifier(databaseName)) OWNER \(sqlIdentifier(owner)) TEMPLATE template0;",
            action: "create the temporary restore database",
            installation: installation
        )
    }

    private func verifyRestoredDatabase(
        _ databaseName: String,
        installation: Installation
    ) throws {
        let result = try runPostgreSQL(
            installation: installation,
            databaseName: databaseName,
            arguments: [
                "--tuples-only",
                "--no-align",
                "--command",
                "SELECT CASE WHEN to_regclass('\"Users\"') IS NOT NULL THEN 1 ELSE 0 END;"
            ],
            action: "verify the restored Vernissage database"
        )
        guard result.standardOutput == "1" else {
            throw PostgreSQLBackupControllerError.invalidDatabaseDump(
                "The restored database does not contain the Vernissage Users table."
            )
        }
    }

    private func dropDatabase(
        _ databaseName: String,
        installation: Installation
    ) throws {
        try executeMaintenanceSQL(
            "DROP DATABASE IF EXISTS \(sqlIdentifier(databaseName)) WITH (FORCE);",
            action: "remove the temporary PostgreSQL database",
            installation: installation
        )
    }

    private func renameDatabase(
        _ databaseName: String,
        to newName: String,
        installation: Installation
    ) throws {
        try executeMaintenanceSQL(
            "ALTER DATABASE \(sqlIdentifier(databaseName)) RENAME TO \(sqlIdentifier(newName));",
            action: "switch the restored PostgreSQL database",
            installation: installation
        )
    }

    private func terminateConnections(
        databaseName: String,
        installation: Installation
    ) throws {
        try executeMaintenanceSQL(
            "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = \(sqlLiteral(databaseName)) AND pid <> pg_backend_pid();",
            action: "close active PostgreSQL connections before restore",
            installation: installation
        )
    }

    private func executeMaintenanceSQL(
        _ sql: String,
        action: String,
        installation: Installation
    ) throws {
        _ = try runPostgreSQL(
            installation: installation,
            databaseName: "postgres",
            arguments: ["--command", sql],
            action: action
        )
    }

    private func runPostgreSQL(
        installation: Installation,
        databaseName: String,
        arguments: [String],
        action: String
    ) throws -> CommandResult {
        try runDocker(
            postgresExecPrefix(installation) + [
                "psql",
                "--host", "127.0.0.1",
                "--port", String(installation.database.port),
                "--username", installation.database.username,
                "--dbname", databaseName,
                "--no-password",
                "--set", "ON_ERROR_STOP=1"
            ] + arguments,
            environment: postgresEnvironment(installation),
            action: action
        )
    }

    private func postgresExecPrefix(_ installation: Installation) -> [String] {
        [
            "container", "exec",
            "--env", "PGPASSWORD",
            "--env", "PGSSLMODE",
            installation.resources.containerName
        ]
    }

    private func postgresEnvironment(
        _ installation: Installation
    ) -> [String: String] {
        [
            "PGPASSWORD": installation.database.password.value,
            "PGSSLMODE": "disable"
        ]
    }

    private func inspectApplicationState(
        _ services: ServerServicesConfiguration
    ) throws -> ApplicationState {
        let containers = [
            services.apiContainerName,
            services.jobsContainerName
        ]
        let result = try runDocker(
            ["container", "inspect", "--format", "{{.State.Running}}"] + containers,
            action: "inspect the API and Jobs containers"
        )
        let states = result.standardOutput
            .split(whereSeparator: \Character.isNewline)
            .map(String.init)
        guard states.count == containers.count,
              states.allSatisfy({ $0 == "true" || $0 == "false" }) else {
            throw PostgreSQLBackupControllerError.dockerCommandFailed(
                action: "read the API and Jobs container states",
                details: "Docker returned '\(result.standardOutput)'."
            )
        }
        return ApplicationState(
            runningContainers: zip(containers, states).compactMap {
                $0.1 == "true" ? $0.0 : nil
            }
        )
    }

    private func stopContainers(_ containers: [String]) throws {
        guard containers.isEmpty == false else { return }
        _ = try runDocker(
            ["container", "stop"] + containers,
            action: "stop API and Jobs before switching databases"
        )
    }

    private func startContainers(_ containers: [String]) throws {
        guard containers.isEmpty == false else { return }
        _ = try runDocker(
            ["container", "start"] + containers,
            action: "start API and Jobs after switching databases"
        )
    }

    private func waitForApplicationHealth(_ containers: [String]) throws {
        for container in containers {
            var lastDetails = "No health response was received."
            for attempt in 0..<max(1, healthAttempts) {
                let result = try? commandRunner.run(
                    "docker",
                    arguments: [
                        "container", "exec", container,
                        "curl", "--fail-with-body", "--silent", "--show-error",
                        "--max-time", "5",
                        "http://127.0.0.1:8080/api/v1/health"
                    ],
                    environment: [:],
                    standardInput: nil
                )
                if let result,
                   result.succeeded,
                   validServerHealth(result.standardOutput) {
                    break
                }
                if let result {
                    lastDetails = commandFailureDetails(result)
                }
                if attempt + 1 == max(1, healthAttempts) {
                    throw PostgreSQLBackupControllerError.dockerCommandFailed(
                        action: "verify \(container) after database restore",
                        details: lastDetails
                    )
                }
                waitBeforeHealthRetry()
            }
        }
    }

    private func validServerHealth(_ output: String) -> Bool {
        guard let health = try? JSONDecoder().decode(
            ServerHealth.self,
            from: Data(output.utf8)
        ) else {
            return false
        }
        return health.isDatabaseHealthy
            && health.isQueueHealthy
            && health.isStorageHealthy
    }

    private func rollbackDatabaseSwap(
        currentDatabase: String,
        previousDatabase: String,
        failedDatabase: String,
        installation: Installation,
        applicationState: ApplicationState
    ) -> String? {
        var failures: [String] = []
        if let failure = stopContainersBestEffort(applicationState.runningContainers) {
            failures.append("stop restored services: \(failure)")
        }

        var failedDatabaseWasMovedAside = false
        var failedDatabaseCanBeRemoved = false
        do {
            try terminateConnections(
                databaseName: currentDatabase,
                installation: installation
            )
            try renameDatabase(
                currentDatabase,
                to: failedDatabase,
                installation: installation
            )
            failedDatabaseWasMovedAside = true
        } catch {
            failures.append("move failed restored database aside: \(error.localizedDescription)")
        }

        if failedDatabaseWasMovedAside {
            do {
                try renameDatabase(
                    previousDatabase,
                    to: currentDatabase,
                    installation: installation
                )
                failedDatabaseCanBeRemoved = true
            } catch {
                failures.append("restore original database: \(error.localizedDescription)")
                do {
                    try renameDatabase(
                        failedDatabase,
                        to: currentDatabase,
                        installation: installation
                    )
                } catch {
                    failures.append(
                        "return restored database to its active name: \(error.localizedDescription)"
                    )
                }
            }
        }
        if let failure = startContainersBestEffort(applicationState.runningContainers) {
            failures.append("restart original services: \(failure)")
        }
        if failedDatabaseCanBeRemoved {
            dropDatabaseBestEffort(failedDatabase, installation: installation)
        }
        return failures.isEmpty ? nil : failures.joined(separator: "; ")
    }

    private func stopContainersBestEffort(_ containers: [String]) -> String? {
        do {
            try stopContainers(containers)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func startContainersBestEffort(_ containers: [String]) -> String? {
        do {
            try startContainers(containers)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func dropDatabaseBestEffort(
        _ databaseName: String,
        installation: Installation
    ) {
        try? dropDatabase(databaseName, installation: installation)
    }

    private func validate(
        manifest: PostgreSQLBackupManifest,
        installation: Installation,
        currentMajorVersion: Int
    ) throws {
        let comparisons = [
            (
                "instance identifier",
                installation.context.instanceIdentifier,
                manifest.instanceIdentifier
            ),
            ("domain", installation.server.domain, manifest.domain),
            (
                "database name",
                installation.database.database,
                manifest.databaseName
            ),
            (
                "PostgreSQL major version",
                String(currentMajorVersion),
                String(manifest.postgresMajorVersion)
            )
        ]
        for comparison in comparisons where comparison.1 != comparison.2 {
            throw PostgreSQLBackupControllerError.incompatibleBackup(
                field: comparison.0,
                expected: comparison.1,
                found: comparison.2
            )
        }
    }

    private func backupDestination(
        context: InstallationContext,
        outputPath: String?,
        workingDirectory: URL,
        createdAt: Date
    ) throws -> URL {
        if let outputPath, outputPath.isEmpty == false {
            let destination = resolve(
                path: outputPath,
                relativeTo: workingDirectory
            )
            try createDirectory(destination.deletingLastPathComponent())
            return destination
        }

        let configurationDirectory = context.summaryFilePath.map {
            URL(fileURLWithPath: $0).deletingLastPathComponent()
        } ?? workingDirectory
        let backupsDirectory = configurationDirectory.appendingPathComponent(
            "backups",
            isDirectory: true
        )
        try createDirectory(backupsDirectory)
        let fileName = "vernissage-\(context.instanceIdentifier)-postgresql-\(compactTimestamp(createdAt)).backup"
        return backupsDirectory.appendingPathComponent(fileName)
    }

    private func resolve(path: String, relativeTo directory: URL) -> URL {
        let expanded = NSString(string: path).expandingTildeInPath
        if NSString(string: expanded).isAbsolutePath {
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }
        return directory.appendingPathComponent(expanded).standardizedFileURL
    }

    private func requireDestinationAvailable(_ destination: URL) throws {
        guard fileManager.fileExists(atPath: destination.path) == false else {
            throw PostgreSQLBackupControllerError.outputAlreadyExists(
                destination.path
            )
        }
    }

    private func requireBackupFile(_ source: URL) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: source.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue == false else {
            throw PostgreSQLBackupControllerError.backupNotFound(source.path)
        }
    }

    private func createDirectory(_ directory: URL) throws {
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw PostgreSQLBackupControllerError.fileOperationFailed(
                action: "create the directory '\(directory.path)'",
                details: error.localizedDescription
            )
        }
    }

    private func makeWorkDirectory(
        parent: URL,
        purpose: String
    ) throws -> URL {
        let directory = parent.appendingPathComponent(
            ".vernissage-\(purpose)-\(safeToken())",
            isDirectory: true
        )
        guard fileManager.fileExists(atPath: directory.path) == false else {
            throw PostgreSQLBackupControllerError.fileOperationFailed(
                action: "create a temporary \(purpose) directory",
                details: "The path '\(directory.path)' already exists."
            )
        }
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw PostgreSQLBackupControllerError.fileOperationFailed(
                action: "create a temporary \(purpose) directory",
                details: error.localizedDescription
            )
        }
        return directory
    }

    private func copyFromContainer(
        container: String,
        containerPath: String,
        destination: URL
    ) throws {
        _ = try runDocker(
            ["container", "cp", "\(container):\(containerPath)", destination.path],
            action: "copy the PostgreSQL dump from the container"
        )
    }

    private func copyToContainer(
        source: URL,
        container: String,
        containerPath: String
    ) throws {
        _ = try runDocker(
            ["container", "cp", source.path, "\(container):\(containerPath)"],
            action: "copy the PostgreSQL dump into the container"
        )
    }

    private func removeContainerFile(_ path: String, container: String) {
        _ = try? commandRunner.run(
            "docker",
            arguments: ["container", "exec", container, "rm", "-f", path],
            environment: [:],
            standardInput: nil
        )
    }

    private func runDocker(
        _ arguments: [String],
        environment: [String: String] = [:],
        action: String
    ) throws -> CommandResult {
        let result: CommandResult
        do {
            result = try commandRunner.run(
                "docker",
                arguments: arguments,
                environment: environment,
                standardInput: nil
            )
        } catch {
            throw PostgreSQLBackupControllerError.dockerCommandFailed(
                action: action,
                details: error.localizedDescription
            )
        }
        guard result.succeeded else {
            throw PostgreSQLBackupControllerError.dockerCommandFailed(
                action: action,
                details: commandFailureDetails(result)
            )
        }
        return result
    }

    private func commandFailureDetails(_ result: CommandResult) -> String {
        if result.standardError.isEmpty == false {
            return result.standardError
        }
        if result.standardOutput.isEmpty == false {
            return result.standardOutput
        }
        return "docker exited with code \(result.exitCode)"
    }

    private func fileSize(_ url: URL) throws -> UInt64 {
        do {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            guard let size = attributes[.size] as? NSNumber else {
                throw PostgreSQLBackupControllerError.fileOperationFailed(
                    action: "read the size of '\(url.path)'",
                    details: "The file size is unavailable."
                )
            }
            return size.uint64Value
        } catch let error as PostgreSQLBackupControllerError {
            throw error
        } catch {
            throw PostgreSQLBackupControllerError.fileOperationFailed(
                action: "read the size of '\(url.path)'",
                details: error.localizedDescription
            )
        }
    }

    private func safeToken() -> String {
        let token = makeToken().lowercased().filter {
            $0.isASCII && ($0.isLetter || $0.isNumber)
        }
        return String((token.isEmpty ? "temporary" : token).prefix(24))
    }

    private func compactTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmssSSS'Z'"
        return formatter.string(from: date)
    }

    private func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func sqlIdentifier(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private func sqlLiteral(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }
}
