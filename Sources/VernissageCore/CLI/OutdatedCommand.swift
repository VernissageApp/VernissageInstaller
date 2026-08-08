import ArgumentParser
import Foundation

public struct OutdatedCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "outdated",
        abstract: "Check whether newer container images are available."
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
        let console = Console.live(colorsEnabled: noColor == false)

        do {
            let context = try configurationOptions.loadContext()
            let containers = try ManagedContainerInventory().containers(from: context)
            let commandRunner = ProcessCommandRunner()
            let containerStatuses = try DockerContainerStatusReader(
                commandRunner: commandRunner
            ).read(containers: containers)

            console.pending("Checking image manifests in the container registry…")
            let updates = try DockerRegistryUpdateChecker(
                commandRunner: commandRunner
            ).check(containers: containers, statuses: containerStatuses)
            OutdatedReportRenderer(console: console).render(
                context: context,
                updates: updates
            )
        } catch {
            throw ValidationError(error.localizedDescription)
        }
    }
}

struct DockerPlatform: Equatable {
    let operatingSystem: String
    let architecture: String

    init(operatingSystem: String, architecture: String) {
        self.operatingSystem = operatingSystem.lowercased()
        self.architecture = Self.normalizedArchitecture(architecture)
    }

    private static func normalizedArchitecture(_ architecture: String) -> String {
        switch architecture.lowercased() {
        case "aarch64", "arm64", "arm64/v8":
            return "arm64"
        case "amd64", "x86_64", "x86-64":
            return "amd64"
        default:
            return architecture.lowercased()
        }
    }
}

enum ImageUpdateState: String, Equatable {
    case upToDate = "up-to-date"
    case outdated
    case missing
    case localBuild = "local build"
    case unavailable
}

struct ImageUpdateStatus: Equatable {
    let service: String
    let container: String
    let image: String
    let currentDigest: String?
    let registryDigest: String?
    let state: ImageUpdateState
    let details: String?
}

enum DockerRegistryUpdateError: LocalizedError, Equatable {
    case platformUnavailable(String)
    case invalidPlatformResponse(String)

    var errorDescription: String? {
        switch self {
        case .platformUnavailable(let details):
            return "The Docker platform could not be determined. Details: \(details)"
        case .invalidPlatformResponse(let response):
            return "Docker returned an invalid platform response: \(response)"
        }
    }
}

struct DockerRegistryUpdateChecker {
    private enum DigestLookup {
        case available(String)
        case unavailable(String)
    }

    private let commandRunner: any CommandRunning

    init(commandRunner: any CommandRunning) {
        self.commandRunner = commandRunner
    }

    func check(
        containers: [ManagedContainer],
        statuses: [ContainerStatus]
    ) throws -> [ImageUpdateStatus] {
        let statusesByContainer = Dictionary(
            uniqueKeysWithValues: statuses.map { ($0.container, $0) }
        )
        let needsRegistry = containers.contains { container in
            container.imageUpdateSource == .registry
                && statusesByContainer[container.name]?.digest != nil
        }
        let platform = needsRegistry ? try dockerPlatform() : nil
        var digestCache: [String: DigestLookup] = [:]

        return containers.map { container in
            guard let status = statusesByContainer[container.name],
                  let currentDigest = status.digest else {
                return ImageUpdateStatus(
                    service: container.service,
                    container: container.name,
                    image: container.expectedImage,
                    currentDigest: nil,
                    registryDigest: nil,
                    state: .missing,
                    details: nil
                )
            }

            guard container.imageUpdateSource == .registry else {
                return ImageUpdateStatus(
                    service: container.service,
                    container: container.name,
                    image: status.image,
                    currentDigest: currentDigest,
                    registryDigest: nil,
                    state: .localBuild,
                    details: nil
                )
            }

            let lookup: DigestLookup
            if let cached = digestCache[container.expectedImage] {
                lookup = cached
            } else {
                guard let platform else {
                    return ImageUpdateStatus(
                        service: container.service,
                        container: container.name,
                        image: container.expectedImage,
                        currentDigest: currentDigest,
                        registryDigest: nil,
                        state: .unavailable,
                        details: "The Docker platform is unavailable."
                    )
                }
                lookup = registryDigest(
                    for: container.expectedImage,
                    platform: platform
                )
                digestCache[container.expectedImage] = lookup
            }

            switch lookup {
            case .available(let registryDigest):
                return ImageUpdateStatus(
                    service: container.service,
                    container: container.name,
                    image: container.expectedImage,
                    currentDigest: currentDigest,
                    registryDigest: registryDigest,
                    state: currentDigest == registryDigest ? .upToDate : .outdated,
                    details: nil
                )
            case .unavailable(let details):
                return ImageUpdateStatus(
                    service: container.service,
                    container: container.name,
                    image: container.expectedImage,
                    currentDigest: currentDigest,
                    registryDigest: nil,
                    state: .unavailable,
                    details: details
                )
            }
        }
    }

