import ArgumentParser
import Foundation

public struct CleanupCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "cleanup",
        abstract: "Remove Docker resources left by an incomplete installation."
    )

    @Option(
        name: .customLong("instance-id"),
        help: "Eight-letter identifier printed when the installation started."
    )
    var instanceIdentifier: String

    @Flag(
        name: .long,
        help: "Also permanently remove the instance's PostgreSQL, Redis, MinIO, and Caddy volumes."
    )
    var includeVolumes = false

    @Flag(name: .long, help: "Disable ANSI colors in terminal output.")
    var noColor = false

    public init() {}

    public mutating func run() throws {
        let console = Console.live(colorsEnabled: noColor == false)

        if includeVolumes {
            console.warning(
                "Persistent Docker volumes for instance \(instanceIdentifier) will be permanently removed."
            )
        }
        console.pending("Inspecting Docker resources for instance \(instanceIdentifier)…")

        do {
            let result = try InstallationCleanupController(
                commandRunner: ProcessCommandRunner()
            ).cleanup(
                instanceIdentifier: instanceIdentifier,
                includeVolumes: includeVolumes
            )
            printResult(result, console: console)
        } catch {
            throw ValidationError(error.localizedDescription)
        }
    }

    private func printResult(
        _ result: InstallationCleanupResult,
        console: Console
    ) {
        console.section("Incomplete installation cleanup")

        for name in result.removedContainers {
            console.success("Removed container: \(name)")
        }
        if let network = result.removedNetwork {
            console.success("Removed network: \(network)")
        }
        if let image = result.removedProxyImage {
            console.success("Removed locally built Proxy image: \(image)")
        }
        for name in result.removedVolumes {
            console.success("Removed volume: \(name)")
        }

        if result.preservedVolumes.isEmpty == false {
            console.warning(
                "Preserved volumes: \(result.preservedVolumes.joined(separator: ", ")). Run cleanup again with --include-volumes to remove them permanently."
            )
        }

        if result.foundResources {
            console.success("Docker cleanup for instance \(result.instanceIdentifier) completed.")
        } else {
            console.info("No Docker resources were found for instance \(result.instanceIdentifier).")
        }
        console.info("Files in the installation directory were not removed.")
    }
}

enum InstallationCleanupError: LocalizedError, Equatable {
    case invalidInstanceIdentifier
    case dockerUnavailable(String)
    case inspectionFailed(resource: String, details: String)
    case removalFailed(resource: String, details: String)

    var errorDescription: String? {
        switch self {
        case .invalidInstanceIdentifier:
            "The --instance-id value must contain exactly eight lowercase ASCII letters."
        case .dockerUnavailable(let details):
            "Docker is not available. Start its daemon and verify your permissions before cleanup. Details: \(details)"
        case .inspectionFailed(let resource, let details):
            "Docker could not inspect the \(resource). No cleanup command was executed for it. Details: \(details)"
        case .removalFailed(let resource, let details):
            "Docker could not remove the \(resource). Some earlier resources may already have been removed. Details: \(details)"
        }
    }
}

struct InstallationCleanupResult: Equatable {
    let instanceIdentifier: String
    let removedContainers: [String]
    let removedVolumes: [String]
    let preservedVolumes: [String]
    let removedNetwork: String?
    let removedProxyImage: String?

    var foundResources: Bool {
        removedContainers.isEmpty == false
            || removedVolumes.isEmpty == false
            || preservedVolumes.isEmpty == false
            || removedNetwork != nil
            || removedProxyImage != nil
    }
}

struct InstallationCleanupController {
    private let commandRunner: any CommandRunning

    init(commandRunner: any CommandRunning) {
        self.commandRunner = commandRunner
    }

