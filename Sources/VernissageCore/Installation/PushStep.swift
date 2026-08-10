import Foundation

enum PushStepError: LocalizedError, Equatable {
    case missingConfiguration(String)
    case invalidGeneratedSecret
    case containerAlreadyExists(String)
    case dockerCommandFailed(action: String, details: String?)
    case startupTimedOut(String?)
    case settingsUpdateFailed(String?)
    case invalidDatabaseResponse

    var errorDescription: String? {
        switch self {
        case .missingConfiguration(let name):
            "The \(name) configuration is missing. Complete all previous installer steps first."
        case .invalidGeneratedSecret:
            "The installer could not generate a valid 32-character WebPush secret."
        case .containerAlreadyExists(let name):
            "A Docker container named \(name) already exists. The installer will not replace it automatically."
        case .dockerCommandFailed(let action, let details):
            Self.message("Docker could not \(action).", details: details)
        case .startupTimedOut(let details):
            Self.message(
                "The Vernissage Push service did not become ready in time. The container was preserved for diagnostics.",
                details: details
            )
        case .settingsUpdateFailed(let details):
            Self.message("The installer could not configure Vernissage WebPush settings.", details: details)
        case .invalidDatabaseResponse:
            "PostgreSQL updated the WebPush settings, but did not return the expected verification result."
        }
    }

    private static func message(_ summary: String, details: String?) -> String {
        guard let details, details.isEmpty == false else { return summary }
        return "\(summary) Details: \(details)"
    }
}

struct PushStep {
    static let image = "mczachurski/vernissage-push:latest"
    static let networkAlias = "vernissage-push.internal"
    static let endpoint = "http://vernissage-push.internal:3000/send"
    static let postgresImage = "postgres:18"

    private static let secretLength = 32
    private static let secretAlphabet = Array(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    )

    private let console: Console
    private let commandRunner: any CommandRunning
    private let waitBeforeRetry: () -> Void
    private let readinessAttempts: Int
    private let operatingSystem: HostOperatingSystem
    private let makeSecretKey: () -> String

    init(
        console: Console,
        commandRunner: any CommandRunning,
        waitBeforeRetry: @escaping () -> Void,
        readinessAttempts: Int = ServiceReadinessPolicy.maximumAttempts,
        operatingSystem: HostOperatingSystem,
        makeSecretKey: @escaping () -> String = PushStep.generateSecretKey
    ) {
        self.console = console
        self.commandRunner = commandRunner
        self.waitBeforeRetry = waitBeforeRetry
        self.readinessAttempts = readinessAttempts
        self.operatingSystem = operatingSystem
        self.makeSecretKey = makeSecretKey
    }

    static func live(colorsEnabled: Bool) -> PushStep {
        PushStep(
            console: .live(colorsEnabled: colorsEnabled),
            commandRunner: ProcessCommandRunner(),
            waitBeforeRetry: { Thread.sleep(forTimeInterval: 1) },
            operatingSystem: .current
        )
    }

    static func generateSecretKey() -> String {
        var generator = SystemRandomNumberGenerator()
        return String(
            (0..<secretLength).map { _ in
                let index = Int.random(in: secretAlphabet.indices, using: &generator)
                return secretAlphabet[index]
            }
        )
    }

    func run(context: InstallationContext) throws {
        let containerName = context.resourceNames.pushContainerName
        let installation = try collectedInstallation(from: context)

        console.section("Vernissage Push")
        console.guidance(InstallationStepGuidance.push)

        let secretKey = try validatedSecretKey(makeSecretKey())
        try ensureContainerDoesNotExist(named: containerName)
        try ensureNetworkExists(installation.serverServices.networkName)
        try pullImage()
        try startContainer(
            name: containerName,
            networkName: installation.serverServices.networkName,
            secretKey: secretKey
        )
        try waitUntilReady(containerName: containerName)
        try updateSettings(
            database: installation.database,
            secretKey: secretKey,
            defaultNetworkName: installation.serverServices.networkName
        )

        context.push = PushConfiguration(
            image: Self.image,
            containerName: containerName,
            networkName: installation.serverServices.networkName,
            networkAlias: Self.networkAlias,
            endpoint: Self.endpoint,
            secretKey: secretKey,
            isEnabled: false
        )

        console.success("Vernissage Push is running and its internal endpoint is configured.")
        console.value(label: "Internal endpoint", value: Self.endpoint)
        console.value(label: "Shared key", value: "generated (hidden)")
        console.value(label: "WebPush", value: "disabled until VAPID settings are configured")
    }

