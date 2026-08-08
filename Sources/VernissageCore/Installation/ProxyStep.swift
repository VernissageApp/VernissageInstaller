import Foundation

enum ProxyStepError: LocalizedError, Equatable {
    case missingConfiguration(String)
    case invalidUpstreamAddress(String)
    case containerAlreadyExists(String)
    case buildContextPreparationFailed(String)
    case commandFailed(action: String, details: String?)
    case startupTimedOut(String?)

    var errorDescription: String? {
        switch self {
        case .missingConfiguration(let name):
            "The \(name) configuration is missing. Complete all previous installer steps first."
        case .invalidUpstreamAddress(let address):
            "The installer cannot use \(address) as an Nginx upstream address."
        case .containerAlreadyExists(let name):
            "A Docker container named \(name) already exists. The installer will not replace it automatically."
        case .buildContextPreparationFailed(let details):
            "The installer could not prepare the Vernissage Proxy build files. Details: \(details)"
        case .commandFailed(let action, let details):
            Self.message("The installer could not \(action).", details: details)
        case .startupTimedOut(let details):
            Self.message(
                "The Vernissage Proxy routes did not become ready in time. The container was preserved for diagnostics.",
                details: details
            )
        }
    }

    private static func message(_ summary: String, details: String?) -> String {
        guard let details, details.isEmpty == false else { return summary }
        return "\(summary) Details: \(details)"
    }
}

struct ProxyStep {
    static let networkAlias = "vernissage-proxy.internal"
    static let defaultHostPort: UInt16 = 8080
    static let containerPort: UInt16 = 8080

    private let console: Console
    private let commandRunner: any CommandRunning
    private let waitBeforeRetry: () -> Void
    private let readinessAttempts: Int
    private let prepareBuildContext: (String, String) throws -> URL

    init(
        console: Console,
        commandRunner: any CommandRunning,
        waitBeforeRetry: @escaping () -> Void,
        readinessAttempts: Int = 30,
        prepareBuildContext: @escaping (String, String) throws -> URL = ProxyStep.writeBuildContext
    ) {
        self.console = console
        self.commandRunner = commandRunner
        self.waitBeforeRetry = waitBeforeRetry
        self.readinessAttempts = readinessAttempts
        self.prepareBuildContext = prepareBuildContext
    }

    static func live(colorsEnabled: Bool) -> ProxyStep {
        ProxyStep(
            console: .live(colorsEnabled: colorsEnabled),
            commandRunner: ProcessCommandRunner(),
            waitBeforeRetry: { Thread.sleep(forTimeInterval: 1) }
        )
    }

    func run(context: InstallationContext, providedHostPort: UInt16? = nil) throws {
        let names = context.resourceNames
        let installation = try collectedInstallation(from: context)
        let apiUpstream = try upstream(
            host: installation.serverServices.apiNetworkAlias,
            port: 8080
        )
        let webUpstream = try upstream(
            host: installation.web.networkAlias,
            port: 8080
        )

        console.section("Vernissage Proxy")
        console.guidance(InstallationStepGuidance.proxy)

        let hostPort = installation.publicAccess.httpsMode == .manual
            ? (providedHostPort ?? readHostPort())
            : nil
        try ensureContainerDoesNotExist(named: names.proxyContainerName)
        try ensureNetworkExists(installation.serverServices.networkName)

        let dockerfile = Self.makeDockerfile()
        let nginxConfiguration = Self.makeNginxConfiguration(
            apiUpstream: apiUpstream,
            webUpstream: webUpstream
        )
        let buildContext = try preparedBuildContext(
            dockerfile: dockerfile,
            nginxConfiguration: nginxConfiguration
        )

        console.success("Generated Dockerfile and nginx.conf in \(buildContext.path).")
        try buildImage(named: names.proxyImage, buildContext: buildContext)
        try validateImage(
            named: names.proxyImage,
            networkName: installation.serverServices.networkName
        )
        try startContainer(
            name: names.proxyContainerName,
            image: names.proxyImage,
            networkName: installation.serverServices.networkName,
            hostPort: hostPort
        )
        try waitUntilReady(
            installation: installation,
            hostPort: hostPort
        )

        let publicHTTPAddress = hostPort.map {
            "http://\(installation.server.domain):\($0)"
        }
        context.proxy = ProxyConfiguration(
            image: names.proxyImage,
            containerName: names.proxyContainerName,
            networkName: installation.serverServices.networkName,
            networkAlias: Self.networkAlias,
            hostPort: hostPort,
            containerPort: Self.containerPort,
            apiUpstream: apiUpstream,
            webUpstream: webUpstream,
            publicHTTPAddress: publicHTTPAddress,
            buildContextPath: buildContext.path
        )

        console.success("Vernissage Proxy is running and API/Web routing was verified.")
        if let hostPort, let publicHTTPAddress {
            console.value(label: "HTTP endpoint", value: publicHTTPAddress)
            console.warning("Port \(hostPort) serves plain HTTP and must be protected by your external TLS terminator.")
        } else {
            console.value(label: "Exposure", value: "private Docker network only")
        }
        console.value(label: "API upstream", value: apiUpstream)
        console.value(label: "Web upstream", value: webUpstream)
    }

