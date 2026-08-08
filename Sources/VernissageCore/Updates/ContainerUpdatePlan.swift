import ArgumentParser
import Foundation

enum UpdateComponent: String, CaseIterable, ExpressibleByArgument {
    case server
    case web
    case push
    case proxy
    case caddy
    case redis
    case postgres
    case minio
}

struct UpdateFile: Equatable {
    let path: String
    let contents: String
}

struct UpdateDockerCommand: Equatable {
    let arguments: [String]
    let environment: [String: String]
    let standardInput: String?
    let description: String

    init(
        arguments: [String],
        environment: [String: String] = [:],
        standardInput: String? = nil,
        description: String
    ) {
        self.arguments = arguments
        self.environment = environment
        self.standardInput = standardInput
        self.description = description
    }
}

struct ContainerReplacementSpecification: Equatable {
    let service: String
    let name: String
    let createArguments: [String]
    let environment: [String: String]
}

struct ContainerUpdatePlan: Equatable {
    let component: UpdateComponent
    let image: String
    let files: [UpdateFile]
    let preparationCommands: [UpdateDockerCommand]
    let containers: [ContainerReplacementSpecification]
}

enum ContainerUpdatePlanError: LocalizedError, Equatable {
    case missingConfiguration(String)
    case componentNotManaged(UpdateComponent)
    case invalidConfiguration(String)

    var errorDescription: String? {
        switch self {
        case .missingConfiguration(let name):
            return "The \(name) configuration is missing from vernissage.yml."
        case .componentNotManaged(let component):
            return "The '\(component.rawValue)' component is not managed by this Vernissage installation."
        case .invalidConfiguration(let name):
            return "The installer could not reconstruct a valid \(name) configuration from vernissage.yml."
        }
    }
}

struct ContainerUpdatePlanFactory {
    private let operatingSystem: HostOperatingSystem

    init(operatingSystem: HostOperatingSystem) {
        self.operatingSystem = operatingSystem
    }

    func plan(
        for component: UpdateComponent,
        context: InstallationContext
    ) throws -> ContainerUpdatePlan {
        switch component {
        case .server:
            return try serverPlan(context)
        case .web:
            return try webPlan(context)
        case .push:
            return try pushPlan(context)
        case .proxy:
            return try proxyPlan(context)
        case .caddy:
            return try caddyPlan(context)
        case .redis:
            return try redisPlan(context)
        case .postgres:
            return try postgresPlan(context)
        case .minio:
            return try minIOPlan(context)
        }
    }

    private func serverPlan(_ context: InstallationContext) throws -> ContainerUpdatePlan {
        guard let server = context.server else {
            throw ContainerUpdatePlanError.missingConfiguration("server and domain")
        }
        guard let database = context.database else {
            throw ContainerUpdatePlanError.missingConfiguration("PostgreSQL")
        }
        guard let redis = context.redis else {
            throw ContainerUpdatePlanError.missingConfiguration("Redis")
        }
        guard let storage = context.storage else {
            throw ContainerUpdatePlanError.missingConfiguration("S3 storage")
        }
        guard let services = context.serverServices else {
            throw ContainerUpdatePlanError.missingConfiguration("API and Jobs")
        }

        let connectionString = try postgresURL(database)
        let queueURL = try redisURL(redis)
        let storageAddress = try storageURL(storage.address)
        let sharedEnvironment = [
            "VERNISSAGE_BASEADDRESS": "https://\(server.domain)",
            "VERNISSAGE_CONNECTIONSTRING": connectionString,
            "VERNISSAGE_QUEUEURL": queueURL,
            "VERNISSAGE_S3ADDRESS": storageAddress,
            "VERNISSAGE_S3REGION": storage.region ?? "",
            "VERNISSAGE_S3BUCKET": storage.bucket,
            "VERNISSAGE_S3ACCESSKEYID": storage.accessKeyId,
            "VERNISSAGE_S3SECRETACCESSKEY": storage.secretAccessKey.value,
            "VERNISSAGE_S3HTTP1ONLYMODE": String(storage.http1OnlyMode)
        ]
        let apiEnvironment = serverEnvironment(
            sharedEnvironment,
            disableQueueJobs: true,
            disableScheduledJobs: true
        )
        let jobsEnvironment = serverEnvironment(
            sharedEnvironment,
            disableQueueJobs: false,
            disableScheduledJobs: false
        )

        return ContainerUpdatePlan(
            component: .server,
            image: services.image,
            files: [],
            preparationCommands: [pullCommand(services.image)],
            containers: [
                serverContainer(
                    service: "API",
                    name: services.apiContainerName,
                    networkName: services.networkName,
                    networkAlias: services.apiNetworkAlias,
                    image: services.image,
                    environment: apiEnvironment
                ),
                serverContainer(
                    service: "Jobs",
                    name: services.jobsContainerName,
                    networkName: services.networkName,
                    networkAlias: services.jobsNetworkAlias,
                    image: services.image,
                    environment: jobsEnvironment
                )
            ]
        )
    }

