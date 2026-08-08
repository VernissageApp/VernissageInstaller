import Foundation

struct DoctorDiagnosticRunner {
    private let commandRunner: any CommandRunning
    private let dnsResolver: any DNSResolving
    private let fileSystem: DoctorFileSystem
    private let operatingSystem: HostOperatingSystem
    private let makeToken: () -> String

    init(
        commandRunner: any CommandRunning,
        dnsResolver: any DNSResolving,
        fileSystem: DoctorFileSystem,
        operatingSystem: HostOperatingSystem,
        makeToken: @escaping () -> String = {
            UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        }
    ) {
        self.commandRunner = commandRunner
        self.dnsResolver = dnsResolver
        self.fileSystem = fileSystem
        self.operatingSystem = operatingSystem
        self.makeToken = makeToken
    }

    static func live() -> DoctorDiagnosticRunner {
        DoctorDiagnosticRunner(
            commandRunner: ProcessCommandRunner(),
            dnsResolver: SystemDNSResolver(),
            fileSystem: .live,
            operatingSystem: .current
        )
    }

    func run(
        context: InstallationContext,
        mode: DoctorMode
    ) -> DoctorReport {
        var findings = configurationFindings(context)
        let docker = checkDocker()
        findings.append(docker)

        if docker.status == .ok {
            findings.append(checkNetwork(context))
            findings += checkContainers(context)
            findings.append(checkPostgreSQL(context, mode: mode))
            findings.append(checkRedis(context, mode: mode))
            findings.append(checkStorage(context, mode: mode))
            findings += checkApplicationServices(context)
        } else {
            findings += dockerDependentSkips(mode: mode)
        }

        findings += checkDNS(context)
        findings += checkPublicAccess(context)
        if mode == .full {
            findings += checkActivityPub(context)
        }

        return DoctorReport(mode: mode, findings: findings)
    }

