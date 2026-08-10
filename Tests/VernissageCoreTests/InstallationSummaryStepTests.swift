import Foundation
import Testing
@testable import VernissageCore

struct InstallationSummaryStepTests {
    @Test
    func `Successful installation writes a versioned summary and stores its path`() throws {
        let recorder = InstallationSummaryRecorder()
        let output = InstallationSummaryOutputBuffer()
        let context = makeCompleteContext()
        let step = makeStep(recorder: recorder, output: output)

        try step.run(context: context)

        let summary = try #require(recorder.summary)
        let secrets = try #require(recorder.secrets)
        #expect(context.summaryFilePath == "/tmp/vernissage/vernissage.yml")
        #expect(context.secretsFilePath == "/tmp/vernissage/vernissage.secrets.yml")
        #expect(summary.contains("schemaVersion: 2"))
        #expect(summary.contains("secretsFile: \"vernissage.secrets.yml\""))
        #expect(summary.contains("instance:\n  id: \"abcdefgh\""))
        #expect(summary.contains("version: \"0.1.7\""))
        #expect(summary.contains("installedAt: \"1970-01-01T00:00:00Z\""))
        #expect(summary.contains("domain: \"social.example.com\""))
        #expect(summary.contains("publicAddress: \"https://social.example.com\""))
        #expect(summary.contains("name: \"Jan \\\"Admin\\\": Kowalski\""))
        #expect(summary.contains("mode: \"localContainer\""))
        #expect(summary.contains("provider: \"awsS3\""))
        #expect(summary.contains("accessKeyId: \"visible-access-key-id\""))
        #expect(summary.contains("imagesURL: \"https://cdn.example.com/vernissage/\""))
        #expect(summary.contains("hostPort: null"))
        #expect(summary.contains("localRootCertificatePath: \"/tmp/vernissage/caddy/root.crt\""))
        #expect(secrets.contains("schemaVersion: 2"))
        #expect(output.text.contains("Installation configuration saved"))
        #expect(output.text.contains("Instance identifier: abcdefgh"))
        #expect(output.text.contains("/tmp/vernissage/vernissage.yml"))
        #expect(output.text.contains("/tmp/vernissage/vernissage.secrets.yml"))
        #expect(output.text.contains("future vernissagectl commands"))
        #expect(output.text.contains("contains unencrypted credentials"))
        #expect(output.text.contains("Never commit it to Git"))
        #expect(output.text.contains("encrypted backup"))
        #expect(output.text.contains("are not a backup"))
        #expect(output.text.contains("Next steps"))
        #expect(output.text.contains("Thank you for choosing Vernissage"))
    }

    @Test
    func `Configuration files can be saved before final HTTPS verification`() throws {
        let recorder = InstallationSummaryRecorder()
        let output = InstallationSummaryOutputBuffer()
        let context = makeCompleteContext()
        let step = makeStep(recorder: recorder, output: output)

        try step.save(context: context)

        #expect(recorder.summary != nil)
        #expect(recorder.secrets != nil)
        #expect(context.summaryFilePath == "/tmp/vernissage/vernissage.yml")
        #expect(context.secretsFilePath == "/tmp/vernissage/vernissage.secrets.yml")
        #expect(output.text.contains("Installation configuration saved"))
        #expect(output.text.contains("Next steps") == false)

        step.printNextSteps()

        #expect(output.text.contains("Next steps"))
    }

