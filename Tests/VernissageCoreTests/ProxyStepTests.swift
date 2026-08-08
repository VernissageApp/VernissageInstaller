import Foundation
import Testing
@testable import VernissageCore

@Suite(.tags(.networking, .proxy))
struct ProxyStepTests {
    @Test
    func `Proxy build files are placed under the working directory`() {
        let workingDirectory = URL(
            fileURLWithPath: "/srv/vernissage-installer",
            isDirectory: true
        )

        let buildContext = ProxyStep.buildContextURL(in: workingDirectory)

        #expect(buildContext.path == "/srv/vernissage-installer/vernissage/proxy")
    }

    @Test
    func `Generated proxy routes API Web and JSON requests through public port 8080`() throws {
        let runner = ProxyCommandRunner(results: successfulResults())
        let buildContext = ProxyBuildContextRecorder()
        let output = ProxyOutputBuffer()
        let context = makeContext()
        let step = makeStep(
            runner: runner,
            buildContext: buildContext,
            output: output,
            input: ProxyInputQueue([""])
        )

        try step.run(context: context)

        let configuration = try #require(context.proxy)
        #expect(configuration.image == "vernissage-proxy:abcdefgh")
        #expect(configuration.containerName == "vernissage-abcdefgh-proxy")
        #expect(configuration.networkName == "vernissage-abcdefgh-network")
        #expect(configuration.networkAlias == "vernissage-proxy.internal")
        #expect(configuration.hostPort == 8080)
        #expect(configuration.containerPort == 8080)
        #expect(configuration.apiUpstream == "vernissage-api.internal:8080")
        #expect(configuration.webUpstream == "vernissage-web.internal:8080")
        #expect(configuration.publicHTTPAddress == "http://social.example.com:8080")
        #expect(configuration.buildContextPath == "/tmp/vernissage-proxy-build")

        let dockerfile = try #require(buildContext.dockerfile)
        #expect(dockerfile.contains("FROM nginx:latest"))
        #expect(dockerfile.contains("COPY nginx.conf /etc/nginx/conf.d/default.conf"))
        #expect(dockerfile.contains("EXPOSE 8080"))

        let nginx = try #require(buildContext.nginxConfiguration)
        #expect(nginx.contains("server vernissage-api.internal:8080"))
        #expect(nginx.contains("server vernissage-web.internal:8080"))
        #expect(nginx.contains("location /api/v1/"))
        #expect(nginx.contains("location /.well-known/"))
        #expect(nginx.contains("location /rss/"))
        #expect(nginx.contains("location /atom/"))
        #expect(nginx.contains("~*json 1"))
        #expect(nginx.contains("if ($vernissage_route_to_api)"))
        #expect(nginx.contains("error_page 418 = @vernissage_api_by_header"))
        #expect(nginx.contains("location @vernissage_api_by_header"))
        #expect(nginx.contains("proxy_pass http://vernissage_web"))
        #expect(nginx.contains("proxy_pass http://$vernissage_upstream") == false)
        #expect(nginx.contains("proxy_set_header X-Forwarded-Proto"))
        #expect(nginx.contains("location /static-resource/") == false)
        #expect(nginx.contains("[fdaa::3]") == false)

        let build = runner.invocations[2]
        #expect(build.executable == "docker")
        #expect(build.arguments == [
            "build", "--tag", "vernissage-proxy:abcdefgh", "/tmp/vernissage-proxy-build"
        ])

        let validation = runner.invocations[3]
        #expect(validation.arguments.containsSequence(["--network", "vernissage-abcdefgh-network"]))
        #expect(validation.arguments.suffix(3) == ["vernissage-proxy:abcdefgh", "nginx", "-t"])

        let start = runner.invocations[4]
        #expect(start.arguments.containsSequence(["--publish", "8080:8080"]))
        #expect(start.arguments.containsSequence(["--network-alias", "vernissage-proxy.internal"]))
        #expect(start.arguments.last == "vernissage-proxy:abcdefgh")

        let apiCheck = runner.invocations[5]
        #expect(apiCheck.executable == "curl")
        #expect(apiCheck.arguments.contains("http://127.0.0.1:8080/api/v1/health"))
        #expect(apiCheck.arguments.contains("Host: social.example.com"))

        let webCheck = runner.invocations[6]
        #expect(webCheck.arguments.contains("http://127.0.0.1:8080/robots.txt"))
        #expect(webCheck.arguments.contains("Accept: text/plain"))

        let headerCheck = runner.invocations[7]
        #expect(headerCheck.arguments.contains("http://127.0.0.1:8080/"))
        #expect(headerCheck.arguments.contains("Accept: application/json"))

        #expect(output.text.contains(InstallationStepGuidance.proxy))
        #expect(output.text.contains("routing was verified"))
        #expect(output.text.contains("must be protected by your external TLS terminator"))
    }

    @Test
    func `Generated proxy exposes local MinIO through static resource path`() {
        let nginx = ProxyStep.makeNginxConfiguration(
            apiUpstream: "vernissage-api.internal:8080",
            webUpstream: "vernissage-web.internal:8080",
            minIOUpstream: "vernissage-abcdefgh-minio:9000"
        )

        #expect(nginx.contains("upstream vernissage_minio"))
        #expect(nginx.contains("server vernissage-abcdefgh-minio:9000"))
        #expect(nginx.contains("location /static-resource/"))
        #expect(nginx.contains("limit_except GET HEAD"))
        #expect(nginx.contains("proxy_pass http://vernissage_minio/vernissage/;"))
    }

    @Test
    func `Custom Proxy port is published stored and used for readiness checks`() throws {
        let runner = ProxyCommandRunner(results: successfulResults())
        let context = makeContext()
        let step = makeStep(
            runner: runner,
            buildContext: ProxyBuildContextRecorder(),
            output: ProxyOutputBuffer(),
            input: ProxyInputQueue(["9090"])
        )

        try step.run(context: context)

        let configuration = try #require(context.proxy)
        #expect(configuration.hostPort == 9090)
        #expect(configuration.containerPort == 8080)
        #expect(configuration.publicHTTPAddress == "http://social.example.com:9090")
        #expect(runner.invocations[4].arguments.containsSequence(["--publish", "9090:8080"]))
        for invocation in runner.invocations[5...] {
            #expect(
                invocation.arguments.contains { $0.hasPrefix("http://127.0.0.1:9090/") }
            )
        }
    }

    @Test
    func `Caddy mode keeps Proxy private and verifies it through API container`() throws {
        let runner = ProxyCommandRunner(results: successfulResults())
        let context = makeContext()
        context.publicAccess = PublicAccessConfiguration(httpsMode: .development)
        let step = makeStep(
            runner: runner,
            buildContext: ProxyBuildContextRecorder(),
            output: ProxyOutputBuffer(),
            input: ProxyInputQueue(["9090"])
        )

        try step.run(context: context)

        let configuration = try #require(context.proxy)
        #expect(configuration.hostPort == nil)
        #expect(configuration.publicHTTPAddress == nil)

        let start = runner.invocations[4]
        #expect(start.arguments.contains("--publish") == false)

        for invocation in runner.invocations[5...] {
            #expect(invocation.executable == "docker")
            #expect(invocation.arguments.starts(with: ["exec", "vernissage-abcdefgh-api", "curl"]))
            #expect(
                invocation.arguments.contains {
                    $0.hasPrefix("http://vernissage-proxy.internal:8080/")
                }
            )
        }
    }

    @Test
    func `Invalid Proxy ports are requested again`() throws {
        let runner = ProxyCommandRunner(results: successfulResults())
        let output = ProxyOutputBuffer()
        let context = makeContext()
        let step = makeStep(
            runner: runner,
            buildContext: ProxyBuildContextRecorder(),
            output: output,
            input: ProxyInputQueue(["0", "65536", "not-a-port", "8443"])
        )

        try step.run(context: context)

        #expect(context.proxy?.hostPort == 8443)
        #expect(runner.invocations[4].arguments.containsSequence(["--publish", "8443:8080"]))
        #expect(
            output.text.components(separatedBy: "Enter a port number between 1 and 65535.").count - 1 == 3
        )
    }

    @Test
    func `Proxy readiness retries all public routes after startup delay`() throws {
        let runner = ProxyCommandRunner(results: [
            .failure("container not found"),
            .success("vernissage-abcdefgh-network"),
            .success("image built"),
            .success("nginx configuration is valid"),
            .success("proxy-container-id"),
            .failure("connection refused"),
            .success(Self.healthyResponse),
            .success("User-agent: *"),
            .success("Service is up and running!")
        ])
        let retries = ProxyRetryCounter()
        let context = makeContext()
        let step = makeStep(
            runner: runner,
            buildContext: ProxyBuildContextRecorder(),
            output: ProxyOutputBuffer(),
            waitBeforeRetry: retries.increment
        )

        try step.run(context: context)

        #expect(retries.value == 1)
        #expect(context.proxy != nil)
        #expect(runner.invocations.count == 9)
    }

    @Test
    func `Incorrect header routing preserves Proxy container for diagnostics`() {
        let runner = ProxyCommandRunner(results: [
            .failure("container not found"),
            .success("vernissage-abcdefgh-network"),
            .success("image built"),
            .success("nginx configuration is valid"),
            .success("proxy-container-id"),
            .success(Self.healthyResponse),
            .success("User-agent: *"),
            .success("<!doctype html>")
        ])
        let context = makeContext()
        let step = makeStep(
            runner: runner,
            buildContext: ProxyBuildContextRecorder(),
            output: ProxyOutputBuffer(),
            readinessAttempts: 1
        )

        let error = #expect(throws: ProxyStepError.self) {
            try step.run(context: context)
        }

        #expect(
            error == .startupTimedOut(
                "JSON Accept-header routing did not return the Vernissage API root response."
            )
        )
        #expect(context.proxy == nil)
        #expect(
            runner.invocations.contains {
                $0.arguments.first == "container" && $0.arguments.contains("rm")
            } == false
        )
    }

    @Test
    func `Existing Proxy container is never rebuilt or replaced`() {
        let runner = ProxyCommandRunner(results: [.success("existing-container")])
        let buildContext = ProxyBuildContextRecorder()
        let context = makeContext()
        let step = makeStep(
            runner: runner,
            buildContext: buildContext,
            output: ProxyOutputBuffer()
        )

        let error = #expect(throws: ProxyStepError.self) {
            try step.run(context: context)
        }

        #expect(error == .containerAlreadyExists("vernissage-abcdefgh-proxy"))
        #expect(buildContext.dockerfile == nil)
        #expect(buildContext.nginxConfiguration == nil)
        #expect(context.proxy == nil)
        #expect(runner.invocations.count == 1)
    }

    @Test
    func `Missing Web configuration performs no file or Docker operations`() {
        let runner = ProxyCommandRunner(results: [])
        let buildContext = ProxyBuildContextRecorder()
        let context = makeContext()
        context.web = nil
        let step = makeStep(
            runner: runner,
            buildContext: buildContext,
            output: ProxyOutputBuffer()
        )

        let error = #expect(throws: ProxyStepError.self) {
            try step.run(context: context)
        }

        #expect(error == .missingConfiguration("Vernissage Web"))
        #expect(buildContext.dockerfile == nil)
        #expect(runner.invocations.isEmpty)
    }

    @Test
    func `Missing public access choice performs no file or Docker operations`() {
        let runner = ProxyCommandRunner(results: [])
        let buildContext = ProxyBuildContextRecorder()
        let context = makeContext()
        context.publicAccess = nil
        let step = makeStep(
            runner: runner,
            buildContext: buildContext,
            output: ProxyOutputBuffer()
        )

        let error = #expect(throws: ProxyStepError.self) {
            try step.run(context: context)
        }

        #expect(error == .missingConfiguration("HTTPS and public access"))
        #expect(buildContext.dockerfile == nil)
        #expect(runner.invocations.isEmpty)
    }

    @Test
    func `Build context failure stops before image build`() {
        let runner = ProxyCommandRunner(results: [
            .failure("container not found"),
            .success("vernissage-abcdefgh-network")
        ])
        let context = makeContext()
        let step = ProxyStep(
            console: Console(
                colorsEnabled: false,
                readInput: { nil },
                writeOutput: { _ in }
            ),
            commandRunner: runner,
            waitBeforeRetry: {},
            prepareBuildContext: { _, _ in
                throw ProxyBuildContextError.permissionDenied
            }
        )

        let error = #expect(throws: ProxyStepError.self) {
            try step.run(context: context)
        }

        #expect(error == .buildContextPreparationFailed("permissionDenied"))
        #expect(context.proxy == nil)
        #expect(runner.invocations.count == 2)
    }

    private func makeStep(
        runner: ProxyCommandRunner,
        buildContext: ProxyBuildContextRecorder,
        output: ProxyOutputBuffer,
        input: ProxyInputQueue = ProxyInputQueue([]),
        waitBeforeRetry: @escaping () -> Void = {},
        readinessAttempts: Int = 3
    ) -> ProxyStep {
        ProxyStep(
            console: Console(
                colorsEnabled: false,
                readInput: input.next,
                writeOutput: output.append
            ),
            commandRunner: runner,
            waitBeforeRetry: waitBeforeRetry,
            readinessAttempts: readinessAttempts,
            prepareBuildContext: buildContext.prepare
        )
    }

    private func makeContext() -> InstallationContext {
        let context = InstallationContext(instanceIdentifier: "abcdefgh")
        context.server = ServerConfiguration(domain: "social.example.com")
        let health = ServerHealth(
            isDatabaseHealthy: true,
            isQueueHealthy: true,
            isWebPushHealthy: false,
            isStorageHealthy: true
        )
        context.serverServices = ServerServicesConfiguration(
            image: "mczachurski/vernissage-server:latest",
            networkName: "vernissage-abcdefgh-network",
            apiContainerName: "vernissage-abcdefgh-api",
            jobsContainerName: "vernissage-abcdefgh-jobs",
            apiNetworkAlias: "vernissage-api.internal",
            jobsNetworkAlias: "vernissage-jobs.internal",
            baseAddress: "https://social.example.com",
            apiHealth: health,
            jobsHealth: health,
            databaseTables: ["Users"]
        )
        context.web = WebConfiguration(
            image: "mczachurski/vernissage-web:latest",
            containerName: "vernissage-abcdefgh-web",
            networkName: "vernissage-abcdefgh-network",
            networkAlias: "vernissage-web.internal",
            allowedHosts: "social.example.com,*.social.example.com",
            cspImageSource: nil
        )
        context.publicAccess = PublicAccessConfiguration(httpsMode: .manual)
        return context
    }

    private func successfulResults() -> [CommandResult] {
        [
            .failure("container not found"),
            .success("vernissage-abcdefgh-network"),
            .success("image built"),
            .success("nginx configuration is valid"),
            .success("proxy-container-id"),
            .success(Self.healthyResponse),
            .success("User-agent: GPTBot\nDisallow: /"),
            .success("Service is up and running!")
        ]
    }

    private static let healthyResponse = """
    {"isDatabaseHealthy":true,"isQueueHealthy":true,"isWebPushHealthy":false,"isStorageHealthy":true}
    """
}

