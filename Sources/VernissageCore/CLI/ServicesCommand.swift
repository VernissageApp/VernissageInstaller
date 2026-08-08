import ArgumentParser
import Foundation

public struct ServicesCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "services",
        abstract: "List the services used by a Vernissage installation."
    )

    @OptionGroup
    var configurationOptions: ConfigurationOptions

    @Flag(
        name: .long,
        help: "Disable ANSI colors in terminal output."
    )
    var noColor = false

    public init() {}

    public mutating func run() throws {
        do {
            let context = try configurationOptions.loadContext()
            let services = try ServicesInventory().services(from: context)
            ServicesReportRenderer(
                console: .live(colorsEnabled: noColor == false)
            ).render(context: context, services: services)
        } catch {
            throw ValidationError(error.localizedDescription)
        }
    }
}

enum ServiceLocation: String, Equatable {
    case local
    case external
}

struct ServiceDescription: Equatable {
    let name: String
    let location: ServiceLocation
    let isManagedByInstaller: Bool
    let resource: String
}

enum ServicesInventoryError: LocalizedError, Equatable {
    case missingConfiguration(String)

    var errorDescription: String? {
        switch self {
        case .missingConfiguration(let name):
            "The \(name) configuration is missing from vernissage.yml."
        }
    }
}

struct ServicesInventory {
    func services(from context: InstallationContext) throws -> [ServiceDescription] {
        guard let database = context.database else {
            throw ServicesInventoryError.missingConfiguration("PostgreSQL")
        }
        guard let redis = context.redis else {
            throw ServicesInventoryError.missingConfiguration("Redis")
        }
        guard let storage = context.storage else {
            throw ServicesInventoryError.missingConfiguration("S3 storage")
        }
        guard let serverServices = context.serverServices else {
            throw ServicesInventoryError.missingConfiguration("API and Jobs")
        }
        guard let web = context.web else {
            throw ServicesInventoryError.missingConfiguration("Web")
        }
        guard let push = context.push else {
            throw ServicesInventoryError.missingConfiguration("Push")
        }
        guard let proxy = context.proxy else {
            throw ServicesInventoryError.missingConfiguration("Proxy")
        }
        guard let publicAccess = context.publicAccess else {
            throw ServicesInventoryError.missingConfiguration("public access")
        }

        return [
            postgresql(database),
            redisService(redis),
            storageService(storage),
            ServiceDescription(
                name: "API",
                location: .local,
                isManagedByInstaller: true,
                resource: serverServices.apiContainerName
            ),
            ServiceDescription(
                name: "Jobs",
                location: .local,
                isManagedByInstaller: true,
                resource: serverServices.jobsContainerName
            ),
            ServiceDescription(
                name: "Web",
                location: .local,
                isManagedByInstaller: true,
                resource: web.containerName
            ),
            ServiceDescription(
                name: "Push",
                location: .local,
                isManagedByInstaller: true,
                resource: push.containerName
            ),
            ServiceDescription(
                name: "Proxy",
                location: .local,
                isManagedByInstaller: true,
                resource: proxyResource(proxy)
            ),
            try httpsService(
                publicAccess: publicAccess,
                caddy: context.caddy
            )
        ]
    }

    private func postgresql(_ configuration: DatabaseConfiguration) -> ServiceDescription {
        if let resources = configuration.localResources {
            return ServiceDescription(
                name: "PostgreSQL",
                location: .local,
                isManagedByInstaller: true,
                resource: "\(resources.containerName) (volume: \(resources.volumeName))"
            )
        }

        return ServiceDescription(
            name: "PostgreSQL",
            location: location(ofHost: configuration.host),
            isManagedByInstaller: false,
            resource: "\(configuration.host):\(configuration.port)/\(configuration.database)"
        )
    }