    private func webPlan(_ context: InstallationContext) throws -> ContainerUpdatePlan {
        guard let web = context.web else {
            throw ContainerUpdatePlanError.missingConfiguration("Web")
        }
        var environment = ["VERNISSAGE_ALLOWED_HOSTS": web.allowedHosts]
        if let cspImageSource = web.cspImageSource {
            environment["VERNISSAGE_CSP_IMG"] = cspImageSource
        }

        return ContainerUpdatePlan(
            component: .web,
            image: web.image,
            files: [],
            preparationCommands: [pullCommand(web.image)],
            containers: [
                standardContainer(
                    service: "Web",
                    name: web.containerName,
                    image: web.image,
                    networkName: web.networkName,
                    networkAlias: web.networkAlias,
                    environment: environment
                )
            ]
        )
    }

    private func pushPlan(_ context: InstallationContext) throws -> ContainerUpdatePlan {
        guard let push = context.push else {
            throw ContainerUpdatePlanError.missingConfiguration("Push")
        }
        let environment = ["VPUSH_KEY": push.secretKey.value]

        return ContainerUpdatePlan(
            component: .push,
            image: push.image,
            files: [],
            preparationCommands: [pullCommand(push.image)],
            containers: [
                standardContainer(
                    service: "Push",
                    name: push.containerName,
                    image: push.image,
                    networkName: push.networkName,
                    networkAlias: push.networkAlias,
                    environment: environment
                )
            ]
        )
    }

    private func proxyPlan(_ context: InstallationContext) throws -> ContainerUpdatePlan {
        guard let proxy = context.proxy else {
            throw ContainerUpdatePlanError.missingConfiguration("Proxy")
        }
        let contextURL = URL(fileURLWithPath: proxy.buildContextPath, isDirectory: true)
        let files = [
            UpdateFile(
                path: contextURL.appendingPathComponent("Dockerfile").path,
                contents: ProxyStep.makeDockerfile()
            ),
            UpdateFile(
                path: contextURL.appendingPathComponent("nginx.conf").path,
                contents: ProxyStep.makeNginxConfiguration(
                    apiUpstream: proxy.apiUpstream,
                    webUpstream: proxy.webUpstream,
                    minIOUpstream: context.storage?.localResources.map {
                        "\($0.containerName):9000"
                    }
                )
            )
        ]
        var createArguments = baseCreateArguments(
            name: proxy.containerName,
            networkName: proxy.networkName,
            networkAlias: proxy.networkAlias
        )
        if let hostPort = proxy.hostPort {
            createArguments += ["--publish", "\(hostPort):\(proxy.containerPort)"]
        }
        createArguments.append(proxy.image)

        return ContainerUpdatePlan(
            component: .proxy,
            image: proxy.image,
            files: files,
            preparationCommands: [
                UpdateDockerCommand(
                    arguments: [
                        "image", "build", "--tag", proxy.image,
                        proxy.buildContextPath
                    ],
                    description: "build the Vernissage Proxy image"
                ),
                UpdateDockerCommand(
                    arguments: [
                        "run", "--rm", "--network", proxy.networkName,
                        proxy.image, "nginx", "-t"
                    ],
                    description: "validate the Vernissage Proxy image"
                )
            ],
            containers: [
                ContainerReplacementSpecification(
                    service: "Proxy",
                    name: proxy.containerName,
                    createArguments: createArguments,
                    environment: [:]
                )
            ]
        )
    }