private struct ProxyCommandInvocation {
    let executable: String
    let arguments: [String]
}

private enum ProxyCommandRunnerError: Error {
    case resultNotConfigured
}

private final class ProxyCommandRunner: CommandRunning {
    private var results: [CommandResult]
    private(set) var invocations: [ProxyCommandInvocation] = []

    init(results: [CommandResult]) {
        self.results = results
    }

    func run(
        _ executable: String,
        arguments: [String],
        environment: [String: String],
        standardInput: String?
    ) throws -> CommandResult {
        invocations.append(
            ProxyCommandInvocation(
                executable: executable,
                arguments: arguments
            )
        )
        guard results.isEmpty == false else {
            throw ProxyCommandRunnerError.resultNotConfigured
        }
        return results.removeFirst()
    }
}

private enum ProxyBuildContextError: LocalizedError {
    case permissionDenied

    var errorDescription: String? {
        "permissionDenied"
    }
}

private final class ProxyBuildContextRecorder {
    private(set) var dockerfile: String?
    private(set) var nginxConfiguration: String?

    func prepare(dockerfile: String, nginxConfiguration: String) -> URL {
        self.dockerfile = dockerfile
        self.nginxConfiguration = nginxConfiguration
        return URL(fileURLWithPath: "/tmp/vernissage-proxy-build", isDirectory: true)
    }
}

private final class ProxyOutputBuffer {
    private(set) var text = ""

    func append(_ value: String) {
        text += value
    }
}

private final class ProxyInputQueue {
    private var values: [String]

    init(_ values: [String]) {
        self.values = values
    }

    func next() -> String? {
        guard values.isEmpty == false else { return nil }
        return values.removeFirst()
    }
}

private final class ProxyRetryCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private extension Array where Element == String {
    func containsSequence(_ sequence: [String]) -> Bool {
        guard sequence.isEmpty == false, sequence.count <= count else { return false }
        return indices.contains { index in
            let end = index + sequence.count
            guard end <= count else { return false }
            return Array(self[index..<end]) == sequence
        }
    }
}

private extension CommandResult {
    static func success(_ output: String) -> CommandResult {
        CommandResult(exitCode: 0, standardOutput: output, standardError: "")
    }

    static func failure(_ error: String) -> CommandResult {
        CommandResult(exitCode: 1, standardOutput: "", standardError: error)
    }
}