    static func writeBuildContext(
        dockerfile: String,
        nginxConfiguration: String
    ) throws -> URL {
        let fileManager = FileManager.default
        let workingDirectory = URL(
            fileURLWithPath: fileManager.currentDirectoryPath,
            isDirectory: true
        )
        let buildContextURL = buildContextURL(in: workingDirectory)
        try fileManager.createDirectory(
            at: buildContextURL,
            withIntermediateDirectories: true
        )
        try dockerfile.write(
            to: buildContextURL.appendingPathComponent("Dockerfile"),
            atomically: true,
            encoding: .utf8
        )
        try nginxConfiguration.write(
            to: buildContextURL.appendingPathComponent("nginx.conf"),
            atomically: true,
            encoding: .utf8
        )
        return buildContextURL
    }

    static func buildContextURL(in workingDirectory: URL) -> URL {
        workingDirectory
            .appendingPathComponent("vernissage", isDirectory: true)
            .appendingPathComponent("proxy", isDirectory: true)
    }

    private func collectedInstallation(from context: InstallationContext) throws -> CollectedProxyInstallation {
        guard let server = context.server else {
            throw ProxyStepError.missingConfiguration("server and domain")
        }
        guard let serverServices = context.serverServices else {
            throw ProxyStepError.missingConfiguration("Vernissage API and Jobs")
        }
        guard let web = context.web else {
            throw ProxyStepError.missingConfiguration("Vernissage Web")
        }
        guard let publicAccess = context.publicAccess else {
            throw ProxyStepError.missingConfiguration("HTTPS and public access")
        }
        return CollectedProxyInstallation(
            server: server,
            serverServices: serverServices,
            web: web,
            publicAccess: publicAccess
        )
    }

    private func upstream(host: String, port: UInt16) throws -> String {
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        guard host.isEmpty == false,
              host.unicodeScalars.allSatisfy(allowedCharacters.contains) else {
            throw ProxyStepError.invalidUpstreamAddress(host)
        }
        return "\(host):\(port)"
    }

    private func readHostPort() -> UInt16 {
        while true {
            guard let input = console.prompt("Proxy host port [\(Self.defaultHostPort)]:"),
                  input.isEmpty == false else {
                return Self.defaultHostPort
            }

            if let port = UInt16(input), port > 0 {
                return port
            }
            console.warning("Enter a port number between 1 and 65535.")
        }
    }

    static func makeDockerfile() -> String {
        """
        FROM nginx:latest

        COPY nginx.conf /etc/nginx/conf.d/default.conf

        EXPOSE 8080

        CMD ["nginx", "-g", "daemon off;"]
        """
    }

    static func makeNginxConfiguration(
        apiUpstream: String,
        webUpstream: String
    ) -> String {
        """
        upstream vernissage_api {
            server \(apiUpstream) max_fails=2 fail_timeout=3s;
            keepalive 16;
        }

        upstream vernissage_web {
            server \(webUpstream) max_fails=2 fail_timeout=3s;
            keepalive 16;
        }

        map "$http_content_type:$http_accept" $vernissage_route_to_api {
            default 0;
            ~*json 1;
        }

        map $http_upgrade $vernissage_connection_upgrade {
            default upgrade;
            '' close;
        }

        map $http_x_forwarded_proto $vernissage_forwarded_proto {
            default $scheme;
            ~^https?$ $http_x_forwarded_proto;
        }

        server {
            listen 8080 default_server;
            server_name _;
            client_max_body_size 20M;

            proxy_http_version 1.1;
            proxy_pass_request_headers on;
            proxy_set_header Host $host;
            proxy_set_header X-Forwarded-Host $http_host;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $vernissage_forwarded_proto;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection $vernissage_connection_upgrade;

            location /api/v1/ {
                proxy_pass http://vernissage_api;
            }

            location /.well-known/ {
                proxy_pass http://vernissage_api;
            }

            location /rss/ {
                proxy_pass http://vernissage_api;
            }

            location /atom/ {
                proxy_pass http://vernissage_api;
            }

            location / {
                error_page 418 = @vernissage_api_by_header;

                if ($vernissage_route_to_api) {
                    return 418;
                }

                proxy_pass http://vernissage_web;
            }

            location @vernissage_api_by_header {
                proxy_pass http://vernissage_api;
            }
        }
        """
    }

    private func ensureContainerDoesNotExist(named containerName: String) throws {
        let inspection = try runCommand(
            "docker",
            arguments: ["container", "inspect", containerName],
            action: "inspect the Vernissage Proxy container"
        )
        if inspection.succeeded {
            throw ProxyStepError.containerAlreadyExists(containerName)
        }
    }

    private func ensureNetworkExists(_ networkName: String) throws {
        _ = try requireSuccess(
            "docker",
            arguments: ["network", "inspect", networkName],
            action: "find the Vernissage Docker network"
        )
    }