    private func collectedInstallation(from context: InstallationContext) throws -> CollectedPushInstallation {
        guard let database = context.database else {
            throw PushStepError.missingConfiguration("PostgreSQL database")
        }
        guard let serverServices = context.serverServices else {
            throw PushStepError.missingConfiguration("Vernissage API and Jobs")
        }
        return CollectedPushInstallation(database: database, serverServices: serverServices)
    }

    private func validatedSecretKey(_ value: String) throws -> Secret {
        guard value.count == Self.secretLength,
              value.allSatisfy({ Self.secretAlphabet.contains($0) }) else {
            throw PushStepError.invalidGeneratedSecret
        }
        return Secret(value: value)
    }

    private func ensureContainerDoesNotExist(named containerName: String) throws {
        let inspection = try runDocker(["container", "inspect", containerName])
        if inspection.succeeded {
            throw PushStepError.containerAlreadyExists(containerName)
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
            action: "pull the Vernissage Push image"
        )
        console.success("Vernissage Push image is available.")
    }

    private func startContainer(
        name: String,
        networkName: String,
        secretKey: Secret
    ) throws {
        let environment = ["VPUSH_KEY": secretKey.value]
        let arguments = [
            "run", "--detach",
            "--name", name,
            "--restart", "unless-stopped",
            "--network", networkName,
            "--network-alias", Self.networkAlias,
            "--env", "VPUSH_KEY",
            Self.image
        ]

        _ = try requireDockerSuccess(
            arguments,
            action: "start the Vernissage Push container",
            environment: environment
        )
        console.success("Started Docker container: \(name)")
    }

    private func waitUntilReady(containerName: String) throws {
        console.info(
            "Waiting up to \(ServiceReadinessPolicy.timeoutDescription) for Vernissage Push. The check is retried automatically…"
        )
        var lastDetails: String?

        for attempt in 0..<readinessAttempts {
            if attempt > 0 {
                waitBeforeRetry()
            }

            let result = try runDocker([
                "exec", containerName,
                "node", "--input-type=module", "--eval",
                "const response = await fetch('http://127.0.0.1:3000/'); const body = await response.text(); if (response.status !== 200 || !body.includes('Server is up and running...')) process.exit(1);"
            ])
            if result.succeeded {
                console.success("Vernissage Push responded successfully.")
                return
            }
            lastDetails = details(from: result)
        }

        throw PushStepError.startupTimedOut(
            DockerContainerDiagnostics.startupFailureDetails(
                lastDetails,
                containerName: containerName
            )
        )
    }

