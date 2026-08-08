import Foundation

struct PostgreSQLBackupManifest: Codable, Equatable {
    static let currentSchemaVersion = 1
    static let kind = "vernissage-postgresql"

    let schemaVersion: Int
    let backupKind: String
    let instanceIdentifier: String
    let domain: String
    let createdAt: String
    let databaseName: String
    let postgresMajorVersion: Int
    let dumpSize: UInt64

    init(
        instanceIdentifier: String,
        domain: String,
        createdAt: String,
        databaseName: String,
        postgresMajorVersion: Int,
        dumpSize: UInt64
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.backupKind = Self.kind
        self.instanceIdentifier = instanceIdentifier
        self.domain = domain
        self.createdAt = createdAt
        self.databaseName = databaseName
        self.postgresMajorVersion = postgresMajorVersion
        self.dumpSize = dumpSize
    }
}

enum PostgreSQLBackupArchiveError: LocalizedError, Equatable {
    case invalidHeader
    case invalidManifestLength
    case invalidManifest(String)
    case unsupportedSchemaVersion(Int)
    case unsupportedBackupKind(String)
    case emptyDatabaseDump
    case truncatedDatabaseDump(expected: UInt64, actual: UInt64)
    case unexpectedDatabaseDumpData(expected: UInt64, actual: UInt64)
    case fileOperationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidHeader:
            return "The file is not a Vernissage PostgreSQL backup."
        case .invalidManifestLength:
            return "The backup contains an invalid metadata length."
        case .invalidManifest(let details):
            return "The backup metadata is invalid. Details: \(details)"
        case .unsupportedSchemaVersion(let version):
            return "The backup uses unsupported schema version \(version)."
        case .unsupportedBackupKind(let kind):
            return "The backup contains unsupported data of kind '\(kind)'."
        case .emptyDatabaseDump:
            return "The PostgreSQL dump is empty."
        case .truncatedDatabaseDump(let expected, let actual):
            return "The PostgreSQL dump is incomplete: expected \(expected) bytes, found \(actual)."
        case .unexpectedDatabaseDumpData(let expected, let actual):
            return "The PostgreSQL dump has an unexpected size: expected \(expected) bytes, found \(actual)."
        case .fileOperationFailed(let details):
            return "The backup file could not be read or written. Details: \(details)"
        }
    }
}

protocol PostgreSQLBackupArchiving {
    func write(
        manifest: PostgreSQLBackupManifest,
        databaseDumpURL: URL,
        archiveURL: URL
    ) throws

    func extract(
        archiveURL: URL,
        databaseDumpURL: URL
    ) throws -> PostgreSQLBackupManifest
}

struct PostgreSQLBackupArchive: PostgreSQLBackupArchiving {
    private static let magic = Data("VERNISSAGE_POSTGRESQL_BACKUP_V1\n".utf8)
    private static let maximumManifestSize = 1_048_576
    private static let copyBufferSize = 1_048_576

    func write(
        manifest: PostgreSQLBackupManifest,
        databaseDumpURL: URL,
        archiveURL: URL
    ) throws {
        guard manifest.dumpSize > 0 else {
            throw PostgreSQLBackupArchiveError.emptyDatabaseDump
        }

        let manifestData: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            manifestData = try encoder.encode(manifest)
        } catch {
            throw PostgreSQLBackupArchiveError.invalidManifest(
                error.localizedDescription
            )
        }

        guard manifestData.isEmpty == false,
              manifestData.count <= Self.maximumManifestSize else {
            throw PostgreSQLBackupArchiveError.invalidManifestLength
        }

