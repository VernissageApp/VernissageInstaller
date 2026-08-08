import ArgumentParser
import Foundation

public struct StatusCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show the runtime status of installer-managed containers."
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
            let containers = try ManagedContainerInventory().containers(from: context)
            let statuses = try DockerContainerStatusReader(
                commandRunner: ProcessCommandRunner()
            ).read(containers: containers)
            StatusReportRenderer(
                console: .live(colorsEnabled: noColor == false)
            ).render(context: context, statuses: statuses)
        } catch {
            throw ValidationError(error.localizedDescription)
        }
    }
}

struct ManagedContainer: Equatable {
    enum ImageUpdateSource: Equatable {
        case registry
        case localBuild
    }

    let service: String
    let name: String
    let expectedImage: String
    let imageUpdateSource: ImageUpdateSource

    init(
        service: String,
        name: String,
        expectedImage: String,
        imageUpdateSource: ImageUpdateSource = .registry
    ) {
        self.service = service
        self.name = name
        self.expectedImage = expectedImage
        self.imageUpdateSource = imageUpdateSource
    }
}

struct ManagedContainerInventory {
    func containers(from context: InstallationContext) throws -> [ManagedContainer] {
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

        var containers: [ManagedContainer] = []

        if let resources = database.localResources {
            containers.append(
                ManagedContainer(
                    service: "PostgreSQL",
                    name: resources.containerName,
                    expectedImage: resources.image
                )
            )
        }
        if let resources = redis.localResources {
            containers.append(
                ManagedContainer(
                    service: "Redis",
                    name: resources.containerName,
                    expectedImage: resources.image
                )
            )
        }
        if let resources = storage.localResources {
            containers.append(
                ManagedContainer(
                    service: "MinIO",
                    name: resources.containerName,
                    expectedImage: resources.image,
                    imageUpdateSource: .localBuild
                )
            )
        }

        containers.append(contentsOf: [
            ManagedContainer(
                service: "API",
                name: serverServices.apiContainerName,
                expectedImage: serverServices.image
            ),
            ManagedContainer(
                service: "Jobs",
                name: serverServices.jobsContainerName,
                expectedImage: serverServices.image
            ),
            ManagedContainer(
                service: "Web",
                name: web.containerName,
                expectedImage: web.image
            ),
            ManagedContainer(
                service: "Push",
                name: push.containerName,
                expectedImage: push.image
            ),
            ManagedContainer(
                service: "Proxy",
                name: proxy.containerName,
                expectedImage: proxy.image,
                imageUpdateSource: .localBuild
            )
        ])

        switch publicAccess.httpsMode {
        case .development, .production:
            guard let caddy = context.caddy else {
                throw ServicesInventoryError.missingConfiguration("Caddy")
            }
            containers.append(
                ManagedContainer(
                    service: "HTTPS",
                    name: caddy.containerName,
                    expectedImage: caddy.image
                )
            )
        case .manual:
            break
        }

        return containers
    }
}

struct ContainerStatus: Equatable {
    let service: String
    let container: String
    let state: String
    let health: String
    let image: String
    let digest: String?
    let ports: [String]
    let uptime: TimeInterval?

    static func missing(_ container: ManagedContainer) -> ContainerStatus {
        ContainerStatus(
            service: container.service,
            container: container.name,
            state: "missing",
            health: "—",
            image: container.expectedImage,
            digest: nil,
            ports: [],
            uptime: nil
        )
    }
}

enum DockerContainerStatusError: LocalizedError, Equatable {
    case unavailable(String)
    case inspectionFailed(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let details):
            return "Docker container status could not be read. Verify that Docker is installed and its daemon is running. Details: \(details)"
        case .inspectionFailed(let details):
            return "Docker could not inspect the Vernissage containers. Details: \(details)"
        case .invalidResponse(let details):
            return "Docker returned an invalid container inspection response. Details: \(details)"
        }
    }
}

struct DockerContainerStatusReader {
    private let commandRunner: any CommandRunning
    private let now: () -> Date

