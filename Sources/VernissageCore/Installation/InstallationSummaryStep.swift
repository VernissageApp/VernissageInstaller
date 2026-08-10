import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

enum InstallationSummaryStepError: LocalizedError, Equatable {
    case missingConfiguration(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingConfiguration(let name):
            "The \(name) configuration is missing. Complete all previous installer steps first."
        case .writeFailed(let details):
            "The installer could not save the Vernissage configuration files. Details: \(details)"
        }
    }
}

struct InstallationFileLocations: Equatable {
    let summaryURL: URL
    let secretsURL: URL
}

struct InstallationSummaryStep {
    static let schemaVersion = 2
    static let summaryFileName = "vernissage.yml"
    static let secretsFileName = "vernissage.secrets.yml"

    private let console: Console
    private let installedAt: () -> Date
    private let writeFiles: (String, String) throws -> InstallationFileLocations

    init(
        console: Console,
        installedAt: @escaping () -> Date,
        writeFiles: @escaping (String, String) throws -> InstallationFileLocations
    ) {
        self.console = console
        self.installedAt = installedAt
        self.writeFiles = writeFiles
    }

    static func live(colorsEnabled: Bool) -> InstallationSummaryStep {
        InstallationSummaryStep(
            console: .live(colorsEnabled: colorsEnabled),
            installedAt: Date.init,
            writeFiles: { summary, secrets in
                try Self.writeConfigurationFiles(summary, secrets)
            }
        )
    }

    func run(context: InstallationContext) throws {
        try save(context: context)
        printNextSteps()
    }

    func save(context: InstallationContext) throws {
        let installation = try collectedInstallation(from: context)
        let summary = makeSummary(
            installation: installation,
            installedAt: installedAt()
        )
        let secrets = makeSecrets(installation: installation)

        let locations: InstallationFileLocations
        do {
            locations = try writeFiles(summary, secrets)
        } catch {
            throw InstallationSummaryStepError.writeFailed(error.localizedDescription)
        }

        context.summaryFilePath = locations.summaryURL.path
        context.secretsFilePath = locations.secretsURL.path
        console.success("Installation configuration saved.")
        console.value(label: "Instance identifier", value: context.instanceIdentifier)
        console.value(label: "Configuration", value: locations.summaryURL.path)
        console.value(label: "Secrets", value: locations.secretsURL.path)
        console.info("Keep both files in place for future vernissagectl commands.")
        console.warning("The secrets file contains unencrypted credentials. Never commit it to Git or share it.")
        console.info("Store an encrypted backup of the secrets file in a secure location.")
        console.warning("These files are not a backup of your database, media, Docker volumes, or complete Vernissage instance.")
    }

    func printNextSteps() {
        console.line("")
        console.installationNextSteps()
    }

    static func writeConfigurationFiles(
        _ summary: String,
        _ secrets: String
    ) throws -> InstallationFileLocations {
        let fileManager = FileManager.default
        let workingDirectory = URL(
            fileURLWithPath: fileManager.currentDirectoryPath,
            isDirectory: true
        )
        return try writeConfigurationFiles(
            summary,
            secrets,
            in: workingDirectory,
            fileManager: fileManager
        )
    }

