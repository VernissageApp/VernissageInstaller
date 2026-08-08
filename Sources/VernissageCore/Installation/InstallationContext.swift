import Foundation

/// Mutable state shared by all steps of the installation wizard.
final class InstallationContext {
    let instanceIdentifier: String
    var docker: DockerEnvironment?
    var server: ServerConfiguration?
    var administrator: AdministratorConfiguration?
    var database: DatabaseConfiguration?
    var redis: RedisConfiguration?
    var storage: StorageConfiguration?
    var serverServices: ServerServicesConfiguration?
    var web: WebConfiguration?
    var push: PushConfiguration?
    var publicAccess: PublicAccessConfiguration?
    var proxy: ProxyConfiguration?
    var caddy: CaddyConfiguration?
    var summaryFilePath: String?
    var secretsFilePath: String?

    var resourceNames: InstallationResourceNames {
        InstallationResourceNames(instanceIdentifier: instanceIdentifier)
    }

    init(instanceIdentifier: String) {
        precondition(
            InstallationIdentity.isValid(instanceIdentifier),
            "A Vernissage instance identifier must contain exactly eight lowercase ASCII letters."
        )
        self.instanceIdentifier = instanceIdentifier
    }
}

struct DockerEnvironment: Equatable {
    let clientVersion: String
    let serverVersion: String
    let composeVersion: String
}

struct ServerConfiguration: Equatable {
    let domain: String
}

struct AdministratorConfiguration: Equatable {
    let userId: Int64
    let name: String?
    let email: String
    let username: String
    /// Available only while the interactive installation is running.
    let password: Secret?
    /// Available only while the interactive installation is running.
    let accessToken: Secret?
}

enum DatabaseInstallationMode: Equatable {
    case existing
    case localContainer
}

enum DatabaseTLSMode: String, Codable, Equatable {
    case require
    case disable
}

struct LocalPostgreSQLResources: Equatable {
    let image: String
    let containerName: String
    let volumeName: String
    let networkName: String
}

struct DatabaseConfiguration: Equatable {
    let mode: DatabaseInstallationMode
    let host: String
    let port: UInt16
    let database: String
    let username: String
    let password: Secret
    let tlsMode: DatabaseTLSMode
    let localResources: LocalPostgreSQLResources?
}

enum RedisInstallationMode: Equatable {
    case existing
    case localContainer
}

struct LocalRedisResources: Equatable {
    let image: String
    let containerName: String
    let volumeName: String
    let networkName: String
}

struct RedisConfiguration: Equatable {
    let mode: RedisInstallationMode
    let url: Secret
    let username: String
    let host: String
    let port: UInt16
    let database: Int
    let password: Secret?
    let usesTLS: Bool
    let localResources: LocalRedisResources?
}

enum StorageProvider: Equatable {
    case awsS3
    case compatible
    case localMinIO
}

struct LocalMinIOResources: Equatable {
    let image: String
    let containerName: String
    let volumeName: String
    let networkName: String
}

struct StorageConfiguration: Equatable {
    let provider: StorageProvider
    let address: String
    let region: String?
    let bucket: String
    let accessKeyId: String
    let secretAccessKey: Secret
    let http1OnlyMode: Bool
    let localResources: LocalMinIOResources?
}

struct ServerHealth: Codable, Equatable {
    let isDatabaseHealthy: Bool
    let isQueueHealthy: Bool
    let isWebPushHealthy: Bool
    let isStorageHealthy: Bool
}

struct ServerServicesConfiguration: Equatable {
    let image: String
    let networkName: String
    let apiContainerName: String
    let jobsContainerName: String
    let apiNetworkAlias: String
    let jobsNetworkAlias: String
    let baseAddress: String
    /// Installation-time diagnostics are not persisted in `vernissage.yml`.
    let apiHealth: ServerHealth?
    let jobsHealth: ServerHealth?
    let databaseTables: [String]?
}

struct WebConfiguration: Equatable {
    let image: String
    let containerName: String
    let networkName: String
    let networkAlias: String
    let allowedHosts: String
    let cspImageSource: String?
}

struct PushConfiguration: Equatable {
    let image: String
    let containerName: String
    let networkName: String
    let networkAlias: String
    let endpoint: String
    let secretKey: Secret
    let isEnabled: Bool
}

enum HTTPSMode: Equatable {
    case development
    case production
    case manual
}

struct PublicAccessConfiguration: Equatable {
    let httpsMode: HTTPSMode
}

struct ProxyConfiguration: Equatable {
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

struct CaddyConfiguration: Equatable {
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

/// Keeps sensitive values from being exposed accidentally by descriptions or logs.
struct Secret: Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    let value: String

    var description: String { "<redacted>" }
    var debugDescription: String { "<redacted>" }
}