    @Test
    func `Public installation summary excludes every password token and secret key`() throws {
        let recorder = InstallationSummaryRecorder()
        let context = makeCompleteContext()
        let step = makeStep(
            recorder: recorder,
            output: InstallationSummaryOutputBuffer()
        )

        try step.run(context: context)

        let summary = try #require(recorder.summary)
        let secrets = try #require(recorder.secrets)
        let runtimeSecrets = [
            "postgresql-password-secret",
            "redis-password-secret",
            "storage-secret-access-key",
            "push-shared-secret-key"
        ]
        for secret in runtimeSecrets {
            #expect(secrets.contains(secret))
        }
        #expect(secrets.contains("postgresql:\n  password: \"postgresql-password-secret\""))
        #expect(secrets.contains("redis:\n  password: \"redis-password-secret\""))
        #expect(secrets.contains("storage:\n  secretAccessKey: \"storage-secret-access-key\""))
        #expect(secrets.contains("push:\n  secretKey: \"push-shared-secret-key\""))
        for secret in runtimeSecrets + [
            "admin-password-secret",
            "administrator-access-token-secret"
        ] {
            #expect(summary.contains(secret) == false)
        }
        #expect(secrets.contains("admin-password-secret") == false)
        #expect(secrets.contains("administrator-access-token-secret") == false)
        #expect(summary.contains("redis://") == false)
        #expect(summary.contains("password:") == false)
        #expect(summary.contains("secretAccessKey:") == false)
        #expect(summary.contains("accessToken:") == false)
        #expect(summary.contains("secretKey:") == false)
    }

    @Test
    func `Generated configuration files restore the persistent installation context`() throws {
        let recorder = InstallationSummaryRecorder()
        let originalContext = makeCompleteContext()
        try makeStep(
            recorder: recorder,
            output: InstallationSummaryOutputBuffer()
        ).run(context: originalContext)
        let summary = try #require(recorder.summary)
        let secrets = try #require(recorder.secrets)
        let workingDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "vernissage-summary-round-trip-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: workingDirectory) }
        let locations = try InstallationSummaryStep.writeConfigurationFiles(
            summary,
            secrets,
            in: workingDirectory
        )
        let loader = InstallationConfigurationLoader(
            environment: { [:] },
            workingDirectory: { workingDirectory }
        )

        let restoredContext = try loader.load(configPath: locations.summaryURL.path)

        #expect(restoredContext.docker == originalContext.docker)
        #expect(restoredContext.instanceIdentifier == "abcdefgh")
        #expect(restoredContext.server == originalContext.server)
        #expect(restoredContext.database == originalContext.database)
        #expect(restoredContext.redis == originalContext.redis)
        #expect(restoredContext.storage == originalContext.storage)
        #expect(restoredContext.web == originalContext.web)
        #expect(restoredContext.push == originalContext.push)
        #expect(restoredContext.publicAccess == originalContext.publicAccess)
        #expect(restoredContext.proxy == originalContext.proxy)
        #expect(restoredContext.caddy == originalContext.caddy)
        #expect(restoredContext.administrator?.userId == originalContext.administrator?.userId)
        #expect(restoredContext.administrator?.password == nil)
        #expect(restoredContext.administrator?.accessToken == nil)
        #expect(restoredContext.serverServices?.image == originalContext.serverServices?.image)
        #expect(restoredContext.serverServices?.apiHealth == nil)
        #expect(restoredContext.serverServices?.jobsHealth == nil)
        #expect(restoredContext.serverServices?.databaseTables == nil)
    }

