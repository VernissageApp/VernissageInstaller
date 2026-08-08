import ArgumentParser
import Foundation

public struct StartCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Start an installer-managed service or all services."
    )

    @OptionGroup
    var configurationOptions: ConfigurationOptions

    @Argument(help: "Managed service: postgresql, redis, minio, api, jobs, web, push, proxy, https, or all.")
    var service: String

    @Flag(name: .long, help: "Disable ANSI colors in terminal output.")
    var noColor = false

    public init() {}

    public mutating func run() throws {
        try ContainerLifecycleCommand().run(
            action: .start,
            target: service,
            configurationOptions: configurationOptions,
            colorsEnabled: noColor == false
        )
    }
}

public struct StopCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop an installer-managed service or all services."
    )

    @OptionGroup
    var configurationOptions: ConfigurationOptions

    @Argument(help: "Managed service: postgresql, redis, minio, api, jobs, web, push, proxy, https, or all.")
    var service: String

    @Flag(name: .long, help: "Disable ANSI colors in terminal output.")
    var noColor = false

    public init() {}

    public mutating func run() throws {
        try ContainerLifecycleCommand().run(
            action: .stop,
            target: service,
            configurationOptions: configurationOptions,
            colorsEnabled: noColor == false
        )
    }
}

public struct RestartCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "restart",
        abstract: "Restart an installer-managed service or all services."
    )

    @OptionGroup
    var configurationOptions: ConfigurationOptions

    @Argument(help: "Managed service: postgresql, redis, minio, api, jobs, web, push, proxy, https, or all.")
    var service: String

    @Flag(name: .long, help: "Disable ANSI colors in terminal output.")
    var noColor = false

    public init() {}

    public mutating func run() throws {
        try ContainerLifecycleCommand().run(
            action: .restart,
            target: service,
            configurationOptions: configurationOptions,
            colorsEnabled: noColor == false
        )
    }
}

enum ContainerLifecycleAction: String, Equatable {
    case start
    case stop
    case restart

    var progressText: String {
        switch self {
        case .start: "Starting"
        case .stop: "Stopping"
        case .restart: "Restarting"
        }
    }

    var completionText: String {
        switch self {
        case .start: "Started"
        case .stop: "Stopped"
        case .restart: "Restarted"
        }
    }
}

enum ContainerLifecycleError: LocalizedError, Equatable {
    case unknownService(target: String, available: [String])
    case serviceNotManaged(target: String, available: [String])
    case inspectionFailed(String)
    case actionFailed(action: ContainerLifecycleAction, details: String)

    var errorDescription: String? {
        switch self {
        case .unknownService(let target, let available):
            return "Unknown Vernissage service '\(target)'. Available managed services: \(available.joined(separator: ", ")), all."
        case .serviceNotManaged(let target, let available):
            return "The '\(target)' service is not managed by this Vernissage installation. Available managed services: \(available.joined(separator: ", ")), all."
        case .inspectionFailed(let details):
            return "The selected Vernissage containers could not be verified before changing their state. No lifecycle command was executed. Details: \(details)"
        case .actionFailed(let action, let details):
            return "Docker could not \(action.rawValue) the selected Vernissage containers. Details: \(details)"
        }
    }
}

struct ContainerLifecycleController {
    private static let recognizedServices: Set<String> = [
        "postgresql", "redis", "minio", "api", "jobs", "web", "push",
        "proxy", "https"
    ]

    private let commandRunner: any CommandRunning

    init(commandRunner: any CommandRunning) {
        self.commandRunner = commandRunner
    }

    func perform(
        action: ContainerLifecycleAction,
        target: String,
        containers: [ManagedContainer]
    ) throws -> [ManagedContainer] {
        let selected = try selectedContainers(target: target, containers: containers)
        let ordered = action == .stop && normalized(target) == "all"
            ? Array(selected.reversed())
            : selected

        try verifyContainersExist(ordered)
        try changeState(action: action, containers: ordered)
        return ordered
    }

    private func selectedContainers(
        target: String,
        containers: [ManagedContainer]
    ) throws -> [ManagedContainer] {
        let selector = normalized(target)
        if selector == "all" {
            return containers
        }

        if let container = containers.first(where: {
            normalized($0.service) == selector
        }) {
            return [container]
        }

        let available = availableServices(containers)
        if Self.recognizedServices.contains(selector) {
            throw ContainerLifecycleError.serviceNotManaged(
                target: target,
                available: available
            )
        }
        throw ContainerLifecycleError.unknownService(
            target: target,
            available: available
        )
    }

    private func verifyContainersExist(_ containers: [ManagedContainer]) throws {
        let result: CommandResult
        do {
            result = try commandRunner.run(
                "docker",
                arguments: [
                    "container", "inspect", "--format", "{{.Name}}"
                ] + containers.map(\.name)
            )
        } catch {
            throw ContainerLifecycleError.inspectionFailed(error.localizedDescription)
        }
        guard result.succeeded else {
            throw ContainerLifecycleError.inspectionFailed(
                commandFailureDetails(result)
            )
        }
    }

    private func changeState(
        action: ContainerLifecycleAction,
        containers: [ManagedContainer]
    ) throws {
        let result: CommandResult
        do {
            result = try commandRunner.run(
                "docker",
                arguments: ["container", action.rawValue] + containers.map(\.name)
            )
        } catch {
            throw ContainerLifecycleError.actionFailed(
                action: action,
                details: error.localizedDescription
            )
        }
        guard result.succeeded else {
            throw ContainerLifecycleError.actionFailed(
                action: action,
                details: commandFailureDetails(result)
            )
        }
    }

    private func normalized(_ value: String) -> String {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "postgres": "postgresql"
        case "caddy": "https"
        default: value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }

    private func availableServices(_ containers: [ManagedContainer]) -> [String] {
        containers.map { normalized($0.service) }
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

private struct ContainerLifecycleCommand {
    func run(
        action: ContainerLifecycleAction,
        target: String,
        configurationOptions: ConfigurationOptions,
        colorsEnabled: Bool
    ) throws {
        let console = Console.live(colorsEnabled: colorsEnabled)

        do {
            let context = try configurationOptions.loadContext()
            let containers = try ManagedContainerInventory().containers(from: context)
            console.pending("\(action.progressText) '\(target)'…")
            let changed = try ContainerLifecycleController(
                commandRunner: ProcessCommandRunner()
            ).perform(
                action: action,
                target: target,
                containers: containers
            )

            console.section("Vernissage container lifecycle")
            for container in changed {
                console.success(
                    "\(action.completionText) \(container.service) (\(container.name))."
                )
            }
        } catch {
            throw ValidationError(error.localizedDescription)
        }
    }
}