    init(
        commandRunner: any CommandRunning,
        now: @escaping () -> Date = Date.init
    ) {
        self.commandRunner = commandRunner
        self.now = now
    }

    func read(containers: [ManagedContainer]) throws -> [ContainerStatus] {
        let listResult: CommandResult
        do {
            listResult = try commandRunner.run(
                "docker",
                arguments: ["container", "ls", "--all", "--format", "{{.Names}}"]
            )
        } catch {
            throw DockerContainerStatusError.unavailable(error.localizedDescription)
        }
        guard listResult.succeeded else {
            throw DockerContainerStatusError.unavailable(
                commandFailureDetails(listResult)
            )
        }

        let existingNames = Set(
            listResult.standardOutput
                .split(whereSeparator: \Character.isNewline)
                .map(String.init)
        )
        let existingContainers = containers.filter { existingNames.contains($0.name) }
        guard existingContainers.isEmpty == false else {
            return containers.map(ContainerStatus.missing)
        }

        let inspectResult: CommandResult
        do {
            inspectResult = try commandRunner.run(
                "docker",
                arguments: ["container", "inspect"] + existingContainers.map(\.name)
            )
        } catch {
            throw DockerContainerStatusError.inspectionFailed(error.localizedDescription)
        }
        guard inspectResult.succeeded else {
            throw DockerContainerStatusError.inspectionFailed(
                commandFailureDetails(inspectResult)
            )
        }

        let documents: [DockerContainerInspection]
        do {
            documents = try JSONDecoder().decode(
                [DockerContainerInspection].self,
                from: Data(inspectResult.standardOutput.utf8)
            )
        } catch {
            throw DockerContainerStatusError.invalidResponse(error.localizedDescription)
        }

        let documentsByName = Dictionary(
            uniqueKeysWithValues: documents.map {
                ($0.name.removingLeadingSlash(), $0)
            }
        )
        let currentDate = now()

        return containers.map { container in
            guard let document = documentsByName[container.name] else {
                return .missing(container)
            }
            return status(
                container: container,
                inspection: document,
                now: currentDate
            )
        }
    }

    private func status(
        container: ManagedContainer,
        inspection: DockerContainerInspection,
        now: Date
    ) -> ContainerStatus {
        let uptime: TimeInterval?
        if inspection.state.running,
           let startedAt = DockerDateParser().date(from: inspection.state.startedAt) {
            uptime = max(0, now.timeIntervalSince(startedAt))
        } else {
            uptime = nil
        }

        return ContainerStatus(
            service: container.service,
            container: container.name,
            state: inspection.state.status,
            health: inspection.state.health?.status ?? "not configured",
            image: inspection.configuration.image,
            digest: inspection.image,
            ports: DockerPortFormatter().ports(inspection.networkSettings.ports),
            uptime: uptime
        )
    }

    private func commandFailureDetails(_ result: CommandResult) -> String {
        if result.standardError.isEmpty == false {
            return result.standardError
        }
        if result.standardOutput.isEmpty == false {
            return result.standardOutput
        }
        return "docker exited with code \(result.exitCode)"
    }
}

private struct DockerContainerInspection: Decodable {
    let name: String
    let image: String
    let configuration: Configuration
    let state: State
    let networkSettings: NetworkSettings

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case image = "Image"
        case configuration = "Config"
        case state = "State"
        case networkSettings = "NetworkSettings"
    }

    struct Configuration: Decodable {
        let image: String

        enum CodingKeys: String, CodingKey {
            case image = "Image"
        }
    }

    struct State: Decodable {
        let status: String
        let running: Bool
        let startedAt: String
        let health: Health?

        enum CodingKeys: String, CodingKey {
            case status = "Status"
            case running = "Running"
            case startedAt = "StartedAt"
            case health = "Health"
        }
    }

    struct Health: Decodable {
        let status: String

        enum CodingKeys: String, CodingKey {
            case status = "Status"
        }
    }

    struct NetworkSettings: Decodable {
        let ports: [String: [PortBinding]?]

        enum CodingKeys: String, CodingKey {
            case ports = "Ports"
        }
    }

    struct PortBinding: Decodable {
        let hostIP: String
        let hostPort: String

        enum CodingKeys: String, CodingKey {
            case hostIP = "HostIp"
            case hostPort = "HostPort"
        }
    }
}