    private func caddyPlan(_ context: InstallationContext) throws -> ContainerUpdatePlan {
        guard let caddy = context.caddy else {
            throw ContainerUpdatePlanError.componentNotManaged(.caddy)
        }
        let configurationDirectory = URL(fileURLWithPath: caddy.caddyfilePath)
            .deletingLastPathComponent().path
        var createArguments = baseCreateArguments(
            name: caddy.containerName,
            networkName: caddy.networkName,
            networkAlias: caddy.networkAlias
        )
        createArguments += [
            "--publish", "80:80",
            "--publish", "443:443",
            "--publish", "443:443/udp",
            "--mount", "type=bind,source=\(configurationDirectory),target=/etc/caddy,readonly",
            "--mount", "type=volume,source=\(caddy.dataVolumeName),target=/data",
            "--mount", "type=volume,source=\(caddy.configVolumeName),target=/config",
            caddy.image
        ]

        return ContainerUpdatePlan(
            component: .caddy,
            image: caddy.image,
            files: [],
            preparationCommands: [pullCommand(caddy.image)],
            containers: [
                ContainerReplacementSpecification(
                    service: "Caddy",
                    name: caddy.containerName,
                    createArguments: createArguments,
                    environment: [:]
                )
            ]
        )
    }

    private func redisPlan(_ context: InstallationContext) throws -> ContainerUpdatePlan {
        guard let redis = context.redis,
              let resources = redis.localResources else {
            throw ContainerUpdatePlanError.componentNotManaged(.redis)
        }
        let createArguments = baseCreateArguments(
            name: resources.containerName,
            networkName: resources.networkName,
            networkAlias: nil
        ) + [
            "--mount", "type=volume,source=\(resources.volumeName),target=/data",
            resources.image,
            "redis-server", "/data/redis.conf"
        ]

        return ContainerUpdatePlan(
            component: .redis,
            image: resources.image,
            files: [],
            preparationCommands: [pullCommand(resources.image)],
            containers: [
                ContainerReplacementSpecification(
                    service: "Redis",
                    name: resources.containerName,
                    createArguments: createArguments,
                    environment: [:]
                )
            ]
        )
    }

    private func postgresPlan(_ context: InstallationContext) throws -> ContainerUpdatePlan {
        guard let database = context.database,
              let resources = database.localResources else {
            throw ContainerUpdatePlanError.componentNotManaged(.postgres)
        }
        let environment = [
            "POSTGRES_DB": database.database,
            "POSTGRES_USER": database.username,
            "POSTGRES_PASSWORD": database.password.value
        ]
        let createArguments = baseCreateArguments(
            name: resources.containerName,
            networkName: resources.networkName,
            networkAlias: nil
        ) + environmentArguments(environment) + [
            "--mount", "type=volume,source=\(resources.volumeName),target=/var/lib/postgresql",
            resources.image
        ]

        return ContainerUpdatePlan(
            component: .postgres,
            image: resources.image,
            files: [],
            preparationCommands: [pullCommand(resources.image)],
            containers: [
                ContainerReplacementSpecification(
                    service: "PostgreSQL",
                    name: resources.containerName,
                    createArguments: createArguments,
                    environment: environment
                )
            ]
        )
    }

    private func minIOPlan(_ context: InstallationContext) throws -> ContainerUpdatePlan {
        guard let storage = context.storage,
              let resources = storage.localResources else {
            throw ContainerUpdatePlanError.componentNotManaged(.minio)
        }
        let environment = [
            "MINIO_ROOT_USER": storage.accessKeyId,
            "MINIO_ROOT_PASSWORD": storage.secretAccessKey.value
        ]
        let createArguments = baseCreateArguments(
            name: resources.containerName,
            networkName: resources.networkName,
            networkAlias: nil
        ) + environmentArguments(environment) + [
            "--mount", "type=volume,source=\(resources.volumeName),target=/data",
            resources.image,
            "server", "/data", "--console-address", ":9001"
        ]

        return ContainerUpdatePlan(
            component: .minio,
            image: resources.image,
            files: [],
            preparationCommands: [
                UpdateDockerCommand(
                    arguments: [
                        "image", "build", "--quiet", "--tag", resources.image, "-"
                    ],
                    standardInput: StorageStep.minIODockerfile,
                    description: "build the local MinIO image"
                )
            ],
            containers: [
                ContainerReplacementSpecification(
                    service: "MinIO",
                    name: resources.containerName,
                    createArguments: createArguments,
                    environment: environment
                )
            ]
        )
    }