    private func dockerPlatform() throws -> DockerPlatform {
        let result: CommandResult
        do {
            result = try commandRunner.run(
                "docker",
                arguments: [
                    "info", "--format",
                    "[{{json .OSType}},{{json .Architecture}}]"
                ]
            )
        } catch {
            throw DockerRegistryUpdateError.platformUnavailable(error.localizedDescription)
        }
        guard result.succeeded else {
            throw DockerRegistryUpdateError.platformUnavailable(
                commandFailureDetails(result)
            )
        }

        guard let data = result.standardOutput.data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: data),
              values.count == 2 else {
            throw DockerRegistryUpdateError.invalidPlatformResponse(
                result.standardOutput
            )
        }
        return DockerPlatform(
            operatingSystem: values[0],
            architecture: values[1]
        )
    }

    private func registryDigest(
        for image: String,
        platform: DockerPlatform
    ) -> DigestLookup {
        let result: CommandResult
        do {
            result = try commandRunner.run(
                "docker",
                arguments: ["manifest", "inspect", "--verbose", image]
            )
        } catch {
            return .unavailable(error.localizedDescription)
        }
        guard result.succeeded else {
            return .unavailable(commandFailureDetails(result))
        }

        do {
            return .available(
                try RegistryManifestParser().configurationDigest(
                    from: result.standardOutput,
                    platform: platform
                )
            )
        } catch {
            return .unavailable(error.localizedDescription)
        }
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

enum RegistryManifestParsingError: LocalizedError, Equatable {
    case invalidJSON(String)
    case platformNotFound(DockerPlatform)
    case configurationDigestMissing

    var errorDescription: String? {
        switch self {
        case .invalidJSON(let details):
            return "The registry manifest is not valid JSON. Details: \(details)"
        case .platformNotFound(let platform):
            return "The registry does not provide an image for \(platform.operatingSystem)/\(platform.architecture)."
        case .configurationDigestMissing:
            return "The registry manifest does not contain an image configuration digest."
        }
    }
}

struct RegistryManifestParser {
    func configurationDigest(
        from response: String,
        platform: DockerPlatform
    ) throws -> String {
        let data = Data(response.utf8)
        let documents: [RegistryManifestDocument]

        do {
            if response.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[") {
                documents = try JSONDecoder().decode(
                    [RegistryManifestDocument].self,
                    from: data
                )
            } else {
                documents = [
                    try JSONDecoder().decode(
                        RegistryManifestDocument.self,
                        from: data
                    )
                ]
            }
        } catch {
            throw RegistryManifestParsingError.invalidJSON(error.localizedDescription)
        }

        let platformDocuments = documents.filter { document in
            guard let manifestPlatform = document.descriptor?.platform else {
                return documents.count == 1
            }
            return DockerPlatform(
                operatingSystem: manifestPlatform.operatingSystem,
                architecture: manifestPlatform.architecture
            ) == platform
        }
        guard platformDocuments.isEmpty == false else {
            throw RegistryManifestParsingError.platformNotFound(platform)
        }
        guard let digest = platformDocuments.lazy.compactMap(\.configurationDigest).first else {
            throw RegistryManifestParsingError.configurationDigestMissing
        }
        return digest
    }
}

private struct RegistryManifestDocument: Decodable {
    let descriptor: Descriptor?
    let ociManifest: ImageManifest?
    let schemaV2Manifest: ImageManifest?

    enum CodingKeys: String, CodingKey {
        case descriptor = "Descriptor"
        case ociManifest = "OCIManifest"
        case schemaV2Manifest = "SchemaV2Manifest"
    }

    var configurationDigest: String? {
        ociManifest?.configuration.digest
            ?? schemaV2Manifest?.configuration.digest
    }

    struct Descriptor: Decodable {
        let platform: Platform?

        enum CodingKeys: String, CodingKey {
            case platform
        }
    }

    struct Platform: Decodable {
        let architecture: String
        let operatingSystem: String

        enum CodingKeys: String, CodingKey {
            case architecture
            case operatingSystem = "os"
        }
    }

    struct ImageManifest: Decodable {
        let configuration: Configuration

        enum CodingKeys: String, CodingKey {
            case configuration = "config"
        }
    }

    struct Configuration: Decodable {
        let digest: String
    }
}

struct OutdatedReportRenderer {
    private let console: Console

    init(console: Console) {
        self.console = console
    }

    func render(
        context: InstallationContext,
        updates: [ImageUpdateStatus]
    ) {
        console.section("Vernissage image updates")
        console.value(label: "Instance", value: context.instanceIdentifier)
        if let summaryFilePath = context.summaryFilePath {
            console.value(label: "Configuration", value: summaryFilePath)
        }
        console.line("")

        let rows = updates.map {
            [
                $0.service,
                $0.container,
                $0.image,
                shortDigest($0.currentDigest),
                shortDigest($0.registryDigest),
                $0.state.rawValue
            ]
        }
        renderTable(
            headers: [
                "SERVICE", "CONTAINER", "IMAGE", "CURRENT DIGEST",
                "REGISTRY DIGEST", "STATUS"
            ],
            rows: rows
        )
        console.line("")

        let outdatedCount = updates.count { $0.state == .outdated }
        let unavailable = updates.filter { $0.state == .unavailable }
        let missingCount = updates.count { $0.state == .missing }

        if outdatedCount == 0 && unavailable.isEmpty && missingCount == 0 {
            console.success("No outdated container images were found.")
        } else if outdatedCount == 0 {
            console.info("No outdated images were found among the containers that could be compared.")
        } else {
            console.warning(
                "\(outdatedCount) container image \(outdatedCount == 1 ? "update is" : "updates are") available."
            )
        }
        if missingCount > 0 {
            console.warning(
                "\(missingCount) configured \(missingCount == 1 ? "container is" : "containers are") missing and could not be compared."
            )
        }
        for update in unavailable {
            console.warning(
                "Could not check \(update.service) (\(update.image)): \(update.details ?? "unknown registry error")"
            )
        }
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
