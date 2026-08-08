import Foundation
import Yams

enum InstallationConfigurationLoadingError: LocalizedError, Equatable {
    case configurationNotFound(searchedPaths: [String])
    case cannotReadFile(path: String, details: String)
    case invalidConfiguration(path: String, details: String)
    case unsupportedSchemaVersion(path: String, found: Int, supported: Int)
    case invalidSecretsReference(String)
    case invalidValue(field: String, value: String)

    var errorDescription: String? {
        switch self {
        case .configurationNotFound(let searchedPaths):
            let paths = searchedPaths.map { "  - \($0)" }.joined(separator: "\n")
            return """
            No Vernissage configuration file was found. Checked:
            \(paths)
            Pass --config /path/vernissage.yml or set VERNISSAGE_CONFIG.
            """
        case .cannotReadFile(let path, let details):
            return "The Vernissage configuration file at '\(path)' could not be read. Details: \(details)"
        case .invalidConfiguration(let path, let details):
            return "The Vernissage configuration file at '\(path)' is invalid. Details: \(details)"
        case .unsupportedSchemaVersion(let path, let found, let supported):
            return "The configuration file at '\(path)' uses schema version \(found), but this vernissagectl supports version \(supported)."
        case .invalidSecretsReference(let reference):
            return "The secretsFile value '\(reference)' must be a relative path inside the directory containing vernissage.yml."
        case .invalidValue(let field, let value):
            return "The Vernissage configuration contains an unsupported value '\(value)' for '\(field)'."
        }
    }
}

struct InstallationConfigurationLocator {
    static let environmentVariable = "VERNISSAGE_CONFIG"

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func locate(
        explicitPath: String?,
        environment: [String: String],
        workingDirectory: URL
    ) throws -> URL {
        if let explicitPath, explicitPath.isEmpty == false {
            return try requireConfiguration(
                at: resolve(explicitPath, relativeTo: workingDirectory)
            )
        }

        if let environmentPath = environment[Self.environmentVariable],
           environmentPath.isEmpty == false {
            return try requireConfiguration(
                at: resolve(environmentPath, relativeTo: workingDirectory)
            )
        }

        let candidates = [
            workingDirectory.appendingPathComponent(InstallationSummaryStep.summaryFileName),
            workingDirectory
                .appendingPathComponent("vernissage", isDirectory: true)
                .appendingPathComponent(InstallationSummaryStep.summaryFileName)
        ].map(\.standardizedFileURL)

        for candidate in candidates where isRegularFile(candidate) {
            return candidate
        }

        throw InstallationConfigurationLoadingError.configurationNotFound(
            searchedPaths: candidates.map(\.path)
        )
    }

    private func resolve(_ path: String, relativeTo workingDirectory: URL) -> URL {
        let expandedPath = NSString(string: path).expandingTildeInPath
        let url: URL
        if NSString(string: expandedPath).isAbsolutePath {
            url = URL(fileURLWithPath: expandedPath)
        } else {
            url = workingDirectory.appendingPathComponent(expandedPath)
        }
        return url.standardizedFileURL
    }

    private func requireConfiguration(at url: URL) throws -> URL {
        guard isRegularFile(url) else {
            throw InstallationConfigurationLoadingError.configurationNotFound(
                searchedPaths: [url.path]
            )
        }
        return url
    }

    private func isRegularFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue == false
    }
}

struct InstallationConfigurationLoader {
    static let supportedSchemaVersion = InstallationSummaryStep.schemaVersion

    private let locator: InstallationConfigurationLocator
    private let fileManager: FileManager
    private let environment: () -> [String: String]
    private let workingDirectory: () -> URL

    init(
        locator: InstallationConfigurationLocator = InstallationConfigurationLocator(),
        fileManager: FileManager = .default,
        environment: @escaping () -> [String: String] = { ProcessInfo.processInfo.environment },
        workingDirectory: @escaping () -> URL = {
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        }
    ) {
        self.locator = locator
        self.fileManager = fileManager
        self.environment = environment
        self.workingDirectory = workingDirectory
    }