    private func serverContainer(
        service: String,
        name: String,
        networkName: String,
        networkAlias: String,
        image: String,
        environment: [String: String]
    ) -> ContainerReplacementSpecification {
        var arguments = baseCreateArguments(
            name: name,
            networkName: networkName,
            networkAlias: networkAlias
        )
        if operatingSystem == .linux {
            arguments += ["--add-host", "host.docker.internal:host-gateway"]
        }
        arguments += environmentArguments(environment)
        arguments += [
            image,
            "serve", "--env", "production",
            "--hostname", "0.0.0.0", "--port", "8080"
        ]
        return ContainerReplacementSpecification(
            service: service,
            name: name,
            createArguments: arguments,
            environment: environment
        )
    }

    private func standardContainer(
        service: String,
        name: String,
        image: String,
        networkName: String,
        networkAlias: String,
        environment: [String: String]
    ) -> ContainerReplacementSpecification {
        ContainerReplacementSpecification(
            service: service,
            name: name,
            createArguments: baseCreateArguments(
                name: name,
                networkName: networkName,
                networkAlias: networkAlias
            ) + environmentArguments(environment) + [image],
            environment: environment
        )
    }

    private func baseCreateArguments(
        name: String,
        networkName: String,
        networkAlias: String?
    ) -> [String] {
        var arguments = [
            "--name", name,
            "--restart", "unless-stopped",
            "--network", networkName
        ]
        if let networkAlias {
            arguments += ["--network-alias", networkAlias]
        }
        return arguments
    }

    private func environmentArguments(_ environment: [String: String]) -> [String] {
        environment.keys.sorted().flatMap { ["--env", $0] }
    }

    private func pullCommand(_ image: String) -> UpdateDockerCommand {
        UpdateDockerCommand(
            arguments: ["image", "pull", image],
            description: "pull \(image)"
        )
    }

    private func serverEnvironment(
        _ shared: [String: String],
        disableQueueJobs: Bool,
        disableScheduledJobs: Bool
    ) -> [String: String] {
        var environment = shared
        environment["VERNISSAGE_DISABLEQUEUEJOBS"] = String(disableQueueJobs)
        environment["VERNISSAGE_DISABLESCHEDULEDJOBS"] = String(disableScheduledJobs)
        return environment
    }

    private func postgresURL(_ configuration: DatabaseConfiguration) throws -> String {
        var components = URLComponents()
        components.scheme = "postgres"
        components.host = containerHost(configuration.host)
        components.port = Int(configuration.port)
        components.user = configuration.username
        components.password = configuration.password.value
        components.path = "/\(configuration.database)"
        components.queryItems = [
            URLQueryItem(name: "tlsmode", value: configuration.tlsMode.rawValue)
        ]
        guard let value = components.string else {
            throw ContainerUpdatePlanError.invalidConfiguration("PostgreSQL connection")
        }
        return value
    }

    private func redisURL(_ configuration: RedisConfiguration) throws -> String {
        guard var components = URLComponents(string: configuration.url.value) else {
            throw ContainerUpdatePlanError.invalidConfiguration("Redis connection")
        }
        components.host = containerHost(configuration.host)
        guard let value = components.string else {
            throw ContainerUpdatePlanError.invalidConfiguration("Redis connection")
        }
        return value
    }

    private func storageURL(_ address: String) throws -> String {
        guard var components = URLComponents(string: address),
              let host = components.host else {
            throw ContainerUpdatePlanError.invalidConfiguration("S3 address")
        }
        components.host = containerHost(host)
        guard let value = components.string else {
            throw ContainerUpdatePlanError.invalidConfiguration("S3 address")
        }
        return value
    }

    private func containerHost(_ host: String) -> String {
        isLoopback(host) ? "host.docker.internal" : host
    }

    private func isLoopback(_ host: String) -> Bool {
        let value = host.lowercased()
        return value == "localhost"
            || value == "localhost."
            || value.hasPrefix("127.")
            || value == "::1"
            || value == "0:0:0:0:0:0:0:1"
    }
}
