import Foundation

enum WebStepError: LocalizedError, Equatable {
    case missingConfiguration(String)
    case invalidCSPImageSource(String)
    case containerAlreadyExists(String)
    case dockerCommandFailed(action: String, details: String?)
    case startupTimedOut(String?)

    var errorDescription: String? {
        switch self {
        case .missingConfiguration(let name):
            "The \(name) configuration is missing. Complete all previous installer steps first."
        case .invalidCSPImageSource(let reason):
            reason
        case .containerAlreadyExists(let name):
            "A Docker container named \(name) already exists. The installer will not replace it automatically."
        case .dockerCommandFailed(let action, let details):
            Self.message("Docker could not \(action).", details: details)
        case .startupTimedOut(let details):
            Self.message(
                "The Vernissage Web service did not become ready in time. The container was preserved for diagnostics.",
                details: details
            )
        }
    }

    private static func message(_ summary: String, details: String?) -> String {
        guard let details, details.isEmpty == false else { return summary }
        return "\(summary) Details: \(details)"
    }
}

struct WebStep {
    static let image = "mczachurski/vernissage-web:latest"
    static let networkAlias = "vernissage-web.internal"

    private let console: Console
    private let commandRunner: any CommandRunning
    private let waitBeforeRetry: () -> Void
    private let readinessAttempts: Int

    init(
        console: Console,
        commandRunner: any CommandRunning,
        waitBeforeRetry: @escaping () -> Void,
        readinessAttempts: Int = 30
    ) {
        self.console = console
        self.commandRunner = commandRunner
        self.waitBeforeRetry = waitBeforeRetry
        self.readinessAttempts = readinessAttempts
    }

    static func live(colorsEnabled: Bool) -> WebStep {
        WebStep(
            console: .live(colorsEnabled: colorsEnabled),
            commandRunner: ProcessCommandRunner(),
            waitBeforeRetry: { Thread.sleep(forTimeInterval: 1) }
        )
    }

    func run(
        context: InstallationContext,
        input: WebStepInput? = nil
    ) throws {
        let containerName = context.resourceNames.webContainerName
        let installation = try collectedInstallation(from: context)

        console.section("Vernissage Web")
        console.guidance(InstallationStepGuidance.web)

        let cspImageSource: String?
        if let input {
            cspImageSource = try validateCSPImageSource(input.cspImageSource ?? "")
        } else {
            cspImageSource = try readCSPImageSource()
        }
        let allowedHosts = "\(installation.server.domain),*.\(installation.server.domain)"
        var environment = ["VERNISSAGE_ALLOWED_HOSTS": allowedHosts]
        if let cspImageSource {
            environment["VERNISSAGE_CSP_IMG"] = cspImageSource
        }

        try ensureContainerDoesNotExist(named: containerName)
        try ensureNetworkExists(installation.serverServices.networkName)
        try pullImage()
        try startContainer(
            name: containerName,
            networkName: installation.serverServices.networkName,
            environment: environment
        )
        try waitUntilReady(containerName: containerName)

        context.web = WebConfiguration(
            image: Self.image,
            containerName: containerName,
            networkName: installation.serverServices.networkName,
            networkAlias: Self.networkAlias,
            allowedHosts: allowedHosts,
            cspImageSource: cspImageSource
        )

        console.success("Vernissage Web is running.")
        console.value(label: "Allowed hosts", value: allowedHosts)
        console.value(label: "CSP image source", value: cspImageSource ?? "not configured")
    }

    private func collectedInstallation(from context: InstallationContext) throws -> CollectedWebInstallation {
        guard let server = context.server else {
            throw WebStepError.missingConfiguration("server and domain")
        }
        guard let serverServices = context.serverServices else {
            throw WebStepError.missingConfiguration("Vernissage API and Jobs")
        }
        return CollectedWebInstallation(server: server, serverServices: serverServices)
    }

    private func readCSPImageSource() throws -> String? {
        while true {
            guard let input = console.prompt(
                "Additional image origin for Content Security Policy (optional; press Enter to skip):"
            ) else {
                return nil
            }

            do {
                return try validateCSPImageSource(input)
            } catch {
                console.warning(error.localizedDescription)
            }
        }
    }

    private func validateCSPImageSource(_ input: String) throws -> String? {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.isEmpty == false else { return nil }

        guard value.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) == false }),
              let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            throw WebStepError.invalidCSPImageSource(
                "Enter an HTTP or HTTPS origin without credentials, a path, query, or fragment, for example https://media.example.com."
            )
        }

        if value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }

    private func ensureContainerDoesNotExist(named containerName: String) throws {
        let inspection = try runDocker(["container", "inspect", containerName])
        if inspection.succeeded {
            throw WebStepError.containerAlreadyExists(containerName)
        }
    }

    private func ensureNetworkExists(_ networkName: String) throws {
        _ = try requireDockerSuccess(
            ["network", "inspect", networkName],
            action: "find the Vernissage Docker network"
        )
    }

    private func pullImage() throws {
        console.info("Pulling \(Self.image)…")
        _ = try requireDockerSuccess(
            ["pull", Self.image],
            action: "pull the Vernissage Web image"
        )
        console.success("Vernissage Web image is available.")
    }

    private func startContainer(
        name: String,
        networkName: String,
        environment: [String: String]
    ) throws {
        var arguments = [
            "run", "--detach",
            "--name", name,
            "--restart", "unless-stopped",
            "--network", networkName,
            "--network-alias", Self.networkAlias
        ]
        for key in environment.keys.sorted() {
            arguments += ["--env", key]
        }
        arguments.append(Self.image)

        _ = try requireDockerSuccess(
            arguments,
            action: "start the Vernissage Web container",
            environment: environment
        )
        console.success("Started Docker container: \(name)")
    }

    private func waitUntilReady(containerName: String) throws {
        console.info("Waiting up to approximately 30 seconds for Vernissage Web…")
        var lastDetails: String?

        for attempt in 0..<readinessAttempts {
            if attempt > 0 {
                waitBeforeRetry()
            }

            let result = try runDocker([
                "exec", containerName,
                "node", "--input-type=module", "--eval",
                "const response = await fetch('http://127.0.0.1:8080/robots.txt'); if (!response.ok) process.exit(1);"
            ])
            if result.succeeded {
                console.success("Vernissage Web responded successfully.")
                return
            }
            lastDetails = details(from: result)
        }

        throw WebStepError.startupTimedOut(
            DockerContainerDiagnostics.startupFailureDetails(
                lastDetails,
                containerName: containerName
            )
        )
    }

    private func runDocker(
        _ arguments: [String],
        environment: [String: String] = [:]
    ) throws -> CommandResult {
        do {
            return try commandRunner.run(
                "docker",
                arguments: arguments,
                environment: environment,
                standardInput: nil
            )
        } catch {
            throw WebStepError.dockerCommandFailed(
                action: "run a Vernissage Web setup command",
                details: error.localizedDescription
            )
        }
    }

    private func requireDockerSuccess(
        _ arguments: [String],
        action: String,
        environment: [String: String] = [:]
    ) throws -> CommandResult {
        let result = try runDocker(arguments, environment: environment)
        guard result.succeeded else {
            throw WebStepError.dockerCommandFailed(
                action: action,
                details: details(from: result)
            )
        }
        return result
    }

    private func details(from result: CommandResult) -> String? {
        if result.standardError.isEmpty == false { return result.standardError }
        if result.standardOutput.isEmpty == false { return result.standardOutput }
        return nil
    }
}

private struct CollectedWebInstallation {
    let server: ServerConfiguration
    let serverServices: ServerServicesConfiguration
}
