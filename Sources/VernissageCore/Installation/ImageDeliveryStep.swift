import Foundation

enum ImageDeliveryStepError: LocalizedError, Equatable {
    case missingConfiguration(String)
    case settingsUpdateFailed(String?)
    case invalidDatabaseResponse
    case serviceRestartFailed(String?)
    case serviceStartupTimedOut(service: String, details: String?)

    var errorDescription: String? {
        switch self {
        case .missingConfiguration(let name):
            "The \(name) configuration is missing. Complete all previous installer steps first."
        case .settingsUpdateFailed(let details):
            Self.message("The installer could not configure the public images URL.", details: details)
        case .invalidDatabaseResponse:
            "PostgreSQL updated the public images URL, but did not return the expected verification result."
        case .serviceRestartFailed(let details):
            Self.message(
                "The public images URL was saved, but the Vernissage API and Jobs services could not be restarted.",
                details: details
            )
        case .serviceStartupTimedOut(let service, let details):
            Self.message(
                "The Vernissage \(service) service did not become healthy after loading the new public images URL.",
                details: details
            )
        }
    }

    private static func message(_ summary: String, details: String?) -> String {
        guard let details, details.isEmpty == false else { return summary }
        return "\(summary) Details: \(details)"
    }
}

struct ImageDeliveryStep {
    static let postgresImage = "postgres:18"

    private let console: Console
    private let commandRunner: any CommandRunning
    private let waitBeforeRetry: () -> Void
    private let healthAttempts: Int
    private let operatingSystem: HostOperatingSystem

    init(
        console: Console,
        commandRunner: any CommandRunning,
        waitBeforeRetry: @escaping () -> Void,
        healthAttempts: Int = 30,
        operatingSystem: HostOperatingSystem
    ) {
        self.console = console
        self.commandRunner = commandRunner
        self.waitBeforeRetry = waitBeforeRetry
        self.healthAttempts = healthAttempts
        self.operatingSystem = operatingSystem
    }

    static func live(colorsEnabled: Bool) -> ImageDeliveryStep {
        ImageDeliveryStep(
            console: .live(colorsEnabled: colorsEnabled),
            commandRunner: ProcessCommandRunner(),
            waitBeforeRetry: { Thread.sleep(forTimeInterval: 1) },
            operatingSystem: .current
        )
    }

    func run(context: InstallationContext) throws {
        guard let storage = context.storage else {
            throw ImageDeliveryStepError.missingConfiguration("S3 object storage")
        }
        guard let imagesURL = storage.imagesURL else {
            return
        }
        guard let database = context.database else {
            throw ImageDeliveryStepError.missingConfiguration("PostgreSQL database")
        }
        guard let serverServices = context.serverServices else {
            throw ImageDeliveryStepError.missingConfiguration("Vernissage API and Jobs")
        }

        console.section("Public image delivery")
        console.guidance(InstallationStepGuidance.imageDelivery)
        console.info("Saving the public image base URL in PostgreSQL…")

        try updateImagesURL(
            imagesURL,
            database: database,
            defaultNetworkName: serverServices.networkName
        )
        try restartServerServices(serverServices)
        try waitForHealthyService(
            named: "API",
            containerName: serverServices.apiContainerName
        )
        try waitForHealthyService(
            named: "Jobs",
            containerName: serverServices.jobsContainerName
        )

        console.success("The public image base URL is configured and loaded by API and Jobs.")
        console.value(label: "Images URL", value: imagesURL)
    }

    private func restartServerServices(
        _ configuration: ServerServicesConfiguration
    ) throws {
        console.info("Restarting Vernissage API and Jobs to load the new public images URL…")
        let result: CommandResult
        do {
            result = try commandRunner.run(
                "docker",
                arguments: [
                    "restart",
                    configuration.apiContainerName,
                    configuration.jobsContainerName
                ],
                environment: [:],
                standardInput: nil
            )
        } catch {
            throw ImageDeliveryStepError.serviceRestartFailed(error.localizedDescription)
        }
        guard result.succeeded else {
            throw ImageDeliveryStepError.serviceRestartFailed(details(from: result))
        }
        console.success("Vernissage API and Jobs were restarted.")
    }