        do {
            guard FileManager.default.createFile(
                atPath: archiveURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw PostgreSQLBackupArchiveError.fileOperationFailed(
                    "The destination file could not be created."
                )
            }

            let archive = try FileHandle(forWritingTo: archiveURL)
            let dump = try FileHandle(forReadingFrom: databaseDumpURL)
            defer {
                try? archive.close()
                try? dump.close()
            }

            try archive.write(contentsOf: Self.magic)
            try archive.write(contentsOf: Data("\(manifestData.count)\n".utf8))
            try archive.write(contentsOf: manifestData)

            let copied = try copy(
                from: dump,
                to: archive,
                expectedSize: manifest.dumpSize
            )
            guard copied == manifest.dumpSize else {
                throw PostgreSQLBackupArchiveError.truncatedDatabaseDump(
                    expected: manifest.dumpSize,
                    actual: copied
                )
            }
            try archive.synchronize()
        } catch let error as PostgreSQLBackupArchiveError {
            try? FileManager.default.removeItem(at: archiveURL)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: archiveURL)
            throw PostgreSQLBackupArchiveError.fileOperationFailed(
                error.localizedDescription
            )
        }
    }

    func extract(
        archiveURL: URL,
        databaseDumpURL: URL
    ) throws -> PostgreSQLBackupManifest {
        do {
            let archive = try FileHandle(forReadingFrom: archiveURL)
            defer { try? archive.close() }

            let header = try readLine(from: archive, maximumSize: Self.magic.count)
            guard header == Self.magic.dropLast() else {
                throw PostgreSQLBackupArchiveError.invalidHeader
            }

            let lengthData = try readLine(from: archive, maximumSize: 32)
            guard let lengthText = String(data: lengthData, encoding: .utf8),
                  let manifestLength = Int(lengthText),
                  manifestLength > 0,
                  manifestLength <= Self.maximumManifestSize else {
                throw PostgreSQLBackupArchiveError.invalidManifestLength
            }

            guard let manifestData = try archive.read(upToCount: manifestLength),
                  manifestData.count == manifestLength else {
                throw PostgreSQLBackupArchiveError.invalidManifestLength
            }

            let manifest: PostgreSQLBackupManifest
            do {
                manifest = try JSONDecoder().decode(
                    PostgreSQLBackupManifest.self,
                    from: manifestData
                )
            } catch {
                throw PostgreSQLBackupArchiveError.invalidManifest(
                    error.localizedDescription
                )
            }
            try validate(manifest)

            guard FileManager.default.createFile(
                atPath: databaseDumpURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw PostgreSQLBackupArchiveError.fileOperationFailed(
                    "The temporary database dump could not be created."
                )
            }

            let dump = try FileHandle(forWritingTo: databaseDumpURL)
            defer { try? dump.close() }
            let copied = try copy(
                from: archive,
                to: dump,
                expectedSize: manifest.dumpSize
            )
            try dump.synchronize()

            if copied < manifest.dumpSize {
                throw PostgreSQLBackupArchiveError.truncatedDatabaseDump(
                    expected: manifest.dumpSize,
                    actual: copied
                )
            }
            if copied > manifest.dumpSize {
                throw PostgreSQLBackupArchiveError.unexpectedDatabaseDumpData(
                    expected: manifest.dumpSize,
                    actual: copied
                )
            }
            return manifest
        } catch let error as PostgreSQLBackupArchiveError {
            try? FileManager.default.removeItem(at: databaseDumpURL)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: databaseDumpURL)
            throw PostgreSQLBackupArchiveError.fileOperationFailed(
                error.localizedDescription
            )
        }
    }

    private func validate(_ manifest: PostgreSQLBackupManifest) throws {
        guard manifest.schemaVersion == PostgreSQLBackupManifest.currentSchemaVersion else {
            throw PostgreSQLBackupArchiveError.unsupportedSchemaVersion(
                manifest.schemaVersion
            )
        }
        guard manifest.backupKind == PostgreSQLBackupManifest.kind else {
            throw PostgreSQLBackupArchiveError.unsupportedBackupKind(
                manifest.backupKind
            )
        }
        guard manifest.dumpSize > 0 else {
            throw PostgreSQLBackupArchiveError.emptyDatabaseDump
        }
    }

    private func readLine(
        from handle: FileHandle,
        maximumSize: Int
    ) throws -> Data {
        var result = Data()
        while result.count <= maximumSize {
            guard let byte = try handle.read(upToCount: 1),
                  byte.isEmpty == false else {
                throw PostgreSQLBackupArchiveError.invalidHeader
            }
            if byte[byte.startIndex] == 0x0A {
                return result
            }
            result.append(byte)
        }
        throw PostgreSQLBackupArchiveError.invalidManifestLength
    }

    private func copy(
        from source: FileHandle,
        to destination: FileHandle,
        expectedSize: UInt64
    ) throws -> UInt64 {
        var copied: UInt64 = 0
        while let data = try source.read(upToCount: Self.copyBufferSize),
              data.isEmpty == false {
            try destination.write(contentsOf: data)
            copied += UInt64(data.count)
            if copied > expectedSize {
                return copied
            }
        }
        return copied
    }
}