    private func preparedBuildContext(
        dockerfile: String,
        nginxConfiguration: String
    ) throws -> URL {
        do {
            return try prepareBuildContext(dockerfile, nginxConfiguration)
        } catch {
            throw ProxyStepError.buildContextPreparationFailed(error.localizedDescription)
        }
    }

    private func buildImage(named image: String, buildContext: URL) throws {
        console.info("Building \(image) from the generated Nginx configuration…")
        _ = try requireSuccess(
            "docker",
            arguments: ["build", "--tag", image, buildContext.path],
            action: "build the Vernissage Proxy image"
        )
        console.success("Built Docker image: \(image)")
    }

    private func validateImage(named image: String, networkName: String) throws {
        _ = try requireSuccess(
            "docker",
            arguments: [
                "run", "--rm",
                "--network", networkName,
                image,
                "nginx", "-t"
            ],
            action: "validate the generated Nginx configuration"
        )
        console.success("The generated Nginx configuration is valid.")
    }

    private func startContainer(
        name: String,
        image: String,
        networkName: String,
        hostPort: UInt16?
    ) throws {
        var arguments = [
            "run", "--detach",
            "--name", name,
            "--restart", "unless-stopped",
            "--network", networkName,
            "--network-alias", Self.networkAlias
        ]
        if let hostPort {
            arguments += ["--publish", "\(hostPort):\(Self.containerPort)"]
        }
        arguments.append(image)

        _ = try requireSuccess(
            "docker",
            arguments: arguments,
            action: "start the Vernissage Proxy container"
        )
        console.success("Started Docker container: \(name)")
    }

    private func waitUntilReady(
        installation: CollectedProxyInstallation,
        hostPort: UInt16?
    ) throws {
        if let hostPort {
            console.info("Waiting up to approximately 30 seconds for API and Web routing on host port \(hostPort)…")
        } else {
            console.info("Waiting up to approximately 30 seconds for API and Web routing inside the Docker network…")
        }
        var lastDetails: String?

        for attempt in 0..<readinessAttempts {
            if attempt > 0 {
                waitBeforeRetry()
            }

            let apiResult = try curl(
                path: "/api/v1/health",
                installation: installation,
                accept: "application/json",
                hostPort: hostPort
            )
            guard apiResult.succeeded else {
                lastDetails = "API path routing failed: \(details(from: apiResult) ?? "no response")"
                continue
            }
            guard let health = try? JSONDecoder().decode(
                ServerHealth.self,
                from: Data(apiResult.standardOutput.utf8)
            ) else {
                lastDetails = "API path routing returned an invalid health response."
                continue
            }
            guard health.isDatabaseHealthy,
                  health.isQueueHealthy,
                  health.isStorageHealthy else {
                lastDetails = "API path routing returned unhealthy dependencies."
                continue
            }

            let webResult = try curl(
                path: "/robots.txt",
                installation: installation,
                accept: "text/plain",
                hostPort: hostPort
            )
            guard webResult.succeeded,
                  webResult.standardOutput.contains("User-agent:") else {
                lastDetails = "Default browser routing did not return the Vernissage Web robots.txt file."
                continue
            }

            let headerResult = try curl(
                path: "/",
                installation: installation,
                accept: "application/json",
                hostPort: hostPort
            )
            guard headerResult.succeeded,
                  headerResult.standardOutput == "Service is up and running!" else {
                lastDetails = "JSON Accept-header routing did not return the Vernissage API root response."
                continue
            }

            console.success("Path routing sends /api/v1 requests to Vernissage API.")
            console.success("Default browser routing sends requests to Vernissage Web.")
            console.success("JSON request headers route machine-readable requests to Vernissage API.")
            if health.isWebPushHealthy {
                console.success("The API reports WebPush as healthy.")
            } else {
                console.info("WebPush remains disabled, so its API health value may remain false.")
            }
            return
        }

        throw ProxyStepError.startupTimedOut(lastDetails)
    }

    private func curl(
        path: String,
        installation: CollectedProxyInstallation,
        accept: String,
        hostPort: UInt16?
    ) throws -> CommandResult {
        let curlArguments = [
            "--fail-with-body", "--silent", "--show-error",
            "--max-time", "5",
            "--header", "Host: \(installation.server.domain)",
            "--header", "Accept: \(accept)"
        ]

        if let hostPort {
            return try runCommand(
                "curl",
                arguments: curlArguments + ["http://127.0.0.1:\(hostPort)\(path)"],
                action: "check Vernissage Proxy routing"
            )
        }

        return try runCommand(
            "docker",
            arguments: [
                "exec", installation.serverServices.apiContainerName,
                "curl"
            ] + curlArguments + [
                "http://\(Self.networkAlias):\(Self.containerPort)\(path)"
            ],
            action: "check Vernissage Proxy routing"
        )
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
            throw ProxyStepError.commandFailed(
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
        let result = try runCommand(executable, arguments: arguments, action: action)
        guard result.succeeded else {
            throw ProxyStepError.commandFailed(
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

private struct CollectedProxyInstallation {
    let server: ServerConfiguration
    let serverServices: ServerServicesConfiguration
    let web: WebConfiguration
    let publicAccess: PublicAccessConfiguration
}