    func cleanup(
        instanceIdentifier: String,
        includeVolumes: Bool
    ) throws -> InstallationCleanupResult {
        guard InstallationIdentity.isValid(instanceIdentifier) else {
            throw InstallationCleanupError.invalidInstanceIdentifier
        }

        try verifyDockerAvailability()

        let names = InstallationResourceNames(
            instanceIdentifier: instanceIdentifier
        )
        let containers = try existingResources(
            names: [
                names.caddyContainerName,
                names.proxyContainerName,
                names.pushContainerName,
                names.webContainerName,
                names.jobsContainerName,
                names.apiContainerName,
                names.minIOContainerName,
                names.redisContainerName,
                names.postgresqlContainerName
            ],
            kind: "container"
        )
        let volumes = try existingResources(
            names: [
                names.caddyConfigVolumeName,
                names.caddyDataVolumeName,
                names.minIOVolumeName,
                names.redisVolumeName,
                names.postgresqlVolumeName
            ],
            kind: "volume"
        )
        let networkExists = try resourceExists(
            name: names.networkName,
            kind: "network"
        )
        let proxyImageExists = try resourceExists(
            name: names.proxyImage,
            kind: "image"
        )

        if containers.isEmpty == false {
            try remove(
                arguments: ["container", "rm", "--force"] + containers,
                resource: "installation containers"
            )
        }
        if networkExists {
            try remove(
                arguments: ["network", "rm", names.networkName],
                resource: "installation network"
            )
        }
        if proxyImageExists {
            try remove(
                arguments: ["image", "rm", names.proxyImage],
                resource: "locally built Proxy image"
            )
        }
        if includeVolumes, volumes.isEmpty == false {
            try remove(
                arguments: ["volume", "rm"] + volumes,
                resource: "persistent installation volumes"
            )
        }

        return InstallationCleanupResult(
            instanceIdentifier: instanceIdentifier,
            removedContainers: containers,
            removedVolumes: includeVolumes ? volumes : [],
            preservedVolumes: includeVolumes ? [] : volumes,
            removedNetwork: networkExists ? names.networkName : nil,
            removedProxyImage: proxyImageExists ? names.proxyImage : nil
        )
    }

    private func verifyDockerAvailability() throws {
        let result: CommandResult
        do {
            result = try commandRunner.run(
                "docker",
                arguments: ["info", "--format", "{{.ServerVersion}}"]
            )
        } catch {
            throw InstallationCleanupError.dockerUnavailable(
                error.localizedDescription
            )
        }
        guard result.succeeded else {
            throw InstallationCleanupError.dockerUnavailable(
                details(from: result)
            )
        }
    }

    private func existingResources(
        names: [String],
        kind: String
    ) throws -> [String] {
        try names.filter { name in
            try resourceExists(name: name, kind: kind)
        }
    }

    private func resourceExists(name: String, kind: String) throws -> Bool {
        let result: CommandResult
        do {
            result = try commandRunner.run(
                "docker",
                arguments: [kind, "inspect", name]
            )
        } catch {
            throw InstallationCleanupError.inspectionFailed(
                resource: "\(kind) '\(name)'",
                details: error.localizedDescription
            )
        }
        if result.succeeded {
            return true
        }

        let failure = details(from: result)
        let normalized = failure.lowercased()
        if normalized.contains("no such") || normalized.contains("not found") {
            return false
        }
        throw InstallationCleanupError.inspectionFailed(
            resource: "\(kind) '\(name)'",
            details: failure
        )
    }

    private func remove(arguments: [String], resource: String) throws {
        let result: CommandResult
        do {
            result = try commandRunner.run(
                "docker",
                arguments: arguments
            )
        } catch {
            throw InstallationCleanupError.removalFailed(
                resource: resource,
                details: error.localizedDescription
            )
        }
        guard result.succeeded else {
            throw InstallationCleanupError.removalFailed(
                resource: resource,
                details: details(from: result)
            )
        }
    }

    private func details(from result: CommandResult) -> String {
        if result.standardError.isEmpty == false {
            return result.standardError
        }
        if result.standardOutput.isEmpty == false {
            return result.standardOutput
        }
        return "docker exited with code \(result.exitCode)"
    }
}
