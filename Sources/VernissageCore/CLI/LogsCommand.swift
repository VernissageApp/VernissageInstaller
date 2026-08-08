import ArgumentParser
import Foundation

public struct LogsCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "logs",
        abstract: "Show logs from an installer-managed service container."
    )

    @OptionGroup
    var configurationOptions: ConfigurationOptions

    @Argument(
        help: "Managed service: postgresql, redis, minio, api, jobs, web, push, proxy, or https."
    )
    var service: String

    @Flag(
        name: .long,
        help: "Continue streaming new log entries until interrupted with Control-C."
    )
    var follow = false

    public init() {}

    public mutating func run() throws {
        do {
            let context = try configurationOptions.loadContext()
            let containers = try ManagedContainerInventory().containers(
                from: context
            )
            _ = try ContainerLogsController(
                commandRunner: ProcessStreamingCommandRunner()
            ).showLogs(
                for: service,
                follow: follow,
                containers: containers
            )
        } catch {
            throw ValidationError(error.localizedDescription)
        }
    }
}

enum ContainerLogsError: LocalizedError, Equatable {
    case unknownService(target: String, available: [String])
    case serviceNotManaged(target: String, available: [String])
    case commandFailed(String)
    case dockerExited(Int32)

    var errorDescription: String? {
        switch self {
        case .unknownService(let target, let available):
            return "Unknown Vernissage service '\(target)'. Available managed services: \(available.joined(separator: ", "))."
        case .serviceNotManaged(let target, let available):
            return "The '\(target)' service is not managed by this Vernissage installation. Available managed services: \(available.joined(separator: ", "))."
        case .commandFailed(let details):
            return "Docker logs could not be started. Verify that Docker is installed and its daemon is running. Details: \(details)"
        case .dockerExited(let exitCode):
            return "Docker could not read the selected container logs and exited with code \(exitCode)."
        }
    }
}

struct ContainerLogsController {
    private static let recognizedServices: Set<String> = [
        "postgresql", "redis", "minio", "api", "jobs", "web", "push",
        "proxy", "https"
    ]

    private let commandRunner: any StreamingCommandRunning

    init(commandRunner: any StreamingCommandRunning) {
        self.commandRunner = commandRunner
    }

    @discardableResult
    func showLogs(
        for target: String,
        follow: Bool,
        containers: [ManagedContainer]
    ) throws -> ManagedContainer {
        let container = try selectedContainer(
            target: target,
            containers: containers
        )
        var arguments = ["container", "logs"]
        if follow {
            arguments.append("--follow")
        }
        arguments.append(container.name)

        let result: StreamingCommandResult
        do {
            result = try commandRunner.runStreaming(
                "docker",
                arguments: arguments
            )
        } catch {
            throw ContainerLogsError.commandFailed(error.localizedDescription)
        }
        guard result.succeeded else {
            throw ContainerLogsError.dockerExited(result.exitCode)
        }
        return container
    }

    private func selectedContainer(
        target: String,
        containers: [ManagedContainer]
    ) throws -> ManagedContainer {
        let selector = normalized(target)
        if let container = containers.first(where: {
            normalized($0.service) == selector
        }) {
            return container
        }

        let available = containers.map { normalized($0.service) }
        if Self.recognizedServices.contains(selector) {
            throw ContainerLogsError.serviceNotManaged(
                target: target,
                available: available
            )
        }
        throw ContainerLogsError.unknownService(
            target: target,
            available: available
        )
    }

    private func normalized(_ value: String) -> String {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "postgres": "postgresql"
        case "caddy": "https"
        default: value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }
}