    static func writeConfigurationFiles(
        _ summary: String,
        _ secrets: String,
        in workingDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> InstallationFileLocations {
        let directory = configurationDirectory(in: workingDirectory)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let summaryURL = directory.appendingPathComponent(Self.summaryFileName)
        let secretsURL = directory.appendingPathComponent(Self.secretsFileName)
        try writeProtectedFile(
            secrets,
            to: secretsURL,
            fileManager: fileManager
        )
        try writeProtectedFile(
            summary,
            to: summaryURL,
            fileManager: fileManager
        )
        return InstallationFileLocations(
            summaryURL: summaryURL,
            secretsURL: secretsURL
        )
    }

    static func configurationDirectory(in workingDirectory: URL) -> URL {
        workingDirectory.appendingPathComponent("vernissage", isDirectory: true)
    }

    private static func writeProtectedFile(
        _ contents: String,
        to url: URL,
        fileManager: FileManager
    ) throws {
        let temporaryURL = url
            .deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let data = Data(contents.utf8)
        guard fileManager.createFile(
            atPath: temporaryURL.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer {
            try? fileManager.removeItem(at: temporaryURL)
        }

        try replaceItemAtomically(at: temporaryURL, with: url)
    }

    private static func replaceItemAtomically(
        at sourceURL: URL,
        with destinationURL: URL
    ) throws {
        let result = sourceURL.path.withCString { sourcePath in
            destinationURL.path.withCString { destinationPath in
                rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func collectedInstallation(
        from context: InstallationContext
    ) throws -> CollectedInstallationSummary {
        guard let docker = context.docker else {
            throw InstallationSummaryStepError.missingConfiguration("Docker environment")
        }
        guard let server = context.server else {
            throw InstallationSummaryStepError.missingConfiguration("server and domain")
        }
        guard let administrator = context.administrator else {
            throw InstallationSummaryStepError.missingConfiguration("administrator account")
        }
        guard let database = context.database else {
            throw InstallationSummaryStepError.missingConfiguration("PostgreSQL database")
        }
        guard let redis = context.redis else {
            throw InstallationSummaryStepError.missingConfiguration("Redis")
        }
        guard let storage = context.storage else {
            throw InstallationSummaryStepError.missingConfiguration("S3 object storage")
        }
        guard let serverServices = context.serverServices else {
            throw InstallationSummaryStepError.missingConfiguration("Vernissage API and Jobs")
        }
        guard let web = context.web else {
            throw InstallationSummaryStepError.missingConfiguration("Vernissage Web")
        }
        guard let push = context.push else {
            throw InstallationSummaryStepError.missingConfiguration("Vernissage Push")
        }
        guard let publicAccess = context.publicAccess else {
            throw InstallationSummaryStepError.missingConfiguration("HTTPS and public access")
        }
        guard let proxy = context.proxy else {
            throw InstallationSummaryStepError.missingConfiguration("Vernissage Proxy")
        }
        if publicAccess.httpsMode != .manual, context.caddy == nil {
            throw InstallationSummaryStepError.missingConfiguration("Caddy")
        }

        return CollectedInstallationSummary(
            instanceIdentifier: context.instanceIdentifier,
            docker: docker,
            server: server,
            administrator: administrator,
            database: database,
            redis: redis,
            storage: storage,
            serverServices: serverServices,
            web: web,
            push: push,
            publicAccess: publicAccess,
            proxy: proxy,
            caddy: context.caddy
        )
    }

    private func makeSummary(
        installation: CollectedInstallationSummary,
        installedAt: Date
    ) -> String {
        var document = YAMLDocument()
        document.field("schemaVersion", Self.schemaVersion)
        document.field("secretsFile", Self.secretsFileName)

        document.section("instance")
        document.field("id", installation.instanceIdentifier, indent: 1)

        document.section("installer")
        document.field("version", VernissageVersion.current, indent: 1)
        document.field("installedAt", Self.timestamp(installedAt), indent: 1)

        document.section("docker")
        document.field("clientVersion", installation.docker.clientVersion, indent: 1)
        document.field("serverVersion", installation.docker.serverVersion, indent: 1)
        document.field("composeVersion", installation.docker.composeVersion, indent: 1)

        document.section("server")
        document.field("domain", installation.server.domain, indent: 1)
        document.field(
            "publicAddress",
            installation.caddy?.publicHTTPSAddress ?? installation.proxy.publicHTTPAddress,
            indent: 1
        )

        document.section("administrator")
        document.field("userId", installation.administrator.userId, indent: 1)
        document.field("name", installation.administrator.name, indent: 1)
        document.field("email", installation.administrator.email, indent: 1)
        document.field("username", installation.administrator.username, indent: 1)

        document.section("postgresql")
        document.field("mode", Self.databaseMode(installation.database.mode), indent: 1)
        document.field("host", installation.database.host, indent: 1)
        document.field("port", installation.database.port, indent: 1)
        document.field("database", installation.database.database, indent: 1)
        document.field("username", installation.database.username, indent: 1)
        document.field("tlsMode", installation.database.tlsMode.rawValue, indent: 1)
        append(
            localResources: installation.database.localResources,
            to: &document,
            parentIndent: 1
        )

        document.section("redis")
        document.field("mode", Self.redisMode(installation.redis.mode), indent: 1)
        document.field("username", installation.redis.username, indent: 1)
        document.field("host", installation.redis.host, indent: 1)
        document.field("port", installation.redis.port, indent: 1)
        document.field("database", installation.redis.database, indent: 1)
        document.field("usesTLS", installation.redis.usesTLS, indent: 1)
        append(
            localResources: installation.redis.localResources,
            to: &document,
            parentIndent: 1
        )

        document.section("storage")
        document.field("provider", Self.storageProvider(installation.storage.provider), indent: 1)
        document.field("address", installation.storage.address, indent: 1)
        document.field("region", installation.storage.region, indent: 1)
        document.field("bucket", installation.storage.bucket, indent: 1)
        document.field("accessKeyId", installation.storage.accessKeyId, indent: 1)
        document.field("http1OnlyMode", installation.storage.http1OnlyMode, indent: 1)
        document.field("imagesURL", installation.storage.imagesURL, indent: 1)
        append(
            localResources: installation.storage.localResources,
            to: &document,
            parentIndent: 1
        )

        document.section("apiAndJobs")
        document.field("image", installation.serverServices.image, indent: 1)
        document.field("networkName", installation.serverServices.networkName, indent: 1)
        document.field("apiContainerName", installation.serverServices.apiContainerName, indent: 1)
        document.field("apiNetworkAlias", installation.serverServices.apiNetworkAlias, indent: 1)
        document.field("jobsContainerName", installation.serverServices.jobsContainerName, indent: 1)
        document.field("jobsNetworkAlias", installation.serverServices.jobsNetworkAlias, indent: 1)
        document.field("baseAddress", installation.serverServices.baseAddress, indent: 1)

        document.section("web")
        document.field("image", installation.web.image, indent: 1)
        document.field("containerName", installation.web.containerName, indent: 1)
        document.field("networkName", installation.web.networkName, indent: 1)
        document.field("networkAlias", installation.web.networkAlias, indent: 1)
        document.field("allowedHosts", installation.web.allowedHosts, indent: 1)
        document.field("cspImageSource", installation.web.cspImageSource, indent: 1)

        document.section("push")
        document.field("image", installation.push.image, indent: 1)
        document.field("containerName", installation.push.containerName, indent: 1)
        document.field("networkName", installation.push.networkName, indent: 1)
        document.field("networkAlias", installation.push.networkAlias, indent: 1)
        document.field("endpoint", installation.push.endpoint, indent: 1)
        document.field("isEnabled", installation.push.isEnabled, indent: 1)

        document.section("publicAccess")
        document.field("httpsMode", Self.httpsMode(installation.publicAccess.httpsMode), indent: 1)

        document.section("proxy")
        document.field("image", installation.proxy.image, indent: 1)
        document.field("containerName", installation.proxy.containerName, indent: 1)
        document.field("networkName", installation.proxy.networkName, indent: 1)
        document.field("networkAlias", installation.proxy.networkAlias, indent: 1)
        document.field("hostPort", installation.proxy.hostPort, indent: 1)
        document.field("containerPort", installation.proxy.containerPort, indent: 1)
        document.field("apiUpstream", installation.proxy.apiUpstream, indent: 1)
        document.field("webUpstream", installation.proxy.webUpstream, indent: 1)
        document.field("publicHTTPAddress", installation.proxy.publicHTTPAddress, indent: 1)
        document.field("buildContextPath", installation.proxy.buildContextPath, indent: 1)

        if let caddy = installation.caddy {
            document.section("caddy")
            document.field("image", caddy.image, indent: 1)
            document.field("containerName", caddy.containerName, indent: 1)
            document.field("networkName", caddy.networkName, indent: 1)
            document.field("networkAlias", caddy.networkAlias, indent: 1)
            document.field("dataVolumeName", caddy.dataVolumeName, indent: 1)
            document.field("configVolumeName", caddy.configVolumeName, indent: 1)
            document.field("caddyfilePath", caddy.caddyfilePath, indent: 1)
            document.field("publicHTTPSAddress", caddy.publicHTTPSAddress, indent: 1)
            document.field("localRootCertificatePath", caddy.localRootCertificatePath, indent: 1)
        } else {
            document.nullField("caddy")
        }

        return document.text
    }

    private func makeSecrets(
        installation: CollectedInstallationSummary
    ) -> String {
        var document = YAMLDocument()
        document.field("schemaVersion", Self.schemaVersion)

        document.section("postgresql")
        document.field("password", installation.database.password.value, indent: 1)

        document.section("redis")
        document.field("password", installation.redis.password?.value, indent: 1)

        document.section("storage")
        document.field(
            "secretAccessKey",
            installation.storage.secretAccessKey.value,
            indent: 1
        )

        document.section("push")
        document.field("secretKey", installation.push.secretKey.value, indent: 1)

        return document.text
    }

    private func append(
        localResources: LocalPostgreSQLResources?,
        to document: inout YAMLDocument,
        parentIndent: Int
    ) {
        guard let localResources else {
            document.nullField("localContainer", indent: parentIndent)
            return
        }
        document.section("localContainer", indent: parentIndent)
        document.field("image", localResources.image, indent: parentIndent + 1)
        document.field("containerName", localResources.containerName, indent: parentIndent + 1)
        document.field("volumeName", localResources.volumeName, indent: parentIndent + 1)
        document.field("networkName", localResources.networkName, indent: parentIndent + 1)
    }

    private func append(
        localResources: LocalRedisResources?,
        to document: inout YAMLDocument,
        parentIndent: Int
    ) {
        guard let localResources else {
            document.nullField("localContainer", indent: parentIndent)
            return
        }
        document.section("localContainer", indent: parentIndent)
        document.field("image", localResources.image, indent: parentIndent + 1)
        document.field("containerName", localResources.containerName, indent: parentIndent + 1)
        document.field("volumeName", localResources.volumeName, indent: parentIndent + 1)
        document.field("networkName", localResources.networkName, indent: parentIndent + 1)
    }

    private func append(
        localResources: LocalMinIOResources?,
        to document: inout YAMLDocument,
        parentIndent: Int
    ) {
        guard let localResources else {
            document.nullField("localContainer", indent: parentIndent)
            return
        }
        document.section("localContainer", indent: parentIndent)
        document.field("image", localResources.image, indent: parentIndent + 1)
        document.field("containerName", localResources.containerName, indent: parentIndent + 1)
        document.field("volumeName", localResources.volumeName, indent: parentIndent + 1)
        document.field("networkName", localResources.networkName, indent: parentIndent + 1)
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func databaseMode(_ mode: DatabaseInstallationMode) -> String {
        switch mode {
        case .existing: "existing"
        case .localContainer: "localContainer"
        }
    }

    private static func redisMode(_ mode: RedisInstallationMode) -> String {
        switch mode {
        case .existing: "existing"
        case .localContainer: "localContainer"
        }
    }

    private static func storageProvider(_ provider: StorageProvider) -> String {
        switch provider {
        case .awsS3: "awsS3"
        case .compatible: "compatible"
        case .localMinIO: "localMinIO"
        }
    }

    private static func httpsMode(_ mode: HTTPSMode) -> String {
        switch mode {
        case .development: "development"
        case .production: "production"
        case .manual: "manual"
        }
    }
}

private struct CollectedInstallationSummary {
    let instanceIdentifier: String
    let docker: DockerEnvironment
    let server: ServerConfiguration
    let administrator: AdministratorConfiguration
    let database: DatabaseConfiguration
    let redis: RedisConfiguration
    let storage: StorageConfiguration
    let serverServices: ServerServicesConfiguration
    let web: WebConfiguration
    let push: PushConfiguration
    let publicAccess: PublicAccessConfiguration
    let proxy: ProxyConfiguration
    let caddy: CaddyConfiguration?
}

private struct YAMLDocument {
    private(set) var lines: [String] = []

    var text: String {
        lines.joined(separator: "\n") + "\n"
    }

    mutating func section(_ key: String, indent: Int = 0) {
        lines.append("\(padding(indent))\(key):")
    }

    mutating func nullField(_ key: String, indent: Int = 0) {
        lines.append("\(padding(indent))\(key): null")
    }

    mutating func field(_ key: String, _ value: String, indent: Int = 0) {
        lines.append("\(padding(indent))\(key): \(quoted(value))")
    }

    mutating func field(_ key: String, _ value: String?, indent: Int = 0) {
        guard let value else {
            nullField(key, indent: indent)
            return
        }
        field(key, value, indent: indent)
    }

    mutating func field(_ key: String, _ value: Bool, indent: Int = 0) {
        lines.append("\(padding(indent))\(key): \(value)")
    }

    mutating func field<T: BinaryInteger>(
        _ key: String,
        _ value: T,
        indent: Int = 0
    ) {
        lines.append("\(padding(indent))\(key): \(value)")
    }

    mutating func field<T: BinaryInteger>(
        _ key: String,
        _ value: T?,
        indent: Int = 0
    ) {
        guard let value else {
            nullField(key, indent: indent)
            return
        }
        field(key, value, indent: indent)
    }

    private func padding(_ indent: Int) -> String {
        String(repeating: "  ", count: indent)
    }

    private func quoted(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x08: result += "\\b"
            case 0x09: result += "\\t"
            case 0x0A: result += "\\n"
            case 0x0C: result += "\\f"
            case 0x0D: result += "\\r"
            case 0x22: result += "\\\""
            case 0x5C: result += "\\\\"
            case 0x00...0x1F, 0x7F...0x9F:
                let hex = String(scalar.value, radix: 16, uppercase: true)
                result += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        result += "\""
        return result
    }
}