    func checkPostgreSQL(
        _ context: InstallationContext,
        mode: DoctorMode
    ) -> DoctorFinding {
        guard let database = context.database else {
            return failure("PostgreSQL", "Configuration is missing.")
        }

        var arguments = diagnosticContainerArguments(
            networkName: context.resourceNames.networkName,
            requiresHostGateway: isLoopback(database.host)
        )
        arguments += [
            "--interactive",
            "--env", "PGPASSWORD",
            "--env", "PGSSLMODE",
            database.localResources?.image ?? DatabaseStep.postgresImage,
            "psql",
            "--host", containerHost(database.host),
            "--port", String(database.port),
            "--username", database.username,
            "--dbname", database.database,
            "--no-password",
            "--set", "ON_ERROR_STOP=1",
            "--tuples-only",
            "--no-align"
        ]

        let standardInput: String?
        if mode == .full {
            let schema = "vernissage_doctor_\(safeToken())"
            standardInput = """
            BEGIN;
            SELECT 1;
            CREATE SCHEMA \(schema) AUTHORIZATION CURRENT_USER;
            CREATE TABLE \(schema).permission_test (id BIGINT PRIMARY KEY);
            DROP TABLE \(schema).permission_test;
            DROP SCHEMA \(schema);
            COMMIT;
            """
        } else {
            arguments += ["--command", "SELECT 1;"]
            standardInput = nil
        }

        let outcome = execute(
            "docker",
            arguments: arguments,
            environment: [
                "PGPASSWORD": database.password.value,
                "PGSSLMODE": database.tlsMode.rawValue
            ],
            standardInput: standardInput
        )
        guard outcome.result?.succeeded == true else {
            return failure(
                "PostgreSQL",
                mode == .full
                    ? "The connection or migration permission test failed."
                    : "SELECT 1 failed.",
                details: outcome.details
            )
        }
        if mode == .standard,
           outcome.result?.standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines) != "1" {
            return failure(
                "PostgreSQL",
                "SELECT 1 returned an unexpected response.",
                details: outcome.result?.standardOutput
            )
        }
        return ok(
            "PostgreSQL",
            mode == .full
                ? "SELECT, CREATE TABLE, and DROP TABLE succeeded in a temporary schema."
                : "Connection and SELECT 1 succeeded."
        )
    }

    func checkRedis(
        _ context: InstallationContext,
        mode: DoctorMode
    ) -> DoctorFinding {
        guard let redis = context.redis else {
            return failure("Redis", "Configuration is missing.")
        }

        let ping = runRedis(["PING"], configuration: redis, context: context)
        guard ping.result?.succeeded == true,
              ping.result?.standardOutput == "PONG" else {
            return failure("Redis", "PING failed.", details: ping.details)
        }
        guard mode == .full else {
            return ok("Redis", "Connection and PING succeeded.")
        }

        let key = "vernissage:doctor:test:\(safeToken())"
        let value = "vernissage-doctor-\(safeToken())"
        let set = runRedis(
            ["SET", key, value, "EX", "60"],
            configuration: redis,
            context: context
        )
        guard set.result?.succeeded == true,
              set.result?.standardOutput == "OK" else {
            let cleanup = runRedis(
                ["DEL", key],
                configuration: redis,
                context: context
            )
            return failure(
                "Redis",
                "SET failed.",
                details: combinedDetails(set.details, cleanup: cleanup)
            )
        }

        let get = runRedis(["GET", key], configuration: redis, context: context)
        let delete = runRedis(["DEL", key], configuration: redis, context: context)
        guard get.result?.succeeded == true else {
            return failure(
                "Redis",
                "GET failed after the temporary key was written.",
                details: combinedDetails(get.details, cleanup: delete)
            )
        }
        guard get.result?.standardOutput == value else {
            return failure(
                "Redis",
                "GET returned a value different from the value written by SET.",
                details: combinedDetails(get.result?.standardOutput, cleanup: delete)
            )
        }
        guard delete.result?.succeeded == true,
              delete.result?.standardOutput == "1" else {
            return failure(
                "Redis",
                "DEL could not remove the temporary diagnostic key.",
                details: delete.details
            )
        }
        return ok("Redis", "PING, SET, GET, and DEL succeeded.")
    }

    func checkStorage(
        _ context: InstallationContext,
        mode: DoctorMode
    ) -> DoctorFinding {
        guard let storage = context.storage else {
            return failure("S3 storage", "Configuration is missing.")
        }

        let head = runAWSCLI(
            ["s3api", "head-bucket", "--bucket", storage.bucket],
            configuration: storage,
            context: context
        )
        guard head.result?.succeeded == true else {
            return failure(
                "S3 storage",
                "The configured bucket could not be accessed.",
                details: head.details
            )
        }
        guard mode == .full else {
            return ok("S3 storage", "The configured bucket is accessible.")
        }

        let objectKey = "vernissage-doctor/\(safeToken()).txt"
        let payload = "vernissage-storage-doctor-\(safeToken())"
        let objectURI = "s3://\(storage.bucket)/\(objectKey)"
        let upload = runAWSCLI(
            ["s3", "cp", "-", objectURI, "--only-show-errors"],
            configuration: storage,
            context: context,
            standardInput: payload
        )
        guard upload.result?.succeeded == true else {
            let cleanup = runAWSCLI(
                [
                    "s3api", "delete-object",
                    "--bucket", storage.bucket,
                    "--key", objectKey
                ],
                configuration: storage,
                context: context
            )
            return failure(
                "S3 storage",
                "Uploading a temporary object failed.",
                details: combinedDetails(upload.details, cleanup: cleanup)
            )
        }

        let download = runAWSCLI(
            ["s3", "cp", objectURI, "-", "--only-show-errors"],
            configuration: storage,
            context: context
        )
        let delete = runAWSCLI(
            [
                "s3api", "delete-object",
                "--bucket", storage.bucket,
                "--key", objectKey
            ],
            configuration: storage,
            context: context
        )

        guard download.result?.succeeded == true else {
            return failure(
                "S3 storage",
                "Downloading the temporary object failed.",
                details: combinedDetails(download.details, cleanup: delete)
            )
        }
        guard download.result?.standardOutput == payload else {
            return failure(
                "S3 storage",
                "The downloaded object differs from the uploaded object.",
                details: cleanupDetails(delete)
            )
        }
        guard delete.result?.succeeded == true else {
            return failure(
                "S3 storage",
                "The temporary object could not be deleted.",
                details: delete.details
            )
        }
        return ok(
            "S3 storage",
            "Bucket access, upload, download, comparison, and deletion succeeded."
        )
    }

    private func configurationFindings(
        _ context: InstallationContext
    ) -> [DoctorFinding] {
        var findings: [DoctorFinding] = []
        if let summary = context.summaryFilePath,
           fileSystem.fileExists(summary) {
            findings.append(ok("Configuration", "vernissage.yml was loaded successfully."))
        } else {
            findings.append(failure("Configuration", "vernissage.yml could not be confirmed on disk."))
        }

        if let secrets = context.secretsFilePath,
           fileSystem.fileExists(secrets) {
            if let permissions = fileSystem.permissions(secrets),
               permissions & 0o077 != 0 {
                findings.append(warning(
                    "Secrets file",
                    "vernissage.secrets.yml is readable by users other than its owner.",
                    details: String(format: "permissions %03o", permissions & 0o777)
                ))
            } else {
                findings.append(ok("Secrets file", "The secrets file exists with private permissions."))
            }
        } else {
            findings.append(failure("Secrets file", "vernissage.secrets.yml is missing."))
        }

        if let proxy = context.proxy {
            let dockerfile = URL(fileURLWithPath: proxy.buildContextPath)
                .appendingPathComponent("Dockerfile").path
            let configuration = URL(fileURLWithPath: proxy.buildContextPath)
                .appendingPathComponent("nginx.conf").path
            if fileSystem.fileExists(dockerfile),
               fileSystem.fileExists(configuration) {
                findings.append(ok("Proxy files", "Dockerfile and nginx.conf are available."))
            } else {
                findings.append(warning(
                    "Proxy files",
                    "Generated Proxy build files are incomplete; a future Proxy update may fail."
                ))
            }
        } else {
            findings.append(failure("Proxy files", "Proxy configuration is missing."))
        }

        if let caddy = context.caddy {
            findings.append(
                fileSystem.fileExists(caddy.caddyfilePath)
                    ? ok("Caddy file", "The generated Caddyfile is available.")
                    : warning(
                        "Caddy file",
                        "The generated Caddyfile is missing; a future Caddy update may fail."
                    )
            )
        } else {
            findings.append(skipped(
                "Caddy file",
                "HTTPS is managed manually outside vernissagectl."
            ))
        }
        return findings
    }

    private func checkDocker() -> DoctorFinding {
        let outcome = execute(
            "docker",
            arguments: ["info", "--format", "{{.ServerVersion}}"]
        )
        guard outcome.result?.succeeded == true,
              outcome.result?.standardOutput.isEmpty == false else {
            return failure(
                "Docker daemon",
                "Docker is unavailable or its daemon is not running.",
                details: outcome.details
            )
        }
        return ok(
            "Docker daemon",
            "Docker Server \(outcome.result?.standardOutput ?? "") is available."
        )
    }

    private func checkNetwork(_ context: InstallationContext) -> DoctorFinding {
        let name = context.resourceNames.networkName
        let outcome = execute(
            "docker",
            arguments: ["network", "inspect", name]
        )
        return outcome.result?.succeeded == true
            ? ok("Docker network", "\(name) exists.")
            : failure(
                "Docker network",
                "\(name) could not be inspected.",
                details: outcome.details
            )
    }

    private func checkContainers(
        _ context: InstallationContext
    ) -> [DoctorFinding] {
        let containers: [ManagedContainer]
        do {
            containers = try ManagedContainerInventory().containers(from: context)
        } catch {
            return [failure(
                "Containers",
                "The managed container inventory could not be created.",
                details: error.localizedDescription
            )]
        }

        let statuses: [ContainerStatus]
        do {
            statuses = try DockerContainerStatusReader(
                commandRunner: commandRunner
            ).read(containers: containers)
        } catch {
            return [failure(
                "Containers",
                "Docker container status could not be read.",
                details: error.localizedDescription
            )]
        }

        return statuses.map { status in
            if status.state == "missing" {
                return failure(
                    "Container \(status.service)",
                    "\(status.container) does not exist."
                )
            }
            if status.state != "running" {
                return failure(
                    "Container \(status.service)",
                    "\(status.container) is \(status.state)."
                )
            }
            if status.health == "unhealthy" {
                return failure(
                    "Container \(status.service)",
                    "\(status.container) is running but unhealthy."
                )
            }
            if status.health == "starting" {
                return warning(
                    "Container \(status.service)",
                    "\(status.container) is still starting."
                )
            }
            return ok(
                "Container \(status.service)",
                "\(status.container) is running."
            )
        }
    }

    private func checkApplicationServices(
        _ context: InstallationContext
    ) -> [DoctorFinding] {
        guard let services = context.serverServices,
              let web = context.web,
              let push = context.push,
              let proxy = context.proxy else {
            return [failure(
                "Application services",
                "API, Jobs, Web, Push, or Proxy configuration is missing."
            )]
        }

        let api = serverHealth(
            service: "API health",
            container: services.apiContainerName
        )
        let jobs = serverHealth(
            service: "Jobs health",
            container: services.jobsContainerName
        )
        var findings = [api.finding, jobs.finding]

        if let health = api.health {
            if health.isWebPushHealthy {
                findings.append(ok("WebPush health", "The API reports WebPush as healthy."))
            } else if push.isEnabled {
                findings.append(failure(
                    "WebPush health",
                    "WebPush is enabled but the API reports it as unhealthy."
                ))
            } else {
                findings.append(warning(
                    "WebPush health",
                    "WebPush remains disabled in the Vernissage settings."
                ))
            }
        } else {
            findings.append(skipped(
                "WebPush health",
                "The API health response was unavailable."
            ))
        }

        findings.append(checkNodeService(
            check: "Web application",
            container: web.containerName,
            script: "const response = await fetch('http://127.0.0.1:8080/robots.txt'); const body = await response.text(); if (!response.ok || !body.includes('User-agent:')) process.exit(1);"
        ))
        findings.append(checkNodeService(
            check: "Push service",
            container: push.containerName,
            script: "const response = await fetch('http://127.0.0.1:3000/'); const body = await response.text(); if (response.status !== 200 || !body.includes('Server is up and running...')) process.exit(1);"
        ))
        findings += checkProxyRoutes(
            diagnosticContainer: services.jobsContainerName,
            proxy: proxy
        )
        return findings
    }

    private func serverHealth(
        service: String,
        container: String
    ) -> (finding: DoctorFinding, health: ServerHealth?) {
        let outcome = execute(
            "docker",
            arguments: [
                "exec", container,
                "curl", "--fail-with-body", "--silent", "--show-error",
                "--max-time", "5",
                "http://127.0.0.1:8080/api/v1/health"
            ]
        )
        guard outcome.result?.succeeded == true,
              let output = outcome.result?.standardOutput,
              let health = try? JSONDecoder().decode(
                ServerHealth.self,
                from: Data(output.utf8)
              ) else {
            return (
                failure(
                    service,
                    "The health endpoint did not return a valid response.",
                    details: outcome.details
                ),
                nil
            )
        }
        guard health.isDatabaseHealthy,
              health.isQueueHealthy,
              health.isStorageHealthy else {
            return (
                failure(
                    service,
                    "The API reports an unhealthy PostgreSQL, Redis, or S3 dependency.",
                    details: healthDescription(health)
                ),
                health
            )
        }
        return (
            ok(service, "PostgreSQL, Redis, and S3 are healthy."),
            health
        )
    }

    private func checkNodeService(
        check: String,
        container: String,
        script: String
    ) -> DoctorFinding {
        let outcome = execute(
            "docker",
            arguments: [
                "exec", container,
                "node", "--input-type=module", "--eval", script
            ]
        )
        return outcome.result?.succeeded == true
            ? ok(check, "The internal endpoint responded successfully.")
            : failure(
                check,
                "The internal endpoint did not respond correctly.",
                details: outcome.details
            )
    }

    private func checkProxyRoutes(
        diagnosticContainer: String,
        proxy: ProxyConfiguration
    ) -> [DoctorFinding] {
        let base = "http://\(proxy.networkAlias):\(proxy.containerPort)"
        let api = dockerCurl(
            from: diagnosticContainer,
            url: "\(base)/api/v1/health",
            accept: "application/json"
        )
        let web = dockerCurl(
            from: diagnosticContainer,
            url: "\(base)/robots.txt",
            accept: "text/plain"
        )
        let json = dockerCurl(
            from: diagnosticContainer,
            url: "\(base)/",
            accept: "application/json"
        )

        return [
            api.result?.succeeded == true && validCoreHealth(api.result?.standardOutput)
                ? ok("Proxy API routing", "/api/v1 requests reach Vernissage API.")
                : failure(
                    "Proxy API routing",
                    "/api/v1 requests do not reach a healthy API.",
                    details: api.details
                ),
            web.result?.succeeded == true
                && web.result?.standardOutput.contains("User-agent:") == true
                ? ok("Proxy Web routing", "Browser requests reach Vernissage Web.")
                : failure(
                    "Proxy Web routing",
                    "Browser requests do not reach Vernissage Web.",
                    details: web.details
                ),
            json.result?.succeeded == true
                && json.result?.standardOutput == "Service is up and running!"
                ? ok("Proxy JSON routing", "JSON Accept headers reach Vernissage API.")
                : failure(
                    "Proxy JSON routing",
                    "JSON Accept headers do not reach Vernissage API.",
                    details: json.details
                )
        ]
    }

    private func checkDNS(_ context: InstallationContext) -> [DoctorFinding] {
        guard let domain = context.server?.domain else {
            return [failure("DNS", "The server domain is missing.")]
        }
        return dnsResolver.resolve(domain: domain).map { lookup in
            if lookup.addresses.isEmpty == false {
                return ok(
                    "DNS \(lookup.family.rawValue)",
                    "\(domain) resolves to \(lookup.addresses.joined(separator: ", "))."
                )
            }
            return warning(
                "DNS \(lookup.family.rawValue)",
                "No \(lookup.family.rawValue) address could be resolved for \(domain).",
                details: lookup.error
            )
        }
    }

    private func checkPublicAccess(
        _ context: InstallationContext
    ) -> [DoctorFinding] {
        guard let publicAccess = context.publicAccess else {
            return [failure("HTTPS endpoint", "Public access configuration is missing.")]
        }
        guard publicAccess.httpsMode != .manual else {
            return [
                skipped("HTTPS endpoint", "TLS and public routing are managed externally."),
                skipped("HTTPS certificate", "Certificate trust is managed externally.")
            ]
        }

        let web = publicCurl(
            context: context,
            path: "/robots.txt",
            accept: "text/plain"
        )
        let api = publicCurl(
            context: context,
            path: "/api/v1/health",
            accept: "application/json"
        )
        let webSucceeded = web.result?.succeeded == true
            && web.result?.standardOutput.contains("User-agent:") == true
        let apiSucceeded = api.result?.succeeded == true
            && validCoreHealth(api.result?.standardOutput)

        return [
            webSucceeded && apiSucceeded
                ? ok("HTTPS endpoint", "Web and API routing work over HTTPS.")
                : failure(
                    "HTTPS endpoint",
                    "Web or API routing over HTTPS failed.",
                    details: combinedDetails(web.details, secondary: api.details)
                ),
            webSucceeded
                ? ok("HTTPS certificate", "The configured certificate is trusted for the instance domain.")
                : failure(
                    "HTTPS certificate",
                    "TLS trust or hostname validation failed.",
                    details: web.details
                )
        ]
    }

    private func checkActivityPub(
        _ context: InstallationContext
    ) -> [DoctorFinding] {
        guard let server = context.server,
              let administrator = context.administrator else {
            return [failure(
                "ActivityPub endpoints",
                "The domain or administrator identity is missing."
            )]
        }
        let account = "acct:\(administrator.username)@\(server.domain)"
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "resource", value: account)]
        let query = components.percentEncodedQuery ?? ""

        let webFinger = accessCurl(
            context: context,
            path: "/.well-known/webfinger?\(query)",
            accept: "application/jrd+json"
        )
        let nodeInfo = accessCurl(
            context: context,
            path: "/.well-known/nodeinfo",
            accept: "application/json"
        )
        return [
            validJSON(webFinger)
                ? ok("WebFinger", "The administrator account resolves through WebFinger.")
                : failure(
                    "WebFinger",
                    "The WebFinger endpoint returned an error or invalid JSON.",
                    details: webFinger.details
                ),
            validJSON(nodeInfo)
                ? ok("NodeInfo", "The NodeInfo discovery endpoint returned valid JSON.")
                : failure(
                    "NodeInfo",
                    "The NodeInfo discovery endpoint returned an error or invalid JSON.",
                    details: nodeInfo.details
                )
        ]
    }

    private func dockerDependentSkips(mode: DoctorMode) -> [DoctorFinding] {
        var checks = [
            "Docker network", "Containers", "PostgreSQL", "Redis", "S3 storage",
            "API health", "Jobs health", "WebPush health", "Web application",
            "Push service", "Proxy API routing", "Proxy Web routing",
            "Proxy JSON routing"
        ]
        if mode == .full {
            checks.append("Active dependency tests")
        }
        return checks.map {
            skipped($0, "The check requires an available Docker daemon.")
        }
    }

    private func runRedis(
        _ command: [String],
        configuration: RedisConfiguration,
        context: InstallationContext
    ) -> CommandOutcome {
        var arguments = diagnosticContainerArguments(
            networkName: context.resourceNames.networkName,
            requiresHostGateway: isLoopback(configuration.host)
        )
        var environment: [String: String] = [:]
        if let password = configuration.password {
            arguments += ["--env", "REDISCLI_AUTH"]
            environment["REDISCLI_AUTH"] = password.value
        }
        arguments += [
            configuration.localResources?.image ?? RedisStep.redisImage,
            "redis-cli",
            "-h", containerHost(configuration.host),
            "-p", String(configuration.port),
            "-n", String(configuration.database),
            "--raw", "--no-auth-warning"
        ]
        if configuration.usesTLS {
            arguments.append("--tls")
        }
        arguments += command
        return execute("docker", arguments: arguments, environment: environment)
    }

    private func runAWSCLI(
        _ command: [String],
        configuration: StorageConfiguration,
        context: InstallationContext,
        standardInput: String? = nil
    ) -> CommandOutcome {
        let endpointHost = URLComponents(string: configuration.address)?.host
        var arguments = diagnosticContainerArguments(
            networkName: context.resourceNames.networkName,
            requiresHostGateway: endpointHost.map(isLoopback) ?? false
        )
        arguments += [
            "--interactive",
            "--env", "AWS_ACCESS_KEY_ID",
            "--env", "AWS_SECRET_ACCESS_KEY",
            "--env", "AWS_DEFAULT_REGION",
            "--env", "AWS_EC2_METADATA_DISABLED",
            "--env", "AWS_PAGER",
            StorageStep.awsCLIImage,
            "--no-cli-pager", "--color", "off"
        ]
        if configuration.provider != .awsS3 {
            arguments += [
                "--endpoint-url",
                replacingLoopbackHost(in: configuration.address)
            ]
        }
        arguments += command
        return execute(
            "docker",
            arguments: arguments,
            environment: [
                "AWS_ACCESS_KEY_ID": configuration.accessKeyId,
                "AWS_SECRET_ACCESS_KEY": configuration.secretAccessKey.value,
                "AWS_DEFAULT_REGION": configuration.region ?? "us-east-1",
                "AWS_EC2_METADATA_DISABLED": "true",
                "AWS_PAGER": ""
            ],
            standardInput: standardInput
        )
    }

    private func dockerCurl(
        from container: String,
        url: String,
        accept: String
    ) -> CommandOutcome {
        execute(
            "docker",
            arguments: [
                "exec", container,
                "curl", "--fail-with-body", "--silent", "--show-error",
                "--max-time", "5",
                "--header", "Accept: \(accept)",
                url
            ]
        )
    }

    private func publicCurl(
        context: InstallationContext,
        path: String,
        accept: String
    ) -> CommandOutcome {
        guard let domain = context.server?.domain,
              let publicAccess = context.publicAccess else {
            return CommandOutcome(result: nil, details: "Public access configuration is missing.")
        }
        var arguments = [
            "--fail-with-body", "--silent", "--show-error",
            "--max-time", "10", "--noproxy", "*",
            "--resolve", "\(domain):443:127.0.0.1",
            "--header", "Accept: \(accept)"
        ]
        if publicAccess.httpsMode == .development,
           let certificate = context.caddy?.localRootCertificatePath {
            arguments += ["--cacert", certificate]
        }
        arguments.append("https://\(domain)\(path)")
        return execute("curl", arguments: arguments)
    }

    private func accessCurl(
        context: InstallationContext,
        path: String,
        accept: String
    ) -> CommandOutcome {
        guard context.publicAccess?.httpsMode == .manual else {
            return publicCurl(context: context, path: path, accept: accept)
        }
        guard let domain = context.server?.domain,
              let port = context.proxy?.hostPort else {
            return CommandOutcome(
                result: nil,
                details: "The manually managed Proxy host port is unavailable."
            )
        }
        return execute(
            "curl",
            arguments: [
                "--fail-with-body", "--silent", "--show-error",
                "--max-time", "10",
                "--header", "Host: \(domain)",
                "--header", "Accept: \(accept)",
                "http://127.0.0.1:\(port)\(path)"
            ]
        )
    }

    private func diagnosticContainerArguments(
        networkName: String,
        requiresHostGateway: Bool
    ) -> [String] {
        var arguments = ["run", "--rm", "--network", networkName]
        if requiresHostGateway, operatingSystem == .linux {
            arguments += ["--add-host", "host.docker.internal:host-gateway"]
        }
        return arguments
    }

    private func containerHost(_ host: String) -> String {
        isLoopback(host) ? "host.docker.internal" : host
    }

    private func replacingLoopbackHost(in address: String) -> String {
        guard var components = URLComponents(string: address),
              let host = components.host,
              isLoopback(host) else {
            return address
        }
        components.host = "host.docker.internal"
        return components.string ?? address
    }

    private func isLoopback(_ host: String) -> Bool {
        let value = host.lowercased()
        return value == "localhost"
            || value == "localhost."
            || value.hasPrefix("127.")
            || value == "::1"
            || value == "0:0:0:0:0:0:0:1"
    }

    private func validCoreHealth(_ output: String?) -> Bool {
        guard let output,
              let health = try? JSONDecoder().decode(
                ServerHealth.self,
                from: Data(output.utf8)
              ) else {
            return false
        }
        return health.isDatabaseHealthy
            && health.isQueueHealthy
            && health.isStorageHealthy
    }

    private func validJSON(_ outcome: CommandOutcome) -> Bool {
        guard outcome.result?.succeeded == true,
              let output = outcome.result?.standardOutput,
              let data = output.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) != nil else {
            return false
        }
        return true
    }

    private func healthDescription(_ health: ServerHealth) -> String {
        "database=\(health.isDatabaseHealthy), queue=\(health.isQueueHealthy), webPush=\(health.isWebPushHealthy), storage=\(health.isStorageHealthy)"
    }

    private func safeToken() -> String {
        let value = makeToken().lowercased().filter {
            $0.isASCII && ($0.isLetter || $0.isNumber)
        }
        return String((value.isEmpty ? "diagnostic" : value).prefix(32))
    }

    private func combinedDetails(
        _ first: String?,
        secondary: String?
    ) -> String? {
        [first, secondary]
            .compactMap { $0 }
            .filter { $0.isEmpty == false }
            .joined(separator: "; ")
            .nilIfEmpty
    }

    private func combinedDetails(
        _ primary: String?,
        cleanup: CommandOutcome
    ) -> String? {
        combinedDetails(primary, secondary: cleanupDetails(cleanup))
    }

    private func cleanupDetails(_ cleanup: CommandOutcome) -> String? {
        guard cleanup.result?.succeeded != true else { return nil }
        return "temporary-data cleanup failed: \(cleanup.details ?? "unknown error")"
    }

    private func execute(
        _ executable: String,
        arguments: [String],
        environment: [String: String] = [:],
        standardInput: String? = nil
    ) -> CommandOutcome {
        do {
            let result = try commandRunner.run(
                executable,
                arguments: arguments,
                environment: environment,
                standardInput: standardInput
            )
            return CommandOutcome(
                result: result,
                details: result.succeeded ? nil : commandFailureDetails(result)
            )
        } catch {
            return CommandOutcome(result: nil, details: error.localizedDescription)
        }
    }

    private func commandFailureDetails(_ result: CommandResult) -> String {
        if result.standardError.isEmpty == false { return result.standardError }
        if result.standardOutput.isEmpty == false { return result.standardOutput }
        return "\(result.exitCode)"
    }

    private func ok(_ check: String, _ message: String) -> DoctorFinding {
        DoctorFinding(check: check, status: .ok, message: message)
    }

    private func warning(
        _ check: String,
        _ message: String,
        details: String? = nil
    ) -> DoctorFinding {
        DoctorFinding(
            check: check,
            status: .warning,
            message: message,
            details: details
        )
    }

    private func failure(
        _ check: String,
        _ message: String,
        details: String? = nil
    ) -> DoctorFinding {
        DoctorFinding(
            check: check,
            status: .failure,
            message: message,
            details: details
        )
    }

    private func skipped(_ check: String, _ message: String) -> DoctorFinding {
        DoctorFinding(check: check, status: .skipped, message: message)
    }
}

private struct CommandOutcome {
    let result: CommandResult?
    let details: String?
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