    private func redisService(_ configuration: RedisConfiguration) -> ServiceDescription {
        if let resources = configuration.localResources {
            return ServiceDescription(
                name: "Redis",
                location: .local,
                isManagedByInstaller: true,
                resource: "\(resources.containerName) (volume: \(resources.volumeName))"
            )
        }

        return ServiceDescription(
            name: "Redis",
            location: location(ofHost: configuration.host),
            isManagedByInstaller: false,
            resource: "\(configuration.host):\(configuration.port)/\(configuration.database)"
        )
    }

    private func storageService(_ configuration: StorageConfiguration) -> ServiceDescription {
        if let resources = configuration.localResources {
            return ServiceDescription(
                name: "S3 storage",
                location: .local,
                isManagedByInstaller: true,
                resource: "\(resources.containerName) (volume: \(resources.volumeName), bucket: \(configuration.bucket))"
            )
        }

        return ServiceDescription(
            name: "S3 storage",
            location: location(ofAddress: configuration.address),
            isManagedByInstaller: false,
            resource: "\(configuration.address) (bucket: \(configuration.bucket))"
        )
    }

    private func proxyResource(_ configuration: ProxyConfiguration) -> String {
        guard let hostPort = configuration.hostPort else {
            return configuration.containerName
        }
        return "\(configuration.containerName) (host port: \(hostPort))"
    }

    private func httpsService(
        publicAccess: PublicAccessConfiguration,
        caddy: CaddyConfiguration?
    ) throws -> ServiceDescription {
        switch publicAccess.httpsMode {
        case .development, .production:
            guard let caddy else {
                throw ServicesInventoryError.missingConfiguration("Caddy")
            }
            return ServiceDescription(
                name: "HTTPS",
                location: .local,
                isManagedByInstaller: true,
                resource: "\(caddy.containerName) (\(caddy.publicHTTPSAddress))"
            )
        case .manual:
            return ServiceDescription(
                name: "HTTPS",
                location: .external,
                isManagedByInstaller: false,
                resource: "configured outside vernissagectl"
            )
        }
    }

    private func location(ofAddress address: String) -> ServiceLocation {
        guard let host = URLComponents(string: address)?.host else {
            return .external
        }
        return location(ofHost: host)
    }

    private func location(ofHost host: String) -> ServiceLocation {
        let normalizedHost = host.lowercased()
        if normalizedHost == "localhost"
            || normalizedHost == "localhost."
            || normalizedHost.hasPrefix("127.")
            || normalizedHost == "::1"
            || normalizedHost == "0:0:0:0:0:0:0:1" {
            return .local
        }
        return .external
    }
}

struct ServicesReportRenderer {
    private let console: Console

    init(console: Console) {
        self.console = console
    }

    func render(
        context: InstallationContext,
        services: [ServiceDescription]
    ) {
        console.section("Vernissage services")
        console.value(label: "Instance", value: context.instanceIdentifier)
        if let summaryFilePath = context.summaryFilePath {
            console.value(label: "Configuration", value: summaryFilePath)
        }
        console.line("")

        let rows = services.map {
            [
                $0.name,
                $0.location.rawValue,
                $0.isManagedByInstaller ? "yes" : "no",
                $0.resource
            ]
        }
        renderTable(
            headers: ["SERVICE", "LOCATION", "MANAGED", "RESOURCE"],
            rows: rows
        )
        console.line("")
        console.info("MANAGED indicates whether the service was created and is managed by vernissagectl.")
    }

    private func renderTable(headers: [String], rows: [[String]]) {
        let widths = headers.indices.map { index in
            ([headers[index]] + rows.map { $0[index] }).map(\.count).max() ?? 0
        }
        console.line(tableLine(headers, widths: widths))
        console.line(tableLine(widths.map { String(repeating: "-", count: $0) }, widths: widths))
        for row in rows {
            console.line(tableLine(row, widths: widths))
        }
    }

    private func tableLine(_ values: [String], widths: [Int]) -> String {
        values.indices.map { index in
            values[index].padding(
                toLength: widths[index],
                withPad: " ",
                startingAt: 0
            )
        }.joined(separator: "  ")
    }
}