    func load(configPath: String? = nil) throws -> InstallationContext {
        let configurationURL = try locator.locate(
            explicitPath: configPath,
            environment: environment(),
            workingDirectory: workingDirectory()
        )
        let document: InstallationConfigurationDocument = try decode(
            InstallationConfigurationDocument.self,
            from: configurationURL
        )
        try requireSupportedSchema(document.schemaVersion, at: configurationURL)

        let secretsURL = try resolveSecretsFile(
            document.secretsFile,
            relativeTo: configurationURL
        )
        let secrets: InstallationSecretsDocument = try decode(
            InstallationSecretsDocument.self,
            from: secretsURL
        )
        try requireSupportedSchema(secrets.schemaVersion, at: secretsURL)

        return try makeContext(
            document: document,
            secrets: secrets,
            configurationURL: configurationURL,
            secretsURL: secretsURL
        )
    }

    private func decode<Value: Decodable>(
        _ type: Value.Type,
        from url: URL
    ) throws -> Value {
        let contents: String
        do {
            contents = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw InstallationConfigurationLoadingError.cannotReadFile(
                path: url.path,
                details: error.localizedDescription
            )
        }

        do {
            return try YAMLDecoder().decode(type, from: contents)
        } catch {
            throw InstallationConfigurationLoadingError.invalidConfiguration(
                path: url.path,
                details: error.localizedDescription
            )
        }
    }

    private func requireSupportedSchema(_ version: Int, at url: URL) throws {
        guard version == Self.supportedSchemaVersion else {
            throw InstallationConfigurationLoadingError.unsupportedSchemaVersion(
                path: url.path,
                found: version,
                supported: Self.supportedSchemaVersion
            )
        }
    }

