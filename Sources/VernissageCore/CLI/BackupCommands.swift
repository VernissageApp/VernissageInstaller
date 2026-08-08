import ArgumentParser
import Foundation

public struct BackupCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "backup",
        abstract: "Create a PostgreSQL backup for an installer-managed database."
    )

    @OptionGroup
    var configurationOptions: ConfigurationOptions

    @Argument(
        help: "Optional destination file. Defaults to a unique file in the backups directory next to vernissage.yml."
    )
    var output: String?

    @Flag(name: .long, help: "Disable ANSI colors in terminal output.")
    var noColor = false

    public init() {}

    public mutating func run() throws {
        let console = Console.live(colorsEnabled: noColor == false)
        console.section("PostgreSQL backup")
        console.guidance(
            "This command backs up the installer-managed PostgreSQL database. S3 or MinIO objects and Vernissage configuration files are not included. The destination file is never overwritten."
        )

        do {
            let context = try configurationOptions.loadContext()
            console.pending("Creating a consistent PostgreSQL custom-format dump…")
            let result = try PostgreSQLBackupController.live().backup(
                context: context,
                outputPath: output,
                workingDirectory: URL(
                    fileURLWithPath: FileManager.default.currentDirectoryPath,
                    isDirectory: true
                )
            )
            console.completion(
                "PostgreSQL backup completed successfully.",
                values: [
                    ("Backup", result.archivePath),
                    ("Database", result.manifest.databaseName),
                    ("Size", formattedByteCount(result.archiveSize))
                ]
            )
            console.warning(
                "Keep this file in secure off-server storage. It can contain personal data, password hashes, access tokens, and other sensitive database records."
            )
        } catch {
            throw ValidationError(error.localizedDescription)
        }
    }
}

public struct RestoreCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "restore",
        abstract: "Restore an installer-managed PostgreSQL database from a Vernissage backup."
    )

    @OptionGroup
    var configurationOptions: ConfigurationOptions

    @Argument(help: "Vernissage PostgreSQL backup file to restore.")
    var backup: String

    @Flag(name: .long, help: "Disable ANSI colors in terminal output.")
    var noColor = false

    public init() {}

    public mutating func run() throws {
        let console = Console.live(colorsEnabled: noColor == false)
        console.section("PostgreSQL restore")
        console.guidance(
            "This command validates and restores an installer-managed PostgreSQL database. It does not create an automatic backup before restore. API and Jobs are stopped only for the final database switch and returned to their previous running state afterwards."
        )
        console.warning(
            "Restoring replaces the current Vernissage database contents with the selected backup. S3 or MinIO objects are not changed."
        )

        do {
            let context = try configurationOptions.loadContext()
            console.pending("Validating the backup and PostgreSQL compatibility…")
            let result = try PostgreSQLBackupController.live().restore(
                context: context,
                backupPath: backup,
                workingDirectory: URL(
                    fileURLWithPath: FileManager.default.currentDirectoryPath,
                    isDirectory: true
                ),
                confirm: {
                    console.line("")
                    console.warning(
                        "No automatic pre-restore backup will be created. Type RESTORE to continue."
                    )
                    return console.prompt("Confirmation:") == "RESTORE"
                }
            )
            console.completion(
                "PostgreSQL restore completed successfully.",
                values: [
                    ("Backup", result.archivePath),
                    ("Database", result.databaseName)
                ]
            )
            if let retainedDatabaseName = result.retainedDatabaseName {
                console.warning(
                    "The restore succeeded, but PostgreSQL could not remove the previous database '\(retainedDatabaseName)'. The active database is healthy; remove the retained database manually after verification to reclaim disk space."
                )
            }
        } catch {
            throw ValidationError(error.localizedDescription)
        }
    }
}

private func formattedByteCount(_ count: UInt64) -> String {
    ByteCountFormatter.string(
        fromByteCount: Int64(clamping: count),
        countStyle: .file
    )
}