private struct DockerDateParser {
    func date(from value: String) -> Date? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: value) {
            return date
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

private struct DockerPortFormatter {
    func ports(
        _ ports: [String: [DockerContainerInspection.PortBinding]?]
    ) -> [String] {
        var values = Set<String>()

        for containerPort in ports.keys.sorted() {
            guard let bindings = ports[containerPort] ?? nil,
                  bindings.isEmpty == false else {
                values.insert(containerPort)
                continue
            }

            for binding in bindings {
                let host = wildcardHost(binding.hostIP)
                values.insert("\(host):\(binding.hostPort)→\(containerPort)")
            }
        }

        return values.sorted()
    }

    private func wildcardHost(_ host: String) -> String {
        switch host {
        case "", "0.0.0.0", "::":
            return "*"
        default:
            if host.contains(":") {
                return "[\(host)]"
            }
            return host
        }
    }
}

struct StatusReportRenderer {
    private let console: Console

    init(console: Console) {
        self.console = console
    }

    func render(
        context: InstallationContext,
        statuses: [ContainerStatus]
    ) {
        console.section("Vernissage container status")
        console.value(label: "Instance", value: context.instanceIdentifier)
        if let summaryFilePath = context.summaryFilePath {
            console.value(label: "Configuration", value: summaryFilePath)
        }
        console.line("")

        let rows = statuses.map {
            [
                $0.service,
                $0.container,
                $0.state,
                shortDigest($0.digest),
                $0.ports.isEmpty ? "—" : $0.ports.joined(separator: ", "),
                UptimeFormatter().string(from: $0.uptime)
            ]
        }
        renderTable(
            headers: [
                "SERVICE", "CONTAINER", "STATE", "DIGEST", "PORTS", "UPTIME"
            ],
            rows: rows
        )
        console.line("")
        console.info("DIGEST shows the shortened immutable image identifier used by the container.")
    }

    private func shortDigest(_ digest: String?) -> String {
        guard let digest, digest.isEmpty == false else {
            return "—"
        }
        if digest.hasPrefix("sha256:") {
            return "sha256:" + digest.dropFirst("sha256:".count).prefix(12)
        }
        return String(digest.prefix(19))
    }

    private func renderTable(headers: [String], rows: [[String]]) {
        let widths = headers.indices.map { index in
            ([headers[index]] + rows.map { $0[index] }).map(\.count).max() ?? 0
        }
        console.line(tableLine(headers, widths: widths))
        console.line(tableLine(widths.map { String(repeating: "-", count: $0) }, widths: widths))
        for row in rows {
            console.line(tableLine(row, widths: widths, stateColumn: 2))
        }
    }

    private func tableLine(
        _ values: [String],
        widths: [Int],
        stateColumn: Int? = nil
    ) -> String {
        values.indices.map { index in
            let value = values[index].padding(
                toLength: widths[index],
                withPad: " ",
                startingAt: 0
            )
            guard index == stateColumn else {
                return value
            }
            return console.coloredContainerState(
                value,
                state: values[index]
            )
        }.joined(separator: "  ")
    }
}

struct UptimeFormatter {
    func string(from uptime: TimeInterval?) -> String {
        guard let uptime else {
            return "—"
        }

        let seconds = max(0, Int(uptime.rounded(.down)))
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainingSeconds = seconds % 60

        if days > 0 {
            return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
        }
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        if minutes > 0 {
            return remainingSeconds > 0 ? "\(minutes)m \(remainingSeconds)s" : "\(minutes)m"
        }
        return "\(remainingSeconds)s"
    }
}

private extension String {
    func removingLeadingSlash() -> String {
        guard first == "/" else {
            return self
        }
        return String(dropFirst())
    }
}