    private func resolveSecretsFile(
        _ reference: String,
        relativeTo configurationURL: URL
    ) throws -> URL {
        guard reference.isEmpty == false,
              NSString(string: reference).isAbsolutePath == false else {
            throw InstallationConfigurationLoadingError.invalidSecretsReference(reference)
        }

        let directory = configurationURL.deletingLastPathComponent().standardizedFileURL
        let url = directory.appendingPathComponent(reference).standardizedFileURL
        let directoryPrefix = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        guard url.path.hasPrefix(directoryPrefix) else {
            throw InstallationConfigurationLoadingError.invalidSecretsReference(reference)
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue == false else {
            throw InstallationConfigurationLoadingError.configurationNotFound(
                searchedPaths: [url.path]
            )
        }
        return url
    }

    private func makeContext(
        document: InstallationConfigurationDocument,
        secrets: InstallationSecretsDocument,
        configurationURL: URL,
        secretsURL: URL
    ) throws -> InstallationContext {
        let databaseMode = try databaseMode(document.postgresql.mode)
        let redisMode = try redisMode(document.redis.mode)
        let storageProvider = try storageProvider(document.storage.provider)
        let httpsMode = try httpsMode(document.publicAccess.httpsMode)
        let redisURL = try makeRedisURL(document.redis, password: secrets.redis.password)

        guard InstallationIdentity.isValid(document.instance.id) else {
            throw InstallationConfigurationLoadingError.invalidValue(
                field: "instance.id",
                value: document.instance.id
            )
        }

        let context = InstallationContext(instanceIdentifier: document.instance.id)
        context.docker = DockerEnvironment(
            clientVersion: document.docker.clientVersion,
            serverVersion: document.docker.serverVersion,
            composeVersion: document.docker.composeVersion
        )
        context.server = ServerConfiguration(domain: document.server.domain)
        context.administrator = AdministratorConfiguration(
            userId: document.administrator.userId,
            name: document.administrator.name,
            email: document.administrator.email,
            username: document.administrator.username,
            password: nil,
            accessToken: nil
        )
        context.database = DatabaseConfiguration(
            mode: databaseMode,
            host: document.postgresql.host,
            port: document.postgresql.port,
            database: document.postgresql.database,
            username: document.postgresql.username,
            password: Secret(value: secrets.postgresql.password),
            tlsMode: document.postgresql.tlsMode,
            localResources: document.postgresql.localContainer.map {
                LocalPostgreSQLResources(
                    image: $0.image,
                    containerName: $0.containerName,
                    volumeName: $0.volumeName,
                    networkName: $0.networkName
                )
            }
        )
        context.redis = RedisConfiguration(
            mode: redisMode,
            url: Secret(value: redisURL),
            username: document.redis.username,
            host: document.redis.host,
            port: document.redis.port,
            database: document.redis.database,
            password: secrets.redis.password.map(Secret.init(value:)),
            usesTLS: document.redis.usesTLS,
            localResources: document.redis.localContainer.map {
                LocalRedisResources(
                    image: $0.image,
                    containerName: $0.containerName,
                    volumeName: $0.volumeName,
                    networkName: $0.networkName
                )
            }
        )
        context.storage = StorageConfiguration(
            provider: storageProvider,
            address: document.storage.address,
            region: document.storage.region,
            bucket: document.storage.bucket,
            accessKeyId: document.storage.accessKeyId,
            secretAccessKey: Secret(value: secrets.storage.secretAccessKey),
            http1OnlyMode: document.storage.http1OnlyMode,
            imagesURL: document.storage.imagesURL,
            localResources: document.storage.localContainer.map {
                LocalMinIOResources(
                    image: $0.image,
                    containerName: $0.containerName,
                    volumeName: $0.volumeName,
                    networkName: $0.networkName
                )
            }
        )
        context.serverServices = ServerServicesConfiguration(
            image: document.apiAndJobs.image,
            networkName: document.apiAndJobs.networkName,
            apiContainerName: document.apiAndJobs.apiContainerName,
            jobsContainerName: document.apiAndJobs.jobsContainerName,
            apiNetworkAlias: document.apiAndJobs.apiNetworkAlias,
            jobsNetworkAlias: document.apiAndJobs.jobsNetworkAlias,
            baseAddress: document.apiAndJobs.baseAddress,
            apiHealth: nil,
            jobsHealth: nil,
            databaseTables: nil
        )
        context.web = WebConfiguration(
            image: document.web.image,
            containerName: document.web.containerName,
            networkName: document.web.networkName,
            networkAlias: document.web.networkAlias,
            allowedHosts: document.web.allowedHosts,
            cspImageSource: document.web.cspImageSource
        )
        context.push = PushConfiguration(
            image: document.push.image,
            containerName: document.push.containerName,
            networkName: document.push.networkName,
            networkAlias: document.push.networkAlias,
            endpoint: document.push.endpoint,
            secretKey: Secret(value: secrets.push.secretKey),
            isEnabled: document.push.isEnabled
        )
        context.publicAccess = PublicAccessConfiguration(httpsMode: httpsMode)
        context.proxy = ProxyConfiguration(
            image: document.proxy.image,
            containerName: document.proxy.containerName,
            networkName: document.proxy.networkName,
            networkAlias: document.proxy.networkAlias,
            hostPort: document.proxy.hostPort,
            containerPort: document.proxy.containerPort,
            apiUpstream: document.proxy.apiUpstream,
            webUpstream: document.proxy.webUpstream,
            publicHTTPAddress: document.proxy.publicHTTPAddress,
            buildContextPath: document.proxy.buildContextPath
        )
        context.caddy = document.caddy.map {
            CaddyConfiguration(
                image: $0.image,
                containerName: $0.containerName,
                networkName: $0.networkName,
                networkAlias: $0.networkAlias,
                dataVolumeName: $0.dataVolumeName,
                configVolumeName: $0.configVolumeName,
                caddyfilePath: $0.caddyfilePath,
                publicHTTPSAddress: $0.publicHTTPSAddress,
                localRootCertificatePath: $0.localRootCertificatePath
            )
        }
        context.summaryFilePath = configurationURL.path
        context.secretsFilePath = secretsURL.path
        return context
    }

    private func makeRedisURL(
        _ redis: InstallationConfigurationDocument.Redis,
        password: String?
    ) throws -> String {
        var components = URLComponents()
        components.scheme = redis.usesTLS ? "rediss" : "redis"
        components.host = redis.host
        components.port = Int(redis.port)
        components.user = redis.username
        components.password = password
        components.path = "/\(redis.database)"
        guard let value = components.string else {
            throw InstallationConfigurationLoadingError.invalidValue(
                field: "redis",
                value: "connection parameters"
            )
        }
        return value
    }

    private func databaseMode(_ value: String) throws -> DatabaseInstallationMode {
        switch value {
        case "existing": .existing
        case "localContainer": .localContainer
        default: throw InstallationConfigurationLoadingError.invalidValue(field: "postgresql.mode", value: value)
        }
    }

    private func redisMode(_ value: String) throws -> RedisInstallationMode {
        switch value {
        case "existing": .existing
        case "localContainer": .localContainer
        default: throw InstallationConfigurationLoadingError.invalidValue(field: "redis.mode", value: value)
        }
    }

    private func storageProvider(_ value: String) throws -> StorageProvider {
        switch value {
        case "awsS3": .awsS3
        case "compatible": .compatible
        case "localMinIO": .localMinIO
        default: throw InstallationConfigurationLoadingError.invalidValue(field: "storage.provider", value: value)
        }
    }

    private func httpsMode(_ value: String) throws -> HTTPSMode {
        switch value {
        case "development": .development
        case "production": .production
        case "manual": .manual
        default: throw InstallationConfigurationLoadingError.invalidValue(field: "publicAccess.httpsMode", value: value)
        }
    }
}

private struct InstallationConfigurationDocument: Decodable {
    let schemaVersion: Int
    let secretsFile: String
    let instance: Instance
    let installer: Installer
    let docker: Docker
    let server: Server
    let administrator: Administrator
    let postgresql: PostgreSQL
    let redis: Redis
    let storage: Storage
    let apiAndJobs: APIAndJobs
    let web: Web
    let push: Push
    let publicAccess: PublicAccess
    let proxy: Proxy
    let caddy: Caddy?