    @Test
    func `Configuration files are created with owner-only permissions`() throws {
        let fileManager = FileManager.default
        let workingDirectory = fileManager.temporaryDirectory.appendingPathComponent(
            "vernissage-summary-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            try? fileManager.removeItem(at: workingDirectory)
        }

        let locations = try InstallationSummaryStep.writeConfigurationFiles(
            "schemaVersion: 1\n",
            "schemaVersion: 1\n",
            in: workingDirectory,
            fileManager: fileManager
        )

        #expect(locations.summaryURL.lastPathComponent == "vernissage.yml")
        #expect(locations.secretsURL.lastPathComponent == "vernissage.secrets.yml")
        #expect(try String(contentsOf: locations.summaryURL, encoding: .utf8) == "schemaVersion: 1\n")
        #expect(try String(contentsOf: locations.secretsURL, encoding: .utf8) == "schemaVersion: 1\n")
        #expect(try permissions(of: locations.summaryURL, fileManager: fileManager) == 0o600)
        #expect(try permissions(of: locations.secretsURL, fileManager: fileManager) == 0o600)
        let generatedFiles = try fileManager.contentsOfDirectory(
            at: locations.summaryURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
        #expect(Set(generatedFiles.map(\.lastPathComponent)) == [
            "vernissage.yml",
            "vernissage.secrets.yml"
        ])
    }

    @Test
    func `Manual HTTPS installation is summarized without Caddy`() throws {
        let recorder = InstallationSummaryRecorder()
        let context = makeCompleteContext()
        context.publicAccess = PublicAccessConfiguration(httpsMode: .manual)
        context.proxy = ProxyConfiguration(
            image: "vernissage-proxy:abcdefgh",
            containerName: "vernissage-abcdefgh-proxy",
            networkName: "vernissage-abcdefgh-network",
            networkAlias: "vernissage-proxy.internal",
            hostPort: 8080,
            containerPort: 8080,
            apiUpstream: "vernissage-api.internal:8080",
            webUpstream: "vernissage-web.internal:8080",
            publicHTTPAddress: "http://social.example.com:8080",
            buildContextPath: "/tmp/vernissage/proxy"
        )
        context.caddy = nil

        try makeStep(
            recorder: recorder,
            output: InstallationSummaryOutputBuffer()
        ).run(context: context)

        let summary = try #require(recorder.summary)
        #expect(summary.contains("httpsMode: \"manual\""))
        #expect(summary.contains("publicAddress: \"http://social.example.com:8080\""))
        #expect(summary.contains("caddy: null"))
    }

    @Test
    func `Missing installation data prevents summary file creation`() {
        let recorder = InstallationSummaryRecorder()
        let context = makeCompleteContext()
        context.storage = nil
        let step = makeStep(
            recorder: recorder,
            output: InstallationSummaryOutputBuffer()
        )

        let error = #expect(throws: InstallationSummaryStepError.self) {
            try step.run(context: context)
        }

        #expect(error == .missingConfiguration("S3 object storage"))
        #expect(recorder.summary == nil)
        #expect(recorder.secrets == nil)
        #expect(context.summaryFilePath == nil)
        #expect(context.secretsFilePath == nil)
    }

    private func makeStep(
        recorder: InstallationSummaryRecorder,
        output: InstallationSummaryOutputBuffer
    ) -> InstallationSummaryStep {
        InstallationSummaryStep(
            console: Console(
                colorsEnabled: false,
                readInput: { nil },
                writeOutput: output.append
            ),
            installedAt: { Date(timeIntervalSince1970: 0) },
            writeFiles: recorder.write
        )
    }

    private func makeCompleteContext() -> InstallationContext {
        let context = InstallationContext(instanceIdentifier: "abcdefgh")
        context.docker = DockerEnvironment(
            clientVersion: "29.0.0",
            serverVersion: "29.0.0",
            composeVersion: "2.40.0"
        )
        context.server = ServerConfiguration(domain: "social.example.com")
        context.administrator = AdministratorConfiguration(
            userId: 123,
            name: "Jan \"Admin\": Kowalski",
            email: "jan@example.com",
            username: "jankowalski",
            password: Secret(value: "admin-password-secret"),
            accessToken: Secret(value: "administrator-access-token-secret")
        )
        context.database = DatabaseConfiguration(
            mode: .localContainer,
            host: "vernissage-abcdefgh-postgres",
            port: 5432,
            database: "vernissage",
            username: "vernissage-user",
            password: Secret(value: "postgresql-password-secret"),
            tlsMode: .disable,
            localResources: LocalPostgreSQLResources(
                image: "postgres:18",
                containerName: "vernissage-abcdefgh-postgres",
                volumeName: "vernissage-abcdefgh-postgres-data",
                networkName: "vernissage-abcdefgh-network"
            )
        )
        context.redis = RedisConfiguration(
            mode: .localContainer,
            url: Secret(
                value: "redis://default:redis-password-secret@vernissage-abcdefgh-redis:6379/0"
            ),
            username: "default",
            host: "vernissage-abcdefgh-redis",
            port: 6379,
            database: 0,
            password: Secret(value: "redis-password-secret"),
            usesTLS: false,
            localResources: LocalRedisResources(
                image: "redis:8",
                containerName: "vernissage-abcdefgh-redis",
                volumeName: "vernissage-abcdefgh-redis-data",
                networkName: "vernissage-abcdefgh-network"
            )
        )
        context.storage = StorageConfiguration(
            provider: .awsS3,
            address: "https://s3.eu-central-1.amazonaws.com",
            region: "eu-central-1",
            bucket: "vernissage-media",
            accessKeyId: "visible-access-key-id",
            secretAccessKey: Secret(value: "storage-secret-access-key"),
            http1OnlyMode: true,
            imagesURL: "https://cdn.example.com/vernissage/",
            localResources: nil
        )
        context.serverServices = ServerServicesConfiguration(
            image: "mczachurski/vernissage-server:latest",
            networkName: "vernissage-abcdefgh-network",
            apiContainerName: "vernissage-abcdefgh-api",
            jobsContainerName: "vernissage-abcdefgh-jobs",
            apiNetworkAlias: "vernissage-api.internal",
            jobsNetworkAlias: "vernissage-jobs.internal",
            baseAddress: "https://social.example.com",
            apiHealth: healthyServer,
            jobsHealth: healthyServer,
            databaseTables: ["Roles", "Settings", "Users"]
        )
        context.web = WebConfiguration(
            image: "mczachurski/vernissage-web:latest",
            containerName: "vernissage-abcdefgh-web",
            networkName: "vernissage-abcdefgh-network",
            networkAlias: "vernissage-web.internal",
            allowedHosts: "social.example.com*.social.example.com",
            cspImageSource: "https://media.example.com"
        )
        context.push = PushConfiguration(
            image: "mczachurski/vernissage-push:latest",
            containerName: "vernissage-abcdefgh-push",
            networkName: "vernissage-abcdefgh-network",
            networkAlias: "vernissage-push.internal",
            endpoint: "http://vernissage-push.internal:8080",
            secretKey: Secret(value: "push-shared-secret-key"),
            isEnabled: false
        )
        context.publicAccess = PublicAccessConfiguration(httpsMode: .development)
        context.proxy = ProxyConfiguration(
            image: "vernissage-proxy:abcdefgh",
            containerName: "vernissage-abcdefgh-proxy",
            networkName: "vernissage-abcdefgh-network",
            networkAlias: "vernissage-proxy.internal",
            hostPort: nil,
            containerPort: 8080,
            apiUpstream: "vernissage-api.internal:8080",
            webUpstream: "vernissage-web.internal:8080",
            publicHTTPAddress: nil,
            buildContextPath: "/tmp/vernissage/proxy"
        )
        context.caddy = CaddyConfiguration(
            image: "caddy:latest",
            containerName: "vernissage-abcdefgh-caddy",
            networkName: "vernissage-abcdefgh-network",
            networkAlias: "vernissage-caddy.internal",
            dataVolumeName: "vernissage-abcdefgh-caddy-data",
            configVolumeName: "vernissage-abcdefgh-caddy-config",
            caddyfilePath: "/tmp/vernissage/caddy/Caddyfile",
            publicHTTPSAddress: "https://social.example.com",
            localRootCertificatePath: "/tmp/vernissage/caddy/root.crt"
        )
        return context
    }

    private var healthyServer: ServerHealth {
        ServerHealth(
            isDatabaseHealthy: true,
            isQueueHealthy: true,
            isWebPushHealthy: true,
            isStorageHealthy: true
        )
    }

    private func permissions(
        of url: URL,
        fileManager: FileManager
    ) throws -> Int {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}

private final class InstallationSummaryRecorder {
    private(set) var summary: String?
    private(set) var secrets: String?

    func write(
        _ summary: String,
        _ secrets: String
    ) -> InstallationFileLocations {
        self.summary = summary
        self.secrets = secrets
        return InstallationFileLocations(
            summaryURL: URL(fileURLWithPath: "/tmp/vernissage/vernissage.yml"),
            secretsURL: URL(
                fileURLWithPath: "/tmp/vernissage/vernissage.secrets.yml"
            )
        )
    }
}

private final class InstallationSummaryOutputBuffer {
    private(set) var text = ""

    func append(_ value: String) {
        text += value
    }
}
