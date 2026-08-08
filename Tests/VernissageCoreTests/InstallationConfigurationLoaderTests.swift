import Foundation
import Testing
@testable import VernissageCore

struct InstallationConfigurationLoaderTests {
    @Test
    func `Explicit configuration path has the highest priority and restores installation context`() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let explicitDirectory = temporaryDirectory.appendingPathComponent("explicit", isDirectory: true)
        let environmentDirectory = temporaryDirectory.appendingPathComponent("environment", isDirectory: true)
        let explicitURL = try writeInstallation(in: explicitDirectory, domain: "explicit.example.com")
        let environmentURL = try writeInstallation(in: environmentDirectory, domain: "environment.example.com")
        _ = try writeInstallation(in: temporaryDirectory, domain: "default.example.com")
        let loader = makeLoader(
            workingDirectory: temporaryDirectory,
            environment: [InstallationConfigurationLocator.environmentVariable: environmentURL.path]
        )

        let context = try loader.load(configPath: explicitURL.path)

        let docker = try #require(context.docker)
        let server = try #require(context.server)
        let administrator = try #require(context.administrator)
        let database = try #require(context.database)
        let databaseResources = try #require(database.localResources)
        let redis = try #require(context.redis)
        let redisResources = try #require(redis.localResources)
        let storage = try #require(context.storage)
        let storageResources = try #require(storage.localResources)
        let services = try #require(context.serverServices)
        let web = try #require(context.web)
        let push = try #require(context.push)
        let publicAccess = try #require(context.publicAccess)
        let proxy = try #require(context.proxy)
        let caddy = try #require(context.caddy)

