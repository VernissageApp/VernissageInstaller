import Foundation
import Testing
@testable import VernissageCore

@Suite(.tags(.https, .networking))
struct CaddyStepTests {
    @Test
    func `Development HTTPS installs Caddy and exports local root certificate`() throws {
        let runner = CaddyCommandRunner(results: developmentResults())
        let configuration = CaddyConfigurationRecorder()
        let output = CaddyOutputBuffer()
        let context = makeContext(mode: .development)
        let step = makeStep(
            runner: runner,
            configuration: configuration,
            output: output,
            operatingSystem: .macOS
        )

        try step.run(context: context)

        let caddy = try #require(context.caddy)
        #expect(caddy.image == "caddy:latest")
        #expect(caddy.containerName == "vernissage-abcdefgh-caddy")
        #expect(caddy.networkName == "vernissage-abcdefgh-network")
        #expect(caddy.networkAlias == "vernissage-caddy.internal")
        #expect(caddy.dataVolumeName == "vernissage-abcdefgh-caddy-data")
        #expect(caddy.configVolumeName == "vernissage-abcdefgh-caddy-config")
        #expect(caddy.caddyfilePath == "/tmp/vernissage-caddy/Caddyfile")
        #expect(caddy.publicHTTPSAddress == "https://social.example.com")
        #expect(caddy.localRootCertificatePath == "/tmp/vernissage-caddy/root.crt")

        let caddyfile = try #require(configuration.caddyfile)
        #expect(caddyfile.contains("social.example.com"))
        #expect(caddyfile.contains("tls internal"))
        #expect(caddyfile.contains("reverse_proxy vernissage-proxy.internal:8080"))
        #expect(caddyfile.contains("acme-v02.api.letsencrypt.org") == false)

        let start = runner.invocations[6]
        #expect(start.arguments.containsSequence(["--publish", "80:80"]))
        #expect(start.arguments.containsSequence(["--publish", "443:443"]))
        #expect(start.arguments.containsSequence(["--publish", "443:443/udp"]))
        #expect(start.arguments.containsSequence(["--network", "vernissage-abcdefgh-network"]))
        #expect(start.arguments.containsSequence(["--network-alias", "vernissage-caddy.internal"]))
        #expect(
            start.arguments.containsSequence([
                "--mount",
                "type=bind,source=/tmp/vernissage-caddy,target=/etc/caddy,readonly"
            ])
        )

