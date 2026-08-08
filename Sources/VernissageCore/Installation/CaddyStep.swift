import Foundation

enum CaddyStepError: LocalizedError, Equatable {
    case missingConfiguration(String)
    case containerAlreadyExists(String)
    case configurationPreparationFailed(String)
    case commandFailed(action: String, details: String?)
    case startupTimedOut(String?)
    case invalidHealthResponse

    var errorDescription: String? {
        switch self {
        case .missingConfiguration(let name):
            "The \(name) configuration is missing. Complete all previous installer steps first."
        case .containerAlreadyExists(let name):
            "A Docker container named \(name) already exists. The installer will not replace it automatically."
        case .configurationPreparationFailed(let details):
            "The installer could not prepare the Caddy configuration. Details: \(details)"
        case .commandFailed(let action, let details):
            Self.message("The installer could not \(action).", details: details)
        case .startupTimedOut(let details):
            Self.message(
                "The HTTPS endpoint did not become ready in time. The Caddy container was preserved for diagnostics.",
                details: details
            )
        case .invalidHealthResponse:
            "The HTTPS API endpoint returned an invalid health response."
        }
    }

    private static func message(_ summary: String, details: String?) -> String {
        guard let details, details.isEmpty == false else { return summary }
        return "\(summary) Details: \(details)"
    }
}

struct CaddyStep {
    static let image = "caddy:latest"
    static let networkAlias = "vernissage-caddy.internal"

    private let console: Console
    private let commandRunner: any CommandRunning
    private let waitBeforeRetry: () -> Void
    private let readinessAttempts: Int
    private let operatingSystem: HostOperatingSystem
    private let prepareConfiguration: (String) throws -> URL

    init(
        console: Console,
        commandRunner: any CommandRunning,
        waitBeforeRetry: @escaping () -> Void,
        readinessAttempts: Int = 60,
        operatingSystem: HostOperatingSystem,
        prepareConfiguration: @escaping (String) throws -> URL = CaddyStep.writeConfiguration
    ) {
        self.console = console
        self.commandRunner = commandRunner
        self.waitBeforeRetry = waitBeforeRetry
        self.readinessAttempts = readinessAttempts
        self.operatingSystem = operatingSystem
        self.prepareConfiguration = prepareConfiguration
    }

    static func live(colorsEnabled: Bool) -> CaddyStep {
        CaddyStep(
            console: .live(colorsEnabled: colorsEnabled),
            commandRunner: ProcessCommandRunner(),
            waitBeforeRetry: { Thread.sleep(forTimeInterval: 1) },
            operatingSystem: .current
        )
    }

    func run(context: InstallationContext) throws {
        let names = context.resourceNames
        let installation = try collectedInstallation(from: context)

        console.section("HTTPS")
        console.guidance(InstallationStepGuidance.caddy)

        guard installation.publicAccess.httpsMode != .manual else {
            context.caddy = nil
            console.warning("Caddy was not installed. Your external TLS terminator must forward requests to \(installation.proxy.publicHTTPAddress ?? "the published Vernissage Proxy port").")
            return
        }

        try ensureContainerDoesNotExist(named: names.caddyContainerName)
        try ensureNetworkExists(installation.proxy.networkName)

        let caddyfile = makeCaddyfile(
            mode: installation.publicAccess.httpsMode,
            domain: installation.server.domain,
            email: installation.administrator.email,
            proxyAddress: "\(installation.proxy.networkAlias):\(installation.proxy.containerPort)"
        )
        let caddyfileURL = try preparedConfiguration(caddyfile)

        try pullImage()
        try createVolumes(names: names)
        try validateConfiguration(
            caddyfileURL: caddyfileURL,
            networkName: installation.proxy.networkName
        )
        try startContainer(
            name: names.caddyContainerName,
            dataVolumeName: names.caddyDataVolumeName,
            configVolumeName: names.caddyConfigVolumeName,
            caddyfileURL: caddyfileURL,
            networkName: installation.proxy.networkName
        )

        let rootCertificatePath: String?
        switch installation.publicAccess.httpsMode {
        case .development:
            try waitUntilReady(
                domain: installation.server.domain,
                certificateTrust: .insecure
            )
            let rootCertificateURL = caddyfileURL
                .deletingLastPathComponent()
                .appendingPathComponent("root.crt")
            try exportLocalRootCertificate(
                from: names.caddyContainerName,
                to: rootCertificateURL
            )
            try verifyRoutes(
                domain: installation.server.domain,
                certificateTrust: .certificate(at: rootCertificateURL.path)
            )
            rootCertificatePath = rootCertificateURL.path
        case .production:
            try waitUntilReady(
                domain: installation.server.domain,
                certificateTrust: .system
            )
            rootCertificatePath = nil
        case .manual:
            return
        }

        let publicHTTPSAddress = "https://\(installation.server.domain)"
        context.caddy = CaddyConfiguration(
            image: Self.image,
            containerName: names.caddyContainerName,
            networkName: installation.proxy.networkName,
            networkAlias: Self.networkAlias,
            dataVolumeName: names.caddyDataVolumeName,
            configVolumeName: names.caddyConfigVolumeName,
            caddyfilePath: caddyfileURL.path,
            publicHTTPSAddress: publicHTTPSAddress,
            localRootCertificatePath: rootCertificatePath
        )

        if let rootCertificatePath {
            printLocalTrustInstructions(rootCertificatePath: rootCertificatePath)
        } else {
            console.success("The HTTPS certificate is publicly trusted and managed automatically by Caddy.")
        }
        console.completion(
            "Vernissage is available through Caddy over HTTPS.",
            values: [("HTTPS endpoint", publicHTTPSAddress)]
        )
    }