    private func waitForHealthyService(
        named service: String,
        containerName: String
    ) throws {
        console.info("Waiting up to approximately 30 seconds for Vernissage \(service)…")
        var lastDetails: String?

        for attempt in 0..<healthAttempts {
            if attempt > 0 {
                waitBeforeRetry()
            }

            let result: CommandResult
            do {
                result = try commandRunner.run(
                    "docker",
                    arguments: [
                        "exec", containerName,
                        "curl", "--fail", "--silent", "--show-error", "--max-time", "5",
                        "http://127.0.0.1:8080/api/v1/health"
                    ],
                    environment: [:],
                    standardInput: nil
                )
            } catch {
                lastDetails = error.localizedDescription
                continue
            }

            guard result.succeeded else {
                lastDetails = details(from: result)
                continue
            }

            do {
                let health = try JSONDecoder().decode(
                    ServerHealth.self,
                    from: Data(result.standardOutput.utf8)
                )
                guard health.isDatabaseHealthy,
                      health.isQueueHealthy,
                      health.isStorageHealthy else {
                    lastDetails = healthSummary(health)
                    continue
                }
                console.success("Vernissage \(service) is healthy after restart.")
                return
            } catch {
                lastDetails = "Invalid health response: \(error.localizedDescription)"
            }
        }

        throw ImageDeliveryStepError.serviceStartupTimedOut(
            service: service,
            details: lastDetails
        )
    }

    private func updateImagesURL(
        _ imagesURL: String,
        database: DatabaseConfiguration,
        defaultNetworkName: String
    ) throws {
        let target = databaseCommandTarget(
            for: database,
            defaultNetworkName: defaultNetworkName
        )
        let escapedImagesURL = sqlLiteral(imagesURL)
        let script = """
        BEGIN;

        DO $vernissage_installer$
        BEGIN
            UPDATE "Settings"
            SET "value" = '\(escapedImagesURL)',
                "updatedAt" = CURRENT_TIMESTAMP
            WHERE "key" = 'imagesUrl';

            IF NOT FOUND THEN
                RAISE EXCEPTION 'The imagesUrl setting was not found.';
            END IF;
        END
        $vernissage_installer$;

        SELECT COUNT(*)
        FROM "Settings"
        WHERE "key" = 'imagesUrl'
          AND "value" = '\(escapedImagesURL)';

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
            throw ImageDeliveryStepError.settingsUpdateFailed(error.localizedDescription)
        }
        guard result.succeeded else {
            throw ImageDeliveryStepError.settingsUpdateFailed(details(from: result))
        }
        guard result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "1" else {
            throw ImageDeliveryStepError.invalidDatabaseResponse
        }
    }

    private func databaseCommandTarget(
        for configuration: DatabaseConfiguration,
        defaultNetworkName: String
    ) -> ImageDeliveryDatabaseCommandTarget {
        if configuration.mode == .localContainer {
            return ImageDeliveryDatabaseCommandTarget(
                host: configuration.host,
                dockerNetwork: configuration.localResources?.networkName ?? defaultNetworkName
            )
        }
        guard isLoopbackHost(configuration.host) else {
            return ImageDeliveryDatabaseCommandTarget(host: configuration.host, dockerNetwork: nil)
        }
        switch operatingSystem {
        case .macOS:
            return ImageDeliveryDatabaseCommandTarget(host: "host.docker.internal", dockerNetwork: nil)
        case .linux:
            return ImageDeliveryDatabaseCommandTarget(host: configuration.host, dockerNetwork: "host")
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

    private func details(from result: CommandResult) -> String? {
        if result.standardError.isEmpty == false { return result.standardError }
        if result.standardOutput.isEmpty == false { return result.standardOutput }
        return nil
    }

    private func healthSummary(_ health: ServerHealth) -> String {
        "database=\(health.isDatabaseHealthy), queue=\(health.isQueueHealthy), webPush=\(health.isWebPushHealthy), storage=\(health.isStorageHealthy)"
    }
}

private struct ImageDeliveryDatabaseCommandTarget {
    let host: String
    let dockerNetwork: String?
}
