import Foundation
import Testing
@testable import VernissageCore

struct StatusCommandTests {
    @Test
    func `Inventory contains every container managed by installer`() throws {
        let context = makeContext(localDependencies: true, managedHTTPS: true)

        let containers = try ManagedContainerInventory().containers(from: context)

        #expect(containers == [
            ManagedContainer(
                service: "PostgreSQL",
                name: "vernissage-abcdefgh-postgres",
                expectedImage: "postgres:18"
            ),
            ManagedContainer(
                service: "Redis",
                name: "vernissage-abcdefgh-redis",
                expectedImage: "redis:8"
            ),
            ManagedContainer(
                service: "MinIO",
                name: "vernissage-abcdefgh-minio",
                expectedImage: "minio/minio:latest",
                imageUpdateSource: .localBuild
            ),
            ManagedContainer(
                service: "API",
                name: "vernissage-abcdefgh-api",
                expectedImage: "mczachurski/vernissage-server:latest"
            ),
            ManagedContainer(
                service: "Jobs",
                name: "vernissage-abcdefgh-jobs",
                expectedImage: "mczachurski/vernissage-server:latest"
            ),
            ManagedContainer(
                service: "Web",
                name: "vernissage-abcdefgh-web",
                expectedImage: "mczachurski/vernissage-web:latest"
            ),
            ManagedContainer(
                service: "Push",
                name: "vernissage-abcdefgh-push",
                expectedImage: "mczachurski/vernissage-push:latest"
            ),
            ManagedContainer(
                service: "Proxy",
                name: "vernissage-abcdefgh-proxy",
                expectedImage: "vernissage-proxy:abcdefgh",
                imageUpdateSource: .localBuild
            ),
            ManagedContainer(
                service: "HTTPS",
                name: "vernissage-abcdefgh-caddy",
                expectedImage: "caddy:latest"
            )
        ])
    }

    @Test
    func `External dependencies and manually managed HTTPS are excluded from container inventory`() throws {
        let context = makeContext(localDependencies: false, managedHTTPS: false)

        let containers = try ManagedContainerInventory().containers(from: context)

        #expect(containers.map(\.service) == ["API", "Jobs", "Web", "Push", "Proxy"])
    }

    @Test
    func `Docker inspection is converted into ordered container statuses`() throws {
        let containers = [
            ManagedContainer(service: "API", name: "vernissage-abcdefgh-api", expectedImage: "server:latest"),
            ManagedContainer(service: "Web", name: "vernissage-abcdefgh-web", expectedImage: "web:latest"),
            ManagedContainer(service: "Push", name: "vernissage-abcdefgh-push", expectedImage: "push:latest")
        ]
        let runner = StatusCommandRunner(results: [
            .success("vernissage-abcdefgh-web\nvernissage-abcdefgh-api\nunrelated-container"),
            .success(inspectResponse)
        ])
        let now = try #require(
            ISO8601DateFormatter().date(from: "2026-08-08T12:00:00Z")
        )
        let reader = DockerContainerStatusReader(
            commandRunner: runner,
            now: { now }
        )

        let statuses = try reader.read(containers: containers)

        #expect(statuses.count == 3)
        let api = statuses[0]
        #expect(api.service == "API")
        #expect(api.container == "vernissage-abcdefgh-api")
        #expect(api.state == "running")
        #expect(api.health == "healthy")
        #expect(api.image == "mczachurski/vernissage-server:latest")
        #expect(api.digest == "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        #expect(api.ports == ["*:8080→8080/tcp", "127.0.0.1:9090→9090/tcp"])
        let apiUptime = try #require(api.uptime)
        #expect(abs(apiUptime - 93_784.877) < 0.001)
        #expect(statuses[1] == ContainerStatus(
            service: "Web",
            container: "vernissage-abcdefgh-web",
            state: "exited",
            health: "not configured",
            image: "mczachurski/vernissage-web:latest",
            digest: "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            ports: ["8080/tcp"],
            uptime: nil
        ))
        #expect(statuses[2] == .missing(containers[2]))
        #expect(runner.invocations == [
            StatusDockerInvocation(
                executable: "docker",
                arguments: ["container", "ls", "--all", "--format", "{{.Names}}"]
            ),
            StatusDockerInvocation(
                executable: "docker",
                arguments: [
                    "container", "inspect",
                    "vernissage-abcdefgh-api", "vernissage-abcdefgh-web"
                ]
            )
        ])
    }

    @Test
    func `Missing containers are reported without an inspect command`() throws {
        let container = ManagedContainer(
            service: "API",
            name: "vernissage-abcdefgh-api",
            expectedImage: "server:latest"
        )
        let runner = StatusCommandRunner(results: [.success("")])

        let statuses = try DockerContainerStatusReader(
            commandRunner: runner
        ).read(containers: [container])

        #expect(statuses == [.missing(container)])
        #expect(runner.invocations.count == 1)
    }

    @Test
    func `Unavailable Docker daemon produces actionable error`() {
        let runner = StatusCommandRunner(results: [
            CommandResult(
                exitCode: 1,
                standardOutput: "",
                standardError: "Cannot connect to the Docker daemon"
            )
        ])

        let error = #expect(throws: DockerContainerStatusError.self) {
            try DockerContainerStatusReader(commandRunner: runner).read(containers: [])
        }

        #expect(error == .unavailable("Cannot connect to the Docker daemon"))
        #expect(error?.localizedDescription.contains("Verify that Docker is installed") == true)
    }

    @Test
    func `Malformed Docker inspection response is rejected`() {
        let runner = StatusCommandRunner(results: [
            .success("vernissage-abcdefgh-api"),
            .success("not-json")
        ])
        let container = ManagedContainer(
            service: "API",
            name: "vernissage-abcdefgh-api",
            expectedImage: "server:latest"
        )

        #expect(throws: DockerContainerStatusError.self) {
            try DockerContainerStatusReader(commandRunner: runner).read(containers: [container])
        }
    }

    @Test
    func `Status report contains concise runtime fields and shortened digest`() {
        let context = makeContext(localDependencies: false, managedHTTPS: false)
        let output = StatusOutputBuffer()
        let renderer = StatusReportRenderer(
            console: Console(
                colorsEnabled: false,
                readInput: { nil },
                writeOutput: output.append
            )
        )
        let status = ContainerStatus(
            service: "API",
            container: "vernissage-abcdefgh-api",
            state: "running",
            health: "healthy",
            image: "mczachurski/vernissage-server:latest",
            digest: "sha256:1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef",
            ports: ["*:8080→8080/tcp"],
            uptime: 90_061
        )

        renderer.render(context: context, statuses: [status])

        #expect(output.text.contains("◆ Vernissage container status"))
        #expect(output.text.contains("Instance: abcdefgh"))
        #expect(output.text.contains("Configuration: /srv/vernissage/vernissage.yml"))
        #expect(output.text.contains("CONTAINER"))
        #expect(output.text.contains("STATE"))
        #expect(output.text.contains("HEALTH") == false)
        #expect(output.text.contains("IMAGE") == false)
        #expect(output.text.contains("DIGEST"))
        #expect(output.text.contains("PORTS"))
        #expect(output.text.contains("UPTIME"))
        #expect(output.text.contains("sha256:1234567890ab"))
        #expect(output.text.contains("1d 1h"))
        #expect(output.text.contains("database-secret") == false)
        #expect(output.text.contains("\u{001B}[") == false)
    }

    @Test
    func `Status report colors running green and exited red`() {
        let context = makeContext(
            localDependencies: false,
            managedHTTPS: false
        )
        let output = StatusOutputBuffer()
        let renderer = StatusReportRenderer(
            console: Console(
                colorsEnabled: true,
                readInput: { nil },
                writeOutput: output.append
            )
        )
        let statuses = [
            ContainerStatus(
                service: "API",
                container: "vernissage-abcdefgh-api",
                state: "running",
                health: "healthy",
                image: "server:latest",
                digest: nil,
                ports: [],
                uptime: 1
            ),
            ContainerStatus(
                service: "Web",
                container: "vernissage-abcdefgh-web",
                state: "exited",
                health: "not configured",
                image: "web:latest",
                digest: nil,
                ports: [],
                uptime: nil
            ),
            ContainerStatus.missing(
                ManagedContainer(
                    service: "Push",
                    name: "vernissage-abcdefgh-push",
                    expectedImage: "push:latest"
                )
            )
        ]

        renderer.render(context: context, statuses: statuses)

        #expect(output.text.contains("\u{001B}[32mrunning\u{001B}[0m"))
        #expect(output.text.contains("\u{001B}[31mexited \u{001B}[0m"))
        #expect(output.text.contains("\u{001B}[31mmissing") == false)
    }

    @Test(
        arguments: [
            (nil, "—"),
            (TimeInterval(0), "0s"),
            (TimeInterval(42), "42s"),
            (TimeInterval(125), "2m 5s"),
            (TimeInterval(7_500), "2h 5m"),
            (TimeInterval(183_600), "2d 3h")
        ]
    )
    func `Uptime is formatted for human-readable output`(
        uptime: TimeInterval?,
        expected: String
    ) {
        #expect(UptimeFormatter().string(from: uptime) == expected)
    }

    @Test
    func `Status command parses shared configuration and color option`() throws {
        let parsed = try VernissageCommand.parseAsRoot([
            "--config", "/srv/vernissage/vernissage.yml", "status", "--no-color"
        ])
        let command = try #require(parsed as? StatusCommand)

        #expect(command.configurationOptions.configPath == "/srv/vernissage/vernissage.yml")
        #expect(command.noColor)
    }

    private var inspectResponse: String {
        #"""
        [
          {
            "Name": "/vernissage-abcdefgh-api",
            "Image": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "Config": {
              "Image": "mczachurski/vernissage-server:latest"
            },
            "State": {
              "Status": "running",
              "Running": true,
              "StartedAt": "2026-08-07T09:56:55.123456789Z",
              "Health": {
                "Status": "healthy"
              }
            },
            "NetworkSettings": {
              "Ports": {
                "8080/tcp": [
                  { "HostIp": "0.0.0.0", "HostPort": "8080" },
                  { "HostIp": "::", "HostPort": "8080" }
                ],
                "9090/tcp": [
                  { "HostIp": "127.0.0.1", "HostPort": "9090" }
                ]
              }
            }
          },
          {
            "Name": "/vernissage-abcdefgh-web",
            "Image": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            "Config": {
              "Image": "mczachurski/vernissage-web:latest"
            },
            "State": {
              "Status": "exited",
              "Running": false,
              "StartedAt": "2026-08-07T10:00:00Z"
            },
            "NetworkSettings": {
              "Ports": {
                "8080/tcp": null
              }
            }
          }
        ]
        """#
    }

    private func makeContext(
        localDependencies: Bool,
        managedHTTPS: Bool
    ) -> InstallationContext {
        let context = InstallationContext(instanceIdentifier: "abcdefgh")
        context.summaryFilePath = "/srv/vernissage/vernissage.yml"
        context.database = DatabaseConfiguration(
            mode: localDependencies ? .localContainer : .existing,
            host: localDependencies ? "vernissage-abcdefgh-postgres" : "postgres.example.com",
            port: 5432,
            database: "vernissage",
            username: "vernissage",
            password: Secret(value: "database-secret"),
            tlsMode: localDependencies ? .disable : .require,
            localResources: localDependencies ? LocalPostgreSQLResources(
                image: "postgres:18",
                containerName: "vernissage-abcdefgh-postgres",
                volumeName: "vernissage-abcdefgh-postgres-data",
                networkName: "vernissage-abcdefgh-network"
            ) : nil
        )
        context.redis = RedisConfiguration(
            mode: localDependencies ? .localContainer : .existing,
            url: Secret(value: "redis://default:redis-secret@redis.example.com:6379/0"),
            username: "default",
            host: "redis.example.com",
            port: 6379,
            database: 0,
            password: Secret(value: "redis-secret"),
            usesTLS: false,
            localResources: localDependencies ? LocalRedisResources(
                image: "redis:8",
                containerName: "vernissage-abcdefgh-redis",
                volumeName: "vernissage-abcdefgh-redis-data",
                networkName: "vernissage-abcdefgh-network"
            ) : nil
        )
        context.storage = StorageConfiguration(
            provider: localDependencies ? .localMinIO : .awsS3,
            address: "https://s3.eu-central-1.amazonaws.com",
            region: "eu-central-1",
            bucket: "vernissage",
            accessKeyId: "access-key",
            secretAccessKey: Secret(value: "storage-secret"),
            http1OnlyMode: true,
            localResources: localDependencies ? LocalMinIOResources(
                image: "minio/minio:latest",
                containerName: "vernissage-abcdefgh-minio",
                volumeName: "vernissage-abcdefgh-minio-data",
                networkName: "vernissage-abcdefgh-network"
            ) : nil
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
            buildContextPath: "/srv/vernissage/proxy"
        )
        context.publicAccess = PublicAccessConfiguration(
            httpsMode: managedHTTPS ? .development : .manual
        )
        context.caddy = managedHTTPS ? CaddyConfiguration(
            image: "caddy:latest",
            containerName: "vernissage-abcdefgh-caddy",
            networkName: "vernissage-abcdefgh-network",
            networkAlias: "vernissage-caddy.internal",
            dataVolumeName: "vernissage-abcdefgh-caddy-data",
            configVolumeName: "vernissage-abcdefgh-caddy-config",
            caddyfilePath: "/srv/vernissage/caddy/Caddyfile",
            publicHTTPSAddress: "https://social.example.com",
            localRootCertificatePath: "/srv/vernissage/caddy/root.crt"
        ) : nil
        return context
    }
}

private struct StatusDockerInvocation: Equatable {
    let executable: String
    let arguments: [String]
}

private enum StatusCommandRunnerError: Error {
    case resultNotConfigured
}

private final class StatusCommandRunner: CommandRunning {
    private var results: [CommandResult]
    private(set) var invocations: [StatusDockerInvocation] = []

    init(results: [CommandResult]) {
        self.results = results
    }

    func run(
        _ executable: String,
        arguments: [String],
        environment: [String: String],
        standardInput: String?
    ) throws -> CommandResult {
        invocations.append(
            StatusDockerInvocation(executable: executable, arguments: arguments)
        )
        guard results.isEmpty == false else {
            throw StatusCommandRunnerError.resultNotConfigured
        }
        return results.removeFirst()
    }
}

private final class StatusOutputBuffer {
    private(set) var text = ""

    func append(_ value: String) {
        text += value
    }
}

private extension CommandResult {
    static func success(_ output: String) -> CommandResult {
        CommandResult(exitCode: 0, standardOutput: output, standardError: "")
    }
}
