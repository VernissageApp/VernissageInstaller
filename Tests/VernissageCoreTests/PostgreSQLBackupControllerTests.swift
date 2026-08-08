import Foundation
import Testing
@testable import VernissageCore

struct PostgreSQLBackupControllerTests {
    @Test
    func `Managed PostgreSQL backup is written beside installation configuration`() throws {
        try withTemporaryDirectory { directory in
            let context = managedContext(in: directory)
            let runner = BackupCommandRunner(
                results: [
                    .success("true"),
                    .success("180002"),
                    .success(),
                    .success(),
                    .success()
                ],
                onRun: writeFakeDumpForContainerCopy
            )
            let date = try #require(
                ISO8601DateFormatter().date(from: "2026-08-08T10:30:12Z")
            )

            let result = try controller(runner: runner, date: date).backup(
                context: context,
                outputPath: nil,
                workingDirectory: directory
            )

            #expect(result.archivePath.hasSuffix(
                "/backups/vernissage-abcdefgh-postgresql-20260808T103012000Z.backup"
            ))
            #expect(FileManager.default.fileExists(atPath: result.archivePath))
            #expect(result.archiveSize > result.manifest.dumpSize)
            #expect(result.manifest.postgresMajorVersion == 18)
            #expect(result.manifest.domain == "photos.example.com")
            #expect(runner.invocations.contains(where: {
                $0.arguments.contains("pg_dump")
                    && $0.environment["PGPASSWORD"] == "database-secret"
                    && $0.arguments.contains("database-secret") == false
            }))
        }
    }

    @Test
    func `Existing backup destination is never overwritten`() throws {
        try withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("existing.backup")
            try Data("keep-me".utf8).write(to: destination)
            let runner = BackupCommandRunner(results: [.success("true")])

            #expect(throws: PostgreSQLBackupControllerError.outputAlreadyExists(
                destination.path
            )) {
                try controller(runner: runner).backup(
                    context: managedContext(in: directory),
                    outputPath: destination.path,
                    workingDirectory: directory
                )
            }
            #expect(try Data(contentsOf: destination) == Data("keep-me".utf8))
            #expect(runner.invocations.count == 1)
        }
    }

    @Test
    func `External PostgreSQL is rejected before Docker is contacted`() throws {
        try withTemporaryDirectory { directory in
            let context = managedContext(in: directory)
            context.database = DatabaseConfiguration(
                mode: .existing,
                host: "postgres.example.com",
                port: 5432,
                database: "vernissage",
                username: "vernissage",
                password: Secret(value: "database-secret"),
                tlsMode: .require,
                localResources: nil
            )
            let runner = BackupCommandRunner(results: [])

            #expect(throws: PostgreSQLBackupControllerError.externalDatabaseUnsupported) {
                try controller(runner: runner).backup(
                    context: context,
                    outputPath: nil,
                    workingDirectory: directory
                )
            }
            #expect(runner.invocations.isEmpty)
        }
    }

    @Test
    func `Restore switches databases without creating a pre-restore backup`() throws {
        try withTemporaryDirectory { directory in
            let context = managedContext(in: directory)
            let backupURL = try makeBackup(in: directory)
            let healthy = healthJSON()
            let runner = BackupCommandRunner(results: [
                .success("true"),
                .success("180002"),
                .success(),
                .success("valid dump listing"),
                .success("true\ntrue"),
                .success(),
                .success(),
                .success("1"),
                .success(),
                .success(),
                .success(),
                .success(),
                .success(),
                .success(healthy),
                .success(healthy),
                .success(),
                .success()
            ])
            var confirmationRequested = false

            let result = try controller(runner: runner).restore(
                context: context,
                backupPath: backupURL.path,
                workingDirectory: directory,
                confirm: {
                    confirmationRequested = true
                    return true
                }
            )

            #expect(confirmationRequested)
            #expect(result.databaseName == "vernissage")
            #expect(result.restartedServices == [
                "vernissage-abcdefgh-api",
                "vernissage-abcdefgh-jobs"
            ])
            #expect(result.retainedDatabaseName == nil)
            #expect(runner.invocations.contains(where: {
                $0.arguments.contains("pg_restore")
                    && $0.arguments.contains("--single-transaction")
            }))
            #expect(runner.invocations.contains(where: {
                $0.arguments.contains("pg_dump")
            }) == false)
        }
    }

    @Test
    func `Cancelled restore leaves database and application containers unchanged`() throws {
        try withTemporaryDirectory { directory in
            let backupURL = try makeBackup(in: directory)
            let runner = BackupCommandRunner(results: [
                .success("true"),
                .success("180002"),
                .success(),
                .success("valid dump listing"),
                .success("true\nfalse"),
                .success()
            ])

            #expect(throws: PostgreSQLBackupControllerError.restoreCancelled) {
                try controller(runner: runner).restore(
                    context: managedContext(in: directory),
                    backupPath: backupURL.path,
                    workingDirectory: directory,
                    confirm: { false }
                )
            }
            #expect(runner.invocations.contains(where: {
                $0.arguments.contains("CREATE DATABASE")
                    || $0.arguments.contains("stop")
            }) == false)
        }
    }

    @Test
    func `PostgreSQL major version mismatch stops restore before container changes`() throws {
        try withTemporaryDirectory { directory in
            let backupURL = try makeBackup(in: directory, postgresMajorVersion: 17)
            let runner = BackupCommandRunner(results: [
                .success("true"),
                .success("180002")
            ])

            let error = #expect(throws: PostgreSQLBackupControllerError.self) {
                try controller(runner: runner).restore(
                    context: managedContext(in: directory),
                    backupPath: backupURL.path,
                    workingDirectory: directory,
                    confirm: { true }
                )
            }

            #expect(error == .incompatibleBackup(
                field: "PostgreSQL major version",
                expected: "18",
                found: "17"
            ))
            #expect(runner.invocations.count == 2)
        }
    }

    @Test
    func `Database dump without Vernissage tables is rejected before service stop`() throws {
        try withTemporaryDirectory { directory in
            let backupURL = try makeBackup(in: directory)
            let runner = BackupCommandRunner(results: [
                .success("true"),
                .success("180002"),
                .success(),
                .success("valid dump listing"),
                .success("true\ntrue"),
                .success(),
                .success(),
                .success("0"),
                .success(),
                .success()
            ])

            let error = #expect(throws: PostgreSQLBackupControllerError.self) {
                try controller(runner: runner).restore(
                    context: managedContext(in: directory),
                    backupPath: backupURL.path,
                    workingDirectory: directory,
                    confirm: { true }
                )
            }

            guard case .restoreFailed(let details, nil) = error else {
                Issue.record("Expected an invalid Vernissage dump failure.")
                return
            }
            #expect(details.contains("Users table"))
            #expect(runner.invocations.contains(where: {
                $0.arguments.starts(with: ["container", "stop"])
            }) == false)
            #expect(runner.invocations.contains(where: {
                $0.arguments.contains("pg_dump")
            }) == false)
        }
    }

    @Test
    func `Failed health check restores original database and services`() throws {
        try withTemporaryDirectory { directory in
            let backupURL = try makeBackup(in: directory)
            let runner = BackupCommandRunner(results: [
                .success("true"),
                .success("180002"),
                .success(),
                .success("valid dump listing"),
                .success("true\ntrue"),
                .success(),
                .success(),
                .success("1"),
                .success(),
                .success(),
                .success(),
                .success(),
                .success(),
                CommandResult(
                    exitCode: 1,
                    standardOutput: "",
                    standardError: "API unavailable"
                ),
                .success(),
                .success(),
                .success(),
                .success(),
                .success(),
                .success(),
                .success()
            ])

            let error = #expect(throws: PostgreSQLBackupControllerError.self) {
                try controller(runner: runner, healthAttempts: 1).restore(
                    context: managedContext(in: directory),
                    backupPath: backupURL.path,
                    workingDirectory: directory,
                    confirm: { true }
                )
            }

            guard case .restoreFailed(_, let rollbackDetails) = error else {
                Issue.record("Expected restore failure with rollback.")
                return
            }
            #expect(rollbackDetails == nil)
            #expect(runner.invocations.contains(where: {
                $0.arguments.contains(where: {
                    $0.contains("vernissage_previous_")
                        && $0.contains("RENAME TO \"vernissage\"")
                })
            }))
            #expect(runner.invocations.contains(where: {
                $0.arguments.contains("pg_dump")
            }) == false)
        }
    }

    @Test
    func `Backup and restore commands parse configuration paths and operands`() throws {
        let backupParsed = try VernissageCommand.parseAsRoot([
            "--config", "/srv/vernissage/vernissage.yml",
            "backup", "/safe/database.backup", "--no-color"
        ])
        let backup = try #require(backupParsed as? BackupCommand)
        #expect(backup.output == "/safe/database.backup")
        #expect(backup.configurationOptions.configPath == "/srv/vernissage/vernissage.yml")
        #expect(backup.noColor)

        let restoreParsed = try VernissageCommand.parseAsRoot([
            "restore", "database.backup",
            "--config", "/srv/vernissage/vernissage.yml"
        ])
        let restore = try #require(restoreParsed as? RestoreCommand)
        #expect(restore.backup == "database.backup")
        #expect(restore.configurationOptions.configPath == "/srv/vernissage/vernissage.yml")
    }

    private func controller(
        runner: BackupCommandRunner,
        date: Date = Date(timeIntervalSince1970: 1_786_182_612),
        healthAttempts: Int = 1
    ) -> PostgreSQLBackupController {
        let token = "test" + UUID().uuidString
            .lowercased()
            .replacingOccurrences(of: "-", with: "")
        return PostgreSQLBackupController(
            commandRunner: runner,
            now: { date },
            makeToken: { token },
            waitBeforeHealthRetry: {},
            healthAttempts: healthAttempts
        )
    }

    private func managedContext(in directory: URL) -> InstallationContext {
        let context = InstallationContext(instanceIdentifier: "abcdefgh")
        context.summaryFilePath = directory
            .appendingPathComponent("vernissage.yml").path
        context.server = ServerConfiguration(domain: "photos.example.com")
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
        context.serverServices = ServerServicesConfiguration(
            image: "mczachurski/vernissage-server:latest",
            networkName: "vernissage-abcdefgh-network",
            apiContainerName: "vernissage-abcdefgh-api",
            jobsContainerName: "vernissage-abcdefgh-jobs",
            apiNetworkAlias: "api",
            jobsNetworkAlias: "jobs",
            baseAddress: "https://photos.example.com",
            apiHealth: nil,
            jobsHealth: nil,
            databaseTables: nil
        )
        return context
    }

    private func makeBackup(
        in directory: URL,
        postgresMajorVersion: Int = 18
    ) throws -> URL {
        let dump = Data("PGDMP-test-database-dump".utf8)
        let dumpURL = directory.appendingPathComponent(UUID().uuidString)
        let backupURL = directory.appendingPathComponent("database.backup")
        try dump.write(to: dumpURL)
        try PostgreSQLBackupArchive().write(
            manifest: PostgreSQLBackupManifest(
                instanceIdentifier: "abcdefgh",
                domain: "photos.example.com",
                createdAt: "2026-08-08T10:30:12.000Z",
                databaseName: "vernissage",
                postgresMajorVersion: postgresMajorVersion,
                dumpSize: UInt64(dump.count)
            ),
            databaseDumpURL: dumpURL,
            archiveURL: backupURL
        )
        try FileManager.default.removeItem(at: dumpURL)
        return backupURL
    }

    private func healthJSON() -> String {
        """
        {"isDatabaseHealthy":true,"isQueueHealthy":true,"isWebPushHealthy":false,"isStorageHealthy":true}
        """
    }

    private func writeFakeDumpForContainerCopy(
        _ invocation: BackupDockerInvocation
    ) throws {
        guard invocation.arguments.starts(with: ["container", "cp"]),
              invocation.arguments[2].contains(":/tmp/vernissage-backup-") else {
            return
        }
        let destination = try #require(invocation.arguments.last)
        try Data("PGDMP-fake-database-dump".utf8).write(
            to: URL(fileURLWithPath: destination)
        )
    }

    private func withTemporaryDirectory(
        _ body: (URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}

private struct BackupDockerInvocation: Equatable {
    let executable: String
    let arguments: [String]
    let environment: [String: String]
    let standardInput: String?
}

private enum BackupCommandRunnerError: Error {
    case resultNotConfigured
}

private final class BackupCommandRunner: CommandRunning {
    private var results: [CommandResult]
    private let onRun: ((BackupDockerInvocation) throws -> Void)?
    private(set) var invocations: [BackupDockerInvocation] = []

    init(
        results: [CommandResult],
        onRun: ((BackupDockerInvocation) throws -> Void)? = nil
    ) {
        self.results = results
        self.onRun = onRun
    }

    func run(
        _ executable: String,
        arguments: [String],
        environment: [String: String],
        standardInput: String?
    ) throws -> CommandResult {
        let invocation = BackupDockerInvocation(
            executable: executable,
            arguments: arguments,
            environment: environment,
            standardInput: standardInput
        )
        invocations.append(invocation)
        try onRun?(invocation)
        guard results.isEmpty == false else {
            throw BackupCommandRunnerError.resultNotConfigured
        }
        return results.removeFirst()
    }
}

private extension CommandResult {
    static func success(_ output: String = "") -> CommandResult {
        CommandResult(
            exitCode: 0,
            standardOutput: output,
            standardError: ""
        )
    }
}