    private func updateSettings(
        database: DatabaseConfiguration,
        secretKey: Secret,
        defaultNetworkName: String
    ) throws {
        console.info("Saving the internal WebPush endpoint and shared key in PostgreSQL…")
        let target = databaseCommandTarget(
            for: database,
            defaultNetworkName: defaultNetworkName
        )
        let escapedSecret = sqlLiteral(secretKey.value)
        let escapedEndpoint = sqlLiteral(Self.endpoint)
        let script = """
        BEGIN;

        DO $vernissage_installer$
        BEGIN
            UPDATE "Settings"
            SET "value" = '\(escapedSecret)',
                "updatedAt" = CURRENT_TIMESTAMP
            WHERE "key" = 'webPushSecretKey';

            IF NOT FOUND THEN
                RAISE EXCEPTION 'The webPushSecretKey setting was not found.';
            END IF;

            UPDATE "Settings"
            SET "value" = '\(escapedEndpoint)',
                "updatedAt" = CURRENT_TIMESTAMP
            WHERE "key" = 'webPushEndpoint';

            IF NOT FOUND THEN
                RAISE EXCEPTION 'The webPushEndpoint setting was not found.';
            END IF;

            UPDATE "Settings"
            SET "value" = '0',
                "updatedAt" = CURRENT_TIMESTAMP
            WHERE "key" = 'isWebPushEnabled';

            IF NOT FOUND THEN
                RAISE EXCEPTION 'The isWebPushEnabled setting was not found.';
            END IF;
        END
        $vernissage_installer$;

        SELECT COUNT(*)
        FROM "Settings"
        WHERE ("key" = 'webPushSecretKey' AND "value" = '\(escapedSecret)')
           OR ("key" = 'webPushEndpoint' AND "value" = '\(escapedEndpoint)')
           OR ("key" = 'isWebPushEnabled' AND "value" = '0');

        COMMIT;
        """

        var arguments = ["run", "--rm", "--interactive"]
        if let dockerNetwork = target.dockerNetwork {
            arguments += ["--network", dockerNetwork]
        }
        arguments += [
            "--env", "PGPASSWORD",
            "--env", "PGSSLMODE",
            Self.postgresImage,
            "psql",
            "--host", target.host,
            "--port", String(database.port),
            "--username", database.username,
            "--dbname", database.database,
            "--no-password",
            "--quiet",
            "--tuples-only",
            "--no-align",
            "--set", "ON_ERROR_STOP=1"
        ]

        let result: CommandResult
        do {
            result = try commandRunner.run(
                "docker",
                arguments: arguments,
                environment: [
                    "PGPASSWORD": database.password.value,
                    "PGSSLMODE": database.tlsMode.rawValue
                ],
                standardInput: script
            )
        } catch {
            throw PushStepError.settingsUpdateFailed(error.localizedDescription)
        }
        guard result.succeeded else {
            throw PushStepError.settingsUpdateFailed(details(from: result))
        }

        let verification = result.standardOutput
            .split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last(where: { $0.isEmpty == false })
        guard verification == "3" else {
            throw PushStepError.invalidDatabaseResponse
        }
        console.success("WebPush endpoint and shared key were saved; WebPush remains disabled.")
    }

    private func databaseCommandTarget(
        for configuration: DatabaseConfiguration,
        defaultNetworkName: String
    ) -> PushDatabaseCommandTarget {
        if configuration.mode == .localContainer {
            return PushDatabaseCommandTarget(
                host: configuration.host,
                dockerNetwork: configuration.localResources?.networkName ?? defaultNetworkName
            )
        }

        guard isLoopbackHost(configuration.host) else {
            return PushDatabaseCommandTarget(host: configuration.host, dockerNetwork: nil)
        }
        switch operatingSystem {
        case .macOS:
            return PushDatabaseCommandTarget(host: "host.docker.internal", dockerNetwork: nil)
        case .linux:
            return PushDatabaseCommandTarget(host: configuration.host, dockerNetwork: "host")
        }
    }

    private func isLoopbackHost(_ host: String) -> Bool {
        let normalizedHost = host.lowercased()
        return normalizedHost == "localhost" ||
            normalizedHost == "localhost." ||
            normalizedHost.hasPrefix("127.") ||
            normalizedHost == "::1" ||
            normalizedHost == "0:0:0:0:0:0:0:1"
    }

    private func sqlLiteral(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
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
            throw PushStepError.dockerCommandFailed(
                action: "run a Vernissage Push setup command",
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
            throw PushStepError.dockerCommandFailed(
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

private struct CollectedPushInstallation {
    let database: DatabaseConfiguration
    let serverServices: ServerServicesConfiguration
}

private struct PushDatabaseCommandTarget {
    let host: String
    let dockerNetwork: String?
}