        #expect(docker == DockerEnvironment(clientVersion: "29.0.0", serverVersion: "29.0.0", composeVersion: "5.0.0"))
        #expect(context.instanceIdentifier == "abcdefgh")
        #expect(server.domain == "explicit.example.com")
        #expect(administrator.userId == 123)
        #expect(administrator.name == "Jan Kowalski")
        #expect(administrator.email == "jan@example.com")
        #expect(administrator.username == "jankowalski")
        #expect(administrator.password == nil)
        #expect(administrator.accessToken == nil)
        #expect(database.mode == .localContainer)
        #expect(database.host == "vernissage-abcdefgh-postgres")
        #expect(database.port == 5432)
        #expect(database.database == "vernissage")
        #expect(database.username == "vernissage-user")
        #expect(database.password.value == "postgres-secret")
        #expect(database.tlsMode == .disable)
        #expect(databaseResources.image == "postgres:18")
        #expect(redis.mode == .localContainer)
        #expect(redis.url.value == "redis://default:redis-secret@vernissage-abcdefgh-redis:6379/0")
        #expect(redis.password?.value == "redis-secret")
        #expect(redisResources.volumeName == "vernissage-abcdefgh-redis-data")
        #expect(storage.provider == .localMinIO)
        #expect(storage.secretAccessKey.value == "storage-secret")
        #expect(storageResources.containerName == "vernissage-abcdefgh-minio")
        #expect(services.image == "mczachurski/vernissage-server:latest")
        #expect(services.apiHealth == nil)
        #expect(services.jobsHealth == nil)
        #expect(services.databaseTables == nil)
        #expect(web.allowedHosts == "explicit.example.com,*.explicit.example.com")
        #expect(push.secretKey.value == "push-secret")
        #expect(publicAccess.httpsMode == .development)
        #expect(proxy.hostPort == nil)
        #expect(caddy.publicHTTPSAddress == "https://explicit.example.com")
        #expect(context.summaryFilePath == explicitURL.path)
        #expect(context.secretsFilePath == explicitDirectory.appendingPathComponent("vernissage.secrets.yml").path)
    }

    @Test
    func `Environment configuration path is used before working directory defaults`() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let environmentURL = try writeInstallation(
            in: temporaryDirectory.appendingPathComponent("environment", isDirectory: true),
            domain: "environment.example.com"
        )
        _ = try writeInstallation(in: temporaryDirectory, domain: "default.example.com")
        let loader = makeLoader(
            workingDirectory: temporaryDirectory,
            environment: [InstallationConfigurationLocator.environmentVariable: environmentURL.path]
        )

        let context = try loader.load()

        #expect(context.server?.domain == "environment.example.com")
        #expect(context.summaryFilePath == environmentURL.path)
    }

    @Test
    func `Root working directory configuration is used before nested installer configuration`() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let rootURL = try writeInstallation(in: temporaryDirectory, domain: "root.example.com")
        _ = try writeInstallation(
            in: temporaryDirectory.appendingPathComponent("vernissage", isDirectory: true),
            domain: "nested.example.com"
        )

        let context = try makeLoader(workingDirectory: temporaryDirectory).load()

        #expect(context.server?.domain == "root.example.com")
        #expect(context.summaryFilePath == rootURL.path)
    }

    @Test
    func `Nested installer configuration is used as the final default`() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let nestedURL = try writeInstallation(
            in: temporaryDirectory.appendingPathComponent("vernissage", isDirectory: true),
            domain: "nested.example.com"
        )

        let context = try makeLoader(workingDirectory: temporaryDirectory).load()

        #expect(context.server?.domain == "nested.example.com")
        #expect(context.summaryFilePath == nestedURL.path)
    }

    @Test
    func `Configuration lookup does not search parent directories`() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        _ = try writeInstallation(in: temporaryDirectory, domain: "parent.example.com")
        let child = temporaryDirectory.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let loader = makeLoader(workingDirectory: child)

        let error = #expect(throws: InstallationConfigurationLoadingError.self) {
            try loader.load()
        }

        #expect(error == .configurationNotFound(searchedPaths: [
            child.appendingPathComponent("vernissage.yml").path,
            child.appendingPathComponent("vernissage/vernissage.yml").path
        ]))
    }

    @Test
    func `Missing explicit configuration does not fall back to a default file`() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        _ = try writeInstallation(in: temporaryDirectory, domain: "default.example.com")
        let missingURL = temporaryDirectory.appendingPathComponent("missing.yml")
        let loader = makeLoader(workingDirectory: temporaryDirectory)

        let error = #expect(throws: InstallationConfigurationLoadingError.self) {
            try loader.load(configPath: missingURL.path)
        }

        #expect(error == .configurationNotFound(searchedPaths: [missingURL.path]))
    }

    @Test
    func `Secrets file is resolved relative to the selected configuration`() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let configurationDirectory = temporaryDirectory.appendingPathComponent("configuration", isDirectory: true)
        let configurationURL = try writeInstallation(
            in: configurationDirectory,
            domain: "relative.example.com"
        )
        try "not: valid secrets\n".write(
            to: temporaryDirectory.appendingPathComponent("vernissage.secrets.yml"),
            atomically: true,
            encoding: .utf8
        )
        let loader = makeLoader(workingDirectory: temporaryDirectory)

        let context = try loader.load(configPath: configurationURL.path)

        #expect(context.database?.password.value == "postgres-secret")
        #expect(context.secretsFilePath == configurationDirectory.appendingPathComponent("vernissage.secrets.yml").path)
    }

    @Test
    func `Unsupported schema version is rejected before secrets are loaded`() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let configurationURL = try writeInstallation(
            in: temporaryDirectory,
            domain: "future.example.com",
            schemaVersion: 99
        )
        let loader = makeLoader(workingDirectory: temporaryDirectory)

        let error = #expect(throws: InstallationConfigurationLoadingError.self) {
            try loader.load(configPath: configurationURL.path)
        }

        #expect(error == .unsupportedSchemaVersion(
            path: configurationURL.path,
            found: 99,
            supported: InstallationSummaryStep.schemaVersion
        ))
    }

    @Test
    func `Secrets reference cannot escape the configuration directory`() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let configurationDirectory = temporaryDirectory.appendingPathComponent("configuration", isDirectory: true)
        let configurationURL = try writeInstallation(
            in: configurationDirectory,
            domain: "safe.example.com",
            secretsFile: "../outside.yml"
        )
        let loader = makeLoader(workingDirectory: temporaryDirectory)

        let error = #expect(throws: InstallationConfigurationLoadingError.self) {
            try loader.load(configPath: configurationURL.path)
        }

        #expect(error == .invalidSecretsReference("../outside.yml"))
    }

    @Test
    func `Invalid installation identifier is rejected while loading configuration`() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let configurationURL = try writeInstallation(
            in: temporaryDirectory,
            domain: "invalid-id.example.com"
        )
        var contents = try String(contentsOf: configurationURL, encoding: .utf8)
        contents = contents.replacingOccurrences(
            of: "id: \"abcdefgh\"",
            with: "id: \"INVALID1\""
        )
        try contents.write(to: configurationURL, atomically: true, encoding: .utf8)
        let loader = makeLoader(workingDirectory: temporaryDirectory)

        let error = #expect(throws: InstallationConfigurationLoadingError.self) {
            try loader.load(configPath: configurationURL.path)
        }

        #expect(error == .invalidValue(field: "instance.id", value: "INVALID1"))
    }

    private func makeLoader(
        workingDirectory: URL,
        environment: [String: String] = [:]
    ) -> InstallationConfigurationLoader {
        InstallationConfigurationLoader(
            environment: { environment },
            workingDirectory: { workingDirectory }
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "vernissage-configuration-loader-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func writeInstallation(
        in directory: URL,
        domain: String,
        schemaVersion: Int = InstallationSummaryStep.schemaVersion,
        secretsFile: String = "vernissage.secrets.yml"
    ) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configurationURL = directory.appendingPathComponent("vernissage.yml")
        let secretsURL = directory.appendingPathComponent("vernissage.secrets.yml")
        try configuration(
            domain: domain,
            schemaVersion: schemaVersion,
            secretsFile: secretsFile
        ).write(to: configurationURL, atomically: true, encoding: .utf8)
        try secrets.write(to: secretsURL, atomically: true, encoding: .utf8)
        return configurationURL
    }

    private func configuration(
        domain: String,
        schemaVersion: Int,
        secretsFile: String
    ) -> String {
        """
        schemaVersion: \(schemaVersion)
        secretsFile: "\(secretsFile)"
        instance:
          id: "abcdefgh"
        installer:
          version: "0.1.3"
          installedAt: "2026-08-08T10:00:00Z"
        docker:
          clientVersion: "29.0.0"
          serverVersion: "29.0.0"
          composeVersion: "5.0.0"
        server:
          domain: "\(domain)"
          publicAddress: "https://\(domain)"
        administrator:
          userId: 123
          name: "Jan Kowalski"
          email: "jan@example.com"
          username: "jankowalski"
        postgresql:
          mode: "localContainer"
          host: "vernissage-abcdefgh-postgres"
          port: 5432
          database: "vernissage"
          username: "vernissage-user"
          tlsMode: "disable"
          localContainer:
            image: "postgres:18"
            containerName: "vernissage-abcdefgh-postgres"
            volumeName: "vernissage-abcdefgh-postgres-data"
            networkName: "vernissage-abcdefgh-network"
        redis:
          mode: "localContainer"
          username: "default"
          host: "vernissage-abcdefgh-redis"
          port: 6379
          database: 0
          usesTLS: false
          localContainer:
            image: "redis:8"
            containerName: "vernissage-abcdefgh-redis"
            volumeName: "vernissage-abcdefgh-redis-data"
            networkName: "vernissage-abcdefgh-network"
        storage:
          provider: "localMinIO"
          address: "http://vernissage-abcdefgh-minio:9000"
          region: null
          bucket: "vernissage"
          accessKeyId: "minio"
          http1OnlyMode: false
          localContainer:
            image: "minio/minio:latest"
            containerName: "vernissage-abcdefgh-minio"
            volumeName: "vernissage-abcdefgh-minio-data"
            networkName: "vernissage-abcdefgh-network"
        apiAndJobs:
          image: "mczachurski/vernissage-server:latest"
          networkName: "vernissage-abcdefgh-network"
          apiContainerName: "vernissage-abcdefgh-api"
          apiNetworkAlias: "vernissage-api.internal"
          jobsContainerName: "vernissage-abcdefgh-jobs"
          jobsNetworkAlias: "vernissage-jobs.internal"
          baseAddress: "https://\(domain)"
        web:
          image: "mczachurski/vernissage-web:latest"
          containerName: "vernissage-abcdefgh-web"
          networkName: "vernissage-abcdefgh-network"
          networkAlias: "vernissage-web.internal"
          allowedHosts: "\(domain),*.\(domain)"
          cspImageSource: null
        push:
          image: "mczachurski/vernissage-push:latest"
          containerName: "vernissage-abcdefgh-push"
          networkName: "vernissage-abcdefgh-network"
          networkAlias: "vernissage-push.internal"
          endpoint: "http://vernissage-push.internal:3000/send"
          isEnabled: false
        publicAccess:
          httpsMode: "development"
        proxy:
          image: "vernissage-proxy:abcdefgh"
          containerName: "vernissage-abcdefgh-proxy"
          networkName: "vernissage-abcdefgh-network"
          networkAlias: "vernissage-proxy.internal"
          hostPort: null
          containerPort: 8080
          apiUpstream: "vernissage-api.internal:8080"
          webUpstream: "vernissage-web.internal:8080"
          publicHTTPAddress: null
          buildContextPath: "/srv/vernissage/proxy"
        caddy:
          image: "caddy:latest"
          containerName: "vernissage-abcdefgh-caddy"
          networkName: "vernissage-abcdefgh-network"
          networkAlias: "vernissage-caddy.internal"
          dataVolumeName: "vernissage-abcdefgh-caddy-data"
          configVolumeName: "vernissage-abcdefgh-caddy-config"
          caddyfilePath: "/srv/vernissage/caddy/Caddyfile"
          publicHTTPSAddress: "https://\(domain)"
          localRootCertificatePath: "/srv/vernissage/caddy/root.crt"
        """
    }

    private var secrets: String {
        """
        schemaVersion: 2
        postgresql:
          password: "postgres-secret"
        redis:
          password: "redis-secret"
        storage:
          secretAccessKey: "storage-secret"
        push:
          secretKey: "push-secret"
        """
    }
}
