import Foundation
import Testing
@testable import VernissageCore

struct PostgreSQLBackupArchiveTests {
    @Test
    func `Backup archive preserves metadata and binary database dump`() throws {
        try withTemporaryDirectory { directory in
            let dumpURL = directory.appendingPathComponent("database.dump")
            let archiveURL = directory.appendingPathComponent("database.backup")
            let extractedURL = directory.appendingPathComponent("extracted.dump")
            let dump = Data([0x50, 0x47, 0x44, 0x4D, 0x50, 0x00, 0xFF, 0x42])
            try dump.write(to: dumpURL)
            let manifest = backupManifest(dumpSize: UInt64(dump.count))
            let archive = PostgreSQLBackupArchive()

            try archive.write(
                manifest: manifest,
                databaseDumpURL: dumpURL,
                archiveURL: archiveURL
            )
            let extractedManifest = try archive.extract(
                archiveURL: archiveURL,
                databaseDumpURL: extractedURL
            )

            #expect(extractedManifest == manifest)
            #expect(try Data(contentsOf: extractedURL) == dump)
            let permissions = try #require(
                FileManager.default.attributesOfItem(
                    atPath: archiveURL.path
                )[.posixPermissions] as? NSNumber
            )
            #expect(permissions.intValue & 0o777 == 0o600)
        }
    }

    @Test
    func `Truncated database payload is rejected`() throws {
        try withTemporaryDirectory { directory in
            let dumpURL = directory.appendingPathComponent("database.dump")
            let archiveURL = directory.appendingPathComponent("database.backup")
            let extractedURL = directory.appendingPathComponent("extracted.dump")
            let dump = Data("PGDMP-database-payload".utf8)
            try dump.write(to: dumpURL)
            let archive = PostgreSQLBackupArchive()
            try archive.write(
                manifest: backupManifest(dumpSize: UInt64(dump.count)),
                databaseDumpURL: dumpURL,
                archiveURL: archiveURL
            )
            let handle = try FileHandle(forWritingTo: archiveURL)
            let size = try handle.seekToEnd()
            try handle.truncate(atOffset: size - 4)
            try handle.close()

            let error = #expect(throws: PostgreSQLBackupArchiveError.self) {
                try archive.extract(
                    archiveURL: archiveURL,
                    databaseDumpURL: extractedURL
                )
            }

            guard case .truncatedDatabaseDump = error else {
                Issue.record("Expected a truncated database dump error.")
                return
            }
            #expect(FileManager.default.fileExists(atPath: extractedURL.path) == false)
        }
    }

    @Test
    func `File without Vernissage header is rejected`() throws {
        try withTemporaryDirectory { directory in
            let archiveURL = directory.appendingPathComponent("database.backup")
            let extractedURL = directory.appendingPathComponent("extracted.dump")
            try Data("not-a-vernissage-backup".utf8).write(to: archiveURL)

            #expect(throws: PostgreSQLBackupArchiveError.invalidHeader) {
                try PostgreSQLBackupArchive().extract(
                    archiveURL: archiveURL,
                    databaseDumpURL: extractedURL
                )
            }
        }
    }

    private func backupManifest(dumpSize: UInt64) -> PostgreSQLBackupManifest {
        PostgreSQLBackupManifest(
            instanceIdentifier: "abcdefgh",
            domain: "photos.example.com",
            createdAt: "2026-08-08T10:30:12.000Z",
            databaseName: "vernissage",
            postgresMajorVersion: 18,
            dumpSize: dumpSize
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