        let export = runner.invocations[9]
        #expect(export.arguments == [
            "cp",
            "vernissage-abcdefgh-caddy:/data/caddy/pki/authorities/local/root.crt",
            "/tmp/vernissage-caddy/root.crt"
        ])
        for request in runner.invocations[10...11] {
            #expect(request.arguments.containsSequence(["--cacert", "/tmp/vernissage-caddy/root.crt"]))
            #expect(request.arguments.contains("--insecure") == false)
        }
        #expect(output.text.contains("Always Trust"))
        #expect(output.text.contains("private CA key"))
        #expect(output.text.contains("✓ Vernissage is available through Caddy over HTTPS."))
        #expect(output.text.contains("  HTTPS endpoint: https://social.example.com"))
        #expect(output.text.hasSuffix("\n\n"))
    }

    @Test
    func `Production HTTPS configures Let's Encrypt and system trust`() throws {
        let runner = CaddyCommandRunner(results: productionResults())
        let configuration = CaddyConfigurationRecorder()
        let output = CaddyOutputBuffer()
        let context = makeContext(mode: .production)
        let step = makeStep(
            runner: runner,
            configuration: configuration,
            output: output
        )

        try step.run(context: context)

        let caddy = try #require(context.caddy)
        #expect(caddy.publicHTTPSAddress == "https://social.example.com")
        #expect(caddy.localRootCertificatePath == nil)

        let caddyfile = try #require(configuration.caddyfile)
        #expect(caddyfile.contains("email admin@example.com"))
        #expect(caddyfile.contains("acme_ca https://acme-v02.api.letsencrypt.org/directory"))
        #expect(caddyfile.contains("tls internal") == false)

        for request in runner.invocations[7...8] {
            #expect(request.executable == "curl")
            #expect(request.arguments.contains("--insecure") == false)
            #expect(request.arguments.contains("--cacert") == false)
            #expect(request.arguments.containsSequence(["--noproxy", "*"]))
            #expect(request.arguments.containsSequence(["--resolve", "social.example.com:443:127.0.0.1"]))
        }
        #expect(output.text.contains("publicly trusted"))
    }

    @Test
    func `Manual HTTPS performs no Caddy or file operations`() throws {
        let runner = CaddyCommandRunner(results: [])
        let configuration = CaddyConfigurationRecorder()
        let output = CaddyOutputBuffer()
        let context = makeContext(mode: .manual, proxyHostPort: 8080)
        let step = makeStep(
            runner: runner,
            configuration: configuration,
            output: output
        )

        try step.run(context: context)

        #expect(context.caddy == nil)
        #expect(configuration.caddyfile == nil)
        #expect(runner.invocations.isEmpty)
        #expect(output.text.contains("http://social.example.com:8080"))
    }

    @Test
    func `Existing Caddy container is never replaced`() {
        let runner = CaddyCommandRunner(results: [.success("existing-container")])
        let configuration = CaddyConfigurationRecorder()
        let context = makeContext(mode: .production)
        let step = makeStep(
            runner: runner,
            configuration: configuration,
            output: CaddyOutputBuffer()
        )

        let error = #expect(throws: CaddyStepError.self) {
            try step.run(context: context)
        }

        #expect(error == .containerAlreadyExists("vernissage-abcdefgh-caddy"))
        #expect(context.caddy == nil)
        #expect(configuration.caddyfile == nil)
        #expect(runner.invocations.count == 1)
    }

    @Test
    func `Unavailable HTTPS endpoint is retried and container is preserved`() {
        let runner = CaddyCommandRunner(results: [
            .failure("container not found"),
            .success("vernissage-abcdefgh-network"),
            .success("image pulled"),
            .success("vernissage-abcdefgh-caddy-data"),
            .success("vernissage-abcdefgh-caddy-config"),
            .success("configuration valid"),
            .success("caddy-container-id"),
            .failure("connection refused"),
            .failure("connection refused")
        ])
        let retries = CaddyRetryCounter()
        let context = makeContext(mode: .production)
        let step = makeStep(
            runner: runner,
            configuration: CaddyConfigurationRecorder(),
            output: CaddyOutputBuffer(),
            waitBeforeRetry: retries.increment,
            readinessAttempts: 2
        )

        let error = #expect(throws: CaddyStepError.self) {
            try step.run(context: context)
        }

        #expect(error == .startupTimedOut("connection refused"))
        #expect(retries.value == 1)
        #expect(context.caddy == nil)
        #expect(
            runner.invocations.contains {
                $0.arguments.first == "container" && $0.arguments.contains("rm")
            } == false
        )
    }

    @Test
    func `Missing Proxy configuration performs no operations`() {
        let runner = CaddyCommandRunner(results: [])
        let context = makeContext(mode: .production)
        context.proxy = nil
        let step = makeStep(
            runner: runner,
            configuration: CaddyConfigurationRecorder(),
            output: CaddyOutputBuffer()
        )

        let error = #expect(throws: CaddyStepError.self) {
            try step.run(context: context)
        }

        #expect(error == .missingConfiguration("Vernissage Proxy"))
        #expect(runner.invocations.isEmpty)
    }

    private func makeStep(
        runner: CaddyCommandRunner,
        configuration: CaddyConfigurationRecorder,
        output: CaddyOutputBuffer,
        waitBeforeRetry: @escaping () -> Void = {},
        readinessAttempts: Int = 3,
        operatingSystem: HostOperatingSystem = .linux
    ) -> CaddyStep {
        CaddyStep(
            console: Console(
                colorsEnabled: false,
                readInput: { nil },
                writeOutput: output.append
            ),
            commandRunner: runner,
            waitBeforeRetry: waitBeforeRetry,
            readinessAttempts: readinessAttempts,
            operatingSystem: operatingSystem,
            prepareConfiguration: configuration.prepare
        )
    }

    private func makeContext(
        mode: HTTPSMode,
        proxyHostPort: UInt16? = nil
    ) -> InstallationContext {
        let context = InstallationContext(instanceIdentifier: "abcdefgh")
        context.server = ServerConfiguration(domain: "social.example.com")
        context.administrator = AdministratorConfiguration(
            userId: 123,
            name: "Administrator",
            email: "admin@example.com",
            username: "admin-user",
            password: Secret(value: "secret-password"),
            accessToken: Secret(value: "access-token")
        )
        context.publicAccess = PublicAccessConfiguration(httpsMode: mode)
        context.proxy = ProxyConfiguration(
            image: "vernissage-proxy:abcdefgh",
            containerName: "vernissage-abcdefgh-proxy",
            networkName: "vernissage-abcdefgh-network",
            networkAlias: "vernissage-proxy.internal",
            hostPort: proxyHostPort,
            containerPort: 8080,
            apiUpstream: "vernissage-api.internal:8080",
            webUpstream: "vernissage-web.internal:8080",
            publicHTTPAddress: proxyHostPort.map { "http://social.example.com:\($0)" },
            buildContextPath: "/tmp/vernissage-proxy"
        )
        return context
    }

    private func developmentResults() -> [CommandResult] {
        productionResults() + [
            .success("certificate copied"),
            .success(Self.robots),
            .success(Self.health)
        ]
    }

    private func productionResults() -> [CommandResult] {
        [
            .failure("container not found"),
            .success("vernissage-abcdefgh-network"),
            .success("image pulled"),
            .success("vernissage-abcdefgh-caddy-data"),
            .success("vernissage-abcdefgh-caddy-config"),
            .success("configuration valid"),
            .success("caddy-container-id"),
            .success(Self.robots),
            .success(Self.health)
        ]
    }

    private static let robots = "User-agent: *\nDisallow: /assets/"
    private static let health = """
    {"isDatabaseHealthy":true,"isQueueHealthy":true,"isWebPushHealthy":false,"isStorageHealthy":true}
    """
}

private struct CaddyCommandInvocation {
    let executable: String
    let arguments: [String]
}

private enum CaddyCommandRunnerError: Error {
    case resultNotConfigured
}

private final class CaddyCommandRunner: CommandRunning {
    private var results: [CommandResult]
    private(set) var invocations: [CaddyCommandInvocation] = []

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
            CaddyCommandInvocation(
                executable: executable,
                arguments: arguments
            )
        )
        guard results.isEmpty == false else {
            throw CaddyCommandRunnerError.resultNotConfigured
        }
        return results.removeFirst()
    }
}

private final class CaddyConfigurationRecorder {
    private(set) var caddyfile: String?

    func prepare(_ caddyfile: String) -> URL {
        self.caddyfile = caddyfile
        return URL(fileURLWithPath: "/tmp/vernissage-caddy/Caddyfile")
    }
}

private final class CaddyOutputBuffer {
    private(set) var text = ""

    func append(_ value: String) {
        text += value
    }
}

private final class CaddyRetryCounter {
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