    static func writeConfiguration(_ caddyfile: String) throws -> URL {
        let directory = configurationDirectory(
            in: URL(
                fileURLWithPath: FileManager.default.currentDirectoryPath,
                isDirectory: true
            )
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let caddyfileURL = directory.appendingPathComponent("Caddyfile")
        try caddyfile.write(to: caddyfileURL, atomically: true, encoding: .utf8)
        return caddyfileURL
    }

    static func configurationDirectory(in workingDirectory: URL) -> URL {
        workingDirectory
            .appendingPathComponent("vernissage", isDirectory: true)
            .appendingPathComponent("caddy", isDirectory: true)
    }

    private func collectedInstallation(from context: InstallationContext) throws -> CollectedCaddyInstallation {
        guard let server = context.server else {
            throw CaddyStepError.missingConfiguration("server and domain")
        }
        guard let administrator = context.administrator else {
            throw CaddyStepError.missingConfiguration("administrator account")
        }
        guard let publicAccess = context.publicAccess else {
            throw CaddyStepError.missingConfiguration("HTTPS and public access")
        }
        guard let proxy = context.proxy else {
            throw CaddyStepError.missingConfiguration("Vernissage Proxy")
        }
        return CollectedCaddyInstallation(
            server: server,
            administrator: administrator,
            publicAccess: publicAccess,
            proxy: proxy
        )
    }

    private func makeCaddyfile(
        mode: HTTPSMode,
        domain: String,
        email: String,
        proxyAddress: String
    ) -> String {
        switch mode {
        case .development:
            """
            \(domain) {
                tls internal
                reverse_proxy \(proxyAddress)
            }
            """
        case .production:
            """
            {
                email \(email)
                acme_ca https://acme-v02.api.letsencrypt.org/directory
            }

            \(domain) {
                reverse_proxy \(proxyAddress)
            }
            """
        case .manual:
            ""
        }
    }

    private func ensureContainerDoesNotExist(named containerName: String) throws {
        let inspection = try runDocker(["container", "inspect", containerName])
        if inspection.succeeded {
            throw CaddyStepError.containerAlreadyExists(containerName)
        }
    }

    private func ensureNetworkExists(_ networkName: String) throws {
        _ = try requireDockerSuccess(
            ["network", "inspect", networkName],
            action: "find the Vernissage Docker network"
        )
    }

    private func preparedConfiguration(_ caddyfile: String) throws -> URL {
        do {
            return try prepareConfiguration(caddyfile)
        } catch {
            throw CaddyStepError.configurationPreparationFailed(error.localizedDescription)
        }
    }

    private func pullImage() throws {
        _ = try requireDockerSuccess(
            ["pull", Self.image],
            action: "pull the Caddy image"
        )
    }

    private func createVolumes(names: InstallationResourceNames) throws {
        for volumeName in [names.caddyDataVolumeName, names.caddyConfigVolumeName] {
            _ = try requireDockerSuccess(
                ["volume", "create", volumeName],
                action: "create the \(volumeName) volume"
            )
        }
    }

    private func validateConfiguration(
        caddyfileURL: URL,
        networkName: String
    ) throws {
        _ = try requireDockerSuccess(
            [
                "run", "--rm",
                "--network", networkName,
                "--mount", caddyfileMount(caddyfileURL),
                Self.image,
                "caddy", "validate",
                "--config", "/etc/caddy/Caddyfile",
                "--adapter", "caddyfile"
            ],
            action: "validate the generated Caddy configuration"
        )
    }

    private func startContainer(
        name: String,
        dataVolumeName: String,
        configVolumeName: String,
        caddyfileURL: URL,
        networkName: String
    ) throws {
        _ = try requireDockerSuccess(
            [
                "run", "--detach",
                "--name", name,
                "--restart", "unless-stopped",
                "--network", networkName,
                "--network-alias", Self.networkAlias,
                "--publish", "80:80",
                "--publish", "443:443",
                "--publish", "443:443/udp",
                "--mount", caddyfileMount(caddyfileURL),
                "--mount", "type=volume,source=\(dataVolumeName),target=/data",
                "--mount", "type=volume,source=\(configVolumeName),target=/config",
                Self.image
            ],
            action: "start the Caddy container"
        )
    }

    private func caddyfileMount(_ caddyfileURL: URL) -> String {
        "type=bind,source=\(caddyfileURL.deletingLastPathComponent().path),target=/etc/caddy,readonly"
    }

    private func waitUntilReady(
        domain: String,
        certificateTrust: HTTPSCertificateTrust
    ) throws {
        console.info("Waiting for the HTTPS endpoint and managed certificate…")
        var lastDetails: String?

        for attempt in 0..<readinessAttempts {
            if attempt > 0 {
                waitBeforeRetry()
            }

            do {
                try verifyRoutes(
                    domain: domain,
                    certificateTrust: certificateTrust
                )
                return
            } catch CaddyStepError.commandFailed(_, let details) {
                lastDetails = details
            } catch {
                lastDetails = error.localizedDescription
            }
        }

        throw CaddyStepError.startupTimedOut(lastDetails)
    }

    private func verifyRoutes(
        domain: String,
        certificateTrust: HTTPSCertificateTrust
    ) throws {
        let web = try httpsCurl(
            domain: domain,
            path: "/robots.txt",
            accept: "text/plain",
            certificateTrust: certificateTrust
        )
        guard web.standardOutput.contains("User-agent:") else {
            throw CaddyStepError.commandFailed(
                action: "verify HTTPS Web routing",
                details: "The HTTPS endpoint did not return the Vernissage Web robots.txt file."
            )
        }

        let api = try httpsCurl(
            domain: domain,
            path: "/api/v1/health",
            accept: "application/json",
            certificateTrust: certificateTrust
        )
        guard let health = try? JSONDecoder().decode(
            ServerHealth.self,
            from: Data(api.standardOutput.utf8)
        ) else {
            throw CaddyStepError.invalidHealthResponse
        }
        guard health.isDatabaseHealthy,
              health.isQueueHealthy,
              health.isStorageHealthy else {
            throw CaddyStepError.commandFailed(
                action: "verify HTTPS API routing",
                details: "The API reported an unhealthy dependency."
            )
        }
    }

    private func httpsCurl(
        domain: String,
        path: String,
        accept: String,
        certificateTrust: HTTPSCertificateTrust
    ) throws -> CommandResult {
        var arguments = [
            "--fail-with-body", "--silent", "--show-error",
            "--max-time", "5",
            "--noproxy", "*",
            "--resolve", "\(domain):443:127.0.0.1",
            "--header", "Accept: \(accept)"
        ]
        switch certificateTrust {
        case .insecure:
            arguments.append("--insecure")
        case .certificate(let certificatePath):
            arguments += ["--cacert", certificatePath]
        case .system:
            break
        }
        arguments.append("https://\(domain)\(path)")

        return try requireSuccess(
            "curl",
            arguments: arguments,
            action: "verify HTTPS routing"
        )
    }

    private func exportLocalRootCertificate(
        from containerName: String,
        to destinationURL: URL
    ) throws {
        _ = try requireDockerSuccess(
            [
                "cp",
                "\(containerName):/data/caddy/pki/authorities/local/root.crt",
                destinationURL.path
            ],
            action: "export Caddy's local root certificate"
        )
    }

    private func printLocalTrustInstructions(rootCertificatePath: String) {
        console.warning("Development HTTPS is trusted only after Caddy's local root certificate is installed on each client device.")
        console.value(label: "Local root certificate", value: rootCertificatePath)
        console.info("Make sure the instance domain resolves to this server on every client device; a local hosts-file entry is suitable for development.")
        switch operatingSystem {
        case .macOS:
            console.info("On macOS, add this certificate to the System keychain and mark it as Always Trust.")
        case .linux:
            console.info("On Ubuntu, copy this certificate to /usr/local/share/ca-certificates/vernissage-caddy.crt and run sudo update-ca-certificates.")
        }
        console.warning("Never distribute Caddy's private CA key. Only the exported root.crt certificate should be trusted by clients.")
    }

    private func runDocker(_ arguments: [String]) throws -> CommandResult {
        try runCommand(
            "docker",
            arguments: arguments,
            action: "run a Caddy setup command"
        )
    }

    private func requireDockerSuccess(
        _ arguments: [String],
        action: String
    ) throws -> CommandResult {
        let result = try runDocker(arguments)
        guard result.succeeded else {
            throw CaddyStepError.commandFailed(
                action: action,
                details: details(from: result)
            )
        }
        return result
    }

    private func runCommand(
        _ executable: String,
        arguments: [String],
        action: String
    ) throws -> CommandResult {
        do {
            return try commandRunner.run(
                executable,
                arguments: arguments,
                environment: [:],
                standardInput: nil
            )
        } catch {
            throw CaddyStepError.commandFailed(
                action: action,
                details: error.localizedDescription
            )
        }
    }

    private func requireSuccess(
        _ executable: String,
        arguments: [String],
        action: String
    ) throws -> CommandResult {
        let result = try runCommand(
            executable,
            arguments: arguments,
            action: action
        )
        guard result.succeeded else {
            throw CaddyStepError.commandFailed(
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

private struct CollectedCaddyInstallation {
    let server: ServerConfiguration
    let administrator: AdministratorConfiguration
    let publicAccess: PublicAccessConfiguration
    let proxy: ProxyConfiguration
}

private enum HTTPSCertificateTrust {
    case insecure
    case system
    case certificate(at: String)
}