    struct Instance: Decodable {
        let id: String
    }

    struct Installer: Decodable {
        let version: String
        let installedAt: String
    }

    struct Docker: Decodable {
        let clientVersion: String
        let serverVersion: String
        let composeVersion: String
    }

    struct Server: Decodable {
        let domain: String
        let publicAddress: String?
    }

    struct Administrator: Decodable {
        let userId: Int64
        let name: String?
        let email: String
        let username: String
    }

    struct PostgreSQL: Decodable {
        let mode: String
        let host: String
        let port: UInt16
        let database: String
        let username: String
        let tlsMode: DatabaseTLSMode
        let localContainer: LocalContainer?
    }

    struct Redis: Decodable {
        let mode: String
        let username: String
        let host: String
        let port: UInt16
        let database: Int
        let usesTLS: Bool
        let localContainer: LocalContainer?
    }

    struct Storage: Decodable {
        let provider: String
        let address: String
        let region: String?
        let bucket: String
        let accessKeyId: String
        let http1OnlyMode: Bool
        let imagesURL: String?
        let localContainer: LocalContainer?
    }

    struct APIAndJobs: Decodable {
        let image: String
        let networkName: String
        let apiContainerName: String
        let apiNetworkAlias: String
        let jobsContainerName: String
        let jobsNetworkAlias: String
        let baseAddress: String
    }

    struct Web: Decodable {
        let image: String
        let containerName: String
        let networkName: String
        let networkAlias: String
        let allowedHosts: String
        let cspImageSource: String?
    }

    struct Push: Decodable {
        let image: String
        let containerName: String
        let networkName: String
        let networkAlias: String
        let endpoint: String
        let isEnabled: Bool
    }

    struct PublicAccess: Decodable {
        let httpsMode: String
    }

    struct Proxy: Decodable {
        let image: String
        let containerName: String
        let networkName: String
        let networkAlias: String
        let hostPort: UInt16?
        let containerPort: UInt16
        let apiUpstream: String
        let webUpstream: String
        let publicHTTPAddress: String?
        let buildContextPath: String
    }

    struct Caddy: Decodable {
        let image: String
        let containerName: String
        let networkName: String
        let networkAlias: String
        let dataVolumeName: String
        let configVolumeName: String
        let caddyfilePath: String
        let publicHTTPSAddress: String
        let localRootCertificatePath: String?
    }

    struct LocalContainer: Decodable {
        let image: String
        let containerName: String
        let volumeName: String
        let networkName: String
    }
}

private struct InstallationSecretsDocument: Decodable {
    let schemaVersion: Int
    let postgresql: PostgreSQL
    let redis: Redis
    let storage: Storage
    let push: Push

    struct PostgreSQL: Decodable {
        let password: String
    }

    struct Redis: Decodable {
        let password: String?
    }

    struct Storage: Decodable {
        let secretAccessKey: String
    }

    struct Push: Decodable {
        let secretKey: String
    }
}
