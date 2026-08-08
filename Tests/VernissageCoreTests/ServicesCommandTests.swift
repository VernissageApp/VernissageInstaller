import Testing
@testable import VernissageCore

struct ServicesCommandTests {
    @Test
    func `Local containers and volumes are reported as managed by installer`() throws {
        let context = makeContext()

        let services = try ServicesInventory().services(from: context)

        #expect(services == [
            ServiceDescription(
                name: "PostgreSQL",
                location: .local,
                isManagedByInstaller: true,
                resource: "vernissage-abcdefgh-postgres (volume: vernissage-abcdefgh-postgres-data)"
            ),
            ServiceDescription(
                name: "Redis",
                location: .local,
                isManagedByInstaller: true,
                resource: "vernissage-abcdefgh-redis (volume: vernissage-abcdefgh-redis-data)"
            ),
            ServiceDescription(
                name: "S3 storage",
                location: .local,
                isManagedByInstaller: true,
                resource: "vernissage-abcdefgh-minio (volume: vernissage-abcdefgh-minio-data, bucket: vernissage)"
            ),
            ServiceDescription(
                name: "API",
                location: .local,
                isManagedByInstaller: true,
                resource: "vernissage-abcdefgh-api"
            ),
            ServiceDescription(
                name: "Jobs",
                location: .local,
                isManagedByInstaller: true,
                resource: "vernissage-abcdefgh-jobs"
            ),
            ServiceDescription(
                name: "Web",
                location: .local,
                isManagedByInstaller: true,
                resource: "vernissage-abcdefgh-web"
            ),
            ServiceDescription(
                name: "Push",
                location: .local,
                isManagedByInstaller: true,
                resource: "vernissage-abcdefgh-push"
            ),
            ServiceDescription(
                name: "Proxy",
                location: .local,
                isManagedByInstaller: true,
                resource: "vernissage-abcdefgh-proxy"
            ),
            ServiceDescription(
                name: "HTTPS",
                location: .local,
                isManagedByInstaller: true,
                resource: "vernissage-abcdefgh-caddy (https://social.example.com)"
            )
        ])
    }

    @Test
    func `Existing loopback services are local but not managed by installer`() throws {
        let context = makeContext()
        context.database = DatabaseConfiguration(
            mode: .existing,
            host: "localhost",
            port: 5432,
            database: "vernissage",
            username: "vernissage",
            password: Secret(value: "database-secret"),
            tlsMode: .disable,
            localResources: nil
        )
        context.redis = RedisConfiguration(
            mode: .existing,
            url: Secret(value: "rediss://default:redis-secret@redis.example.com:6380/2"),
            username: "default",
            host: "redis.example.com",
            port: 6380,
            database: 2,
            password: Secret(value: "redis-secret"),
            usesTLS: true,
            localResources: nil
        )
        context.storage = StorageConfiguration(
            provider: .compatible,
            address: "http://127.0.0.1:9000",
            region: nil,
            bucket: "media",
            accessKeyId: "access-key",
            secretAccessKey: Secret(value: "storage-secret"),
            http1OnlyMode: false,
            localResources: nil
        )
        context.publicAccess = PublicAccessConfiguration(httpsMode: .manual)
        context.proxy = makeProxy(hostPort: 8080)
        context.caddy = nil

        let services = try ServicesInventory().services(from: context)
        let postgresql = try service(named: "PostgreSQL", in: services)
        let redis = try service(named: "Redis", in: services)
        let storage = try service(named: "S3 storage", in: services)
        let proxy = try service(named: "Proxy", in: services)
        let https = try service(named: "HTTPS", in: services)

        #expect(postgresql.location == .local)
        #expect(postgresql.isManagedByInstaller == false)
        #expect(postgresql.resource == "localhost:5432/vernissage")
        #expect(redis.location == .external)
        #expect(redis.isManagedByInstaller == false)
        #expect(redis.resource == "redis.example.com:6380/2")
        #expect(storage.location == .local)
        #expect(storage.isManagedByInstaller == false)
        #expect(storage.resource == "http://127.0.0.1:9000 (bucket: media)")
        #expect(proxy.resource == "vernissage-abcdefgh-proxy (host port: 8080)")
        #expect(https.location == .external)
        #expect(https.isManagedByInstaller == false)
        #expect(https.resource == "configured outside vernissagectl")
    }

    @Test
    func `Services report renders instance configuration and management table`() throws {
        let context = makeContext()
        let services = try ServicesInventory().services(from: context)
        let output = ServicesOutputBuffer()
        let renderer = ServicesReportRenderer(
            console: Console(
                colorsEnabled: false,
                readInput: { nil },
                writeOutput: output.append
            )
        )

        renderer.render(context: context, services: services)

        #expect(output.text.contains("◆ Vernissage services"))
        #expect(output.text.contains("Instance: abcdefgh"))
        #expect(output.text.contains("Configuration: /srv/vernissage/vernissage.yml"))
        #expect(output.text.contains("SERVICE"))
        #expect(output.text.contains("LOCATION"))
        #expect(output.text.contains("MANAGED"))
        #expect(output.text.contains("PostgreSQL"))
        #expect(output.text.contains("local"))
        #expect(output.text.contains("yes"))
        #expect(output.text.contains("database-secret") == false)
        #expect(output.text.contains("redis-secret") == false)
        #expect(output.text.contains("storage-secret") == false)
        #expect(output.text.contains("push-secret") == false)
        #expect(output.text.contains("MANAGED indicates whether the service was created and is managed by vernissagectl."))
    }

    @Test
    func `Managed HTTPS requires Caddy configuration`() {
        let context = makeContext()
        context.caddy = nil

        let error = #expect(throws: ServicesInventoryError.self) {
            try ServicesInventory().services(from: context)
        }

        #expect(error == .missingConfiguration("Caddy"))
        #expect(error?.localizedDescription == "The Caddy configuration is missing from vernissage.yml.")
    }

    @Test
    func `Services command parses configuration after subcommand`() throws {
        let parsed = try VernissageCommand.parseAsRoot([
            "services", "--config", "/srv/vernissage/vernissage.yml", "--no-color"
        ])
        let command = try #require(parsed as? ServicesCommand)

        #expect(command.configurationOptions.configPath == "/srv/vernissage/vernissage.yml")
        #expect(command.noColor)
    }

    @Test
    func `Services command parses global configuration before subcommand`() throws {
        let parsed = try VernissageCommand.parseAsRoot([
            "--config", "/srv/vernissage/vernissage.yml", "services"
        ])
        let command = try #require(parsed as? ServicesCommand)

        #expect(command.configurationOptions.configPath == "/srv/vernissage/vernissage.yml")
    }

    private func service(
        named name: String,
        in services: [ServiceDescription]
    ) throws -> ServiceDescription {
        try #require(services.first { $0.name == name })
    }

    private func makeContext() -> InstallationContext {
        let context = InstallationContext(instanceIdentifier: "abcdefgh")
        context.summaryFilePath = "/srv/vernissage/vernissage.yml"
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
        context.redis = RedisConfiguration(
            mode: .localContainer,
            url: Secret(value: "redis://default:redis-secret@vernissage-abcdefgh-redis:6379/0"),
            username: "default",
            host: "vernissage-abcdefgh-redis",
            port: 6379,
            database: 0,
            password: Secret(value: "redis-secret"),
            usesTLS: false,
            localResources: LocalRedisResources(
                image: "redis:8",
                containerName: "vernissage-abcdefgh-redis",
                volumeName: "vernissage-abcdefgh-redis-data",
                networkName: "vernissage-abcdefgh-network"
            )
        )
        context.storage = StorageConfiguration(
            provider: .localMinIO,
            address: "http://vernissage-abcdefgh-minio:9000",
            region: nil,
            bucket: "vernissage",
            accessKeyId: "minio",
            secretAccessKey: Secret(value: "storage-secret"),
            http1OnlyMode: false,
            localResources: LocalMinIOResources(
                image: "minio:latest",
                containerName: "vernissage-abcdefgh-minio",
                volumeName: "vernissage-abcdefgh-minio-data",
                networkName: "vernissage-abcdefgh-network"
            )
        )
        context.serverServices = ServerServicesConfiguration(
            image: "mczachurski/vernissage-server:latest",
            networkName: "vernissage-abcdefgh-network",
            apiContainerName: "vernissage-abcdefgh-api",
            jobsContainerName: "vernissage-abcdefgh-jobs",
            apiNetworkAlias: "vernissage-api.internal",
            jobsNetworkAlias: "vernissage-jobs.internal",
            baseAddress: "https://social.example.com",
            apiHealth: nil,
            jobsHealth: nil,
            databaseTables: nil
        )
        context.web = WebConfiguration(
            image: "mczachurski/vernissage-web:latest",
            containerName: "vernissage-abcdefgh-web",
            networkName: "vernissage-abcdefgh-network",
            networkAlias: "vernissage-web.internal",
            allowedHosts: "social.example.com,*.social.example.com",
            cspImageSource: nil
        )
        context.push = PushConfiguration(
            image: "mczachurski/vernissage-push:latest",
            containerName: "vernissage-abcdefgh-push",
            networkName: "vernissage-abcdefgh-network",
            networkAlias: "vernissage-push.internal",
            endpoint: "http://vernissage-push.internal:3000/send",
            secretKey: Secret(value: "push-secret"),
            isEnabled: false
        )
        context.proxy = makeProxy(hostPort: nil)
        context.publicAccess = PublicAccessConfiguration(httpsMode: .development)
        context.caddy = CaddyConfiguration(
            image: "caddy:latest",
            containerName: "vernissage-abcdefgh-caddy",
            networkName: "vernissage-abcdefgh-network",
            networkAlias: "vernissage-caddy.internal",
            dataVolumeName: "vernissage-abcdefgh-caddy-data",
            configVolumeName: "vernissage-abcdefgh-caddy-config",
            caddyfilePath: "/srv/vernissage/caddy/Caddyfile",
            publicHTTPSAddress: "https://social.example.com",
            localRootCertificatePath: "/srv/vernissage/caddy/root.crt"
        )
        return context
    }

    private func makeProxy(hostPort: UInt16?) -> ProxyConfiguration {
        ProxyConfiguration(
            image: "vernissage-proxy:abcdefgh",
            containerName: "vernissage-abcdefgh-proxy",
            networkName: "vernissage-abcdefgh-network",
            networkAlias: "vernissage-proxy.internal",
            hostPort: hostPort,
            containerPort: 8080,
            apiUpstream: "vernissage-api.internal:8080",
            webUpstream: "vernissage-web.internal:8080",
            publicHTTPAddress: hostPort.map { "http://social.example.com:\($0)" },
            buildContextPath: "/srv/vernissage/proxy"
        )
    }
}

private final class ServicesOutputBuffer {
    private(set) var text = ""

    func append(_ value: String) {
        text += value
    }
}
