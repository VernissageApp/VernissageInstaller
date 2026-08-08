import Foundation
import Testing
@testable import VernissageCore

struct DoctorCommandTests {
    @Test
    func `Doctor command defaults to standard read-only diagnostics`() throws {
        let parsed = try VernissageCommand.parseAsRoot([
            "doctor", "--config", "/srv/vernissage/vernissage.yml"
        ])
        let command = try #require(parsed as? DoctorCommand)

        #expect(command.full == false)
        #expect(command.noColor == false)
        #expect(
            command.configurationOptions.configPath
                == "/srv/vernissage/vernissage.yml"
        )
    }

    @Test
    func `Full doctor option enables active diagnostics`() throws {
        let parsed = try VernissageCommand.parseAsRoot([
            "--config", "/srv/vernissage/vernissage.yml",
            "doctor", "--full", "--no-color"
        ])
        let command = try #require(parsed as? DoctorCommand)

        #expect(command.full)
        #expect(command.noColor)
    }

    @Test
    func `Doctor report fails only when a failure is present`() {
        let warningReport = DoctorReport(
            mode: .standard,
            findings: [
                DoctorFinding(
                    check: "DNS AAAA",
                    status: .warning,
                    message: "No AAAA record was found."
                )
            ]
        )
        let failureReport = DoctorReport(
            mode: .standard,
            findings: warningReport.findings + [
                DoctorFinding(
                    check: "API health",
                    status: .failure,
                    message: "The API is unavailable."
                )
            ]
        )

        #expect(warningReport.hasFailures == false)
        #expect(warningReport.warningCount == 1)
        #expect(failureReport.hasFailures)
        #expect(failureReport.failureCount == 1)
    }

    @Test
    func `Doctor report renders every diagnostic status and summary`() {
        var output = ""
        let console = Console(
            colorsEnabled: false,
            writeOutput: { output += $0 }
        )
        let report = DoctorReport(
            mode: .full,
            findings: [
                DoctorFinding(check: "API", status: .ok, message: "healthy"),
                DoctorFinding(check: "DNS", status: .warning, message: "missing"),
                DoctorFinding(check: "S3", status: .failure, message: "unavailable"),
                DoctorFinding(check: "HTTPS", status: .skipped, message: "external")
            ]
        )

        DoctorReportRenderer(console: console).render(report)

        #expect(output.contains("[OK]   API: healthy"))
        #expect(output.contains("[WARN] DNS: missing"))
        #expect(output.contains("[FAIL] S3: unavailable"))
        #expect(output.contains("[SKIP] HTTPS: external"))
        #expect(output.contains("Doctor completed with 1 failure(s) and 1 warning(s)."))
    }

    @Test
    func `Standard PostgreSQL doctor executes only SELECT one`() {
        let runner = DoctorCommandRunner(results: [.success("1")])
        let context = makeContext()

        let finding = makeRunner(commandRunner: runner).checkPostgreSQL(
            context,
            mode: .standard
        )

        #expect(finding.status == .ok)
        #expect(runner.invocations.count == 1)
        #expect(runner.invocations[0].arguments.suffix(2) == [
            "--command", "SELECT 1;"
        ])
        #expect(runner.invocations[0].standardInput == nil)
        #expect(runner.invocations[0].environment == [
            "PGPASSWORD": "database-secret",
            "PGSSLMODE": "disable"
        ])
        #expect(runner.invocations[0].arguments.contains("database-secret") == false)
    }

    @Test
    func `Full PostgreSQL doctor verifies temporary migration permissions`() throws {
        let runner = DoctorCommandRunner(results: [.success("1")])

        let finding = makeRunner(commandRunner: runner).checkPostgreSQL(
            makeContext(),
            mode: .full
        )

        let sql = try #require(runner.invocations[0].standardInput)
        #expect(finding.status == .ok)
        #expect(sql.contains("CREATE SCHEMA vernissage_doctor_fixed"))
        #expect(sql.contains("CREATE TABLE vernissage_doctor_fixed.permission_test"))
        #expect(sql.contains("DROP TABLE vernissage_doctor_fixed.permission_test"))
        #expect(sql.contains("DROP SCHEMA vernissage_doctor_fixed"))
    }

    @Test
    func `Full Redis doctor verifies and removes a temporary value`() {
        let runner = DoctorCommandRunner(results: [
            .success("PONG"),
            .success("OK"),
            .success("vernissage-doctor-fixed"),
            .success("1")
        ])

        let finding = makeRunner(commandRunner: runner).checkRedis(
            makeContext(),
            mode: .full
        )

        #expect(finding.status == .ok)
        #expect(runner.invocations.count == 4)
        #expect(runner.invocations[0].arguments.suffix(1) == ["PING"])
        #expect(runner.invocations[1].arguments.suffix(5) == [
            "SET", "vernissage:doctor:test:fixed",
            "vernissage-doctor-fixed", "EX", "60"
        ])
        #expect(runner.invocations[2].arguments.suffix(2) == [
            "GET", "vernissage:doctor:test:fixed"
        ])
        #expect(runner.invocations[3].arguments.suffix(2) == [
            "DEL", "vernissage:doctor:test:fixed"
        ])
        #expect(runner.invocations.allSatisfy {
            $0.arguments.contains("redis-secret") == false
        })
    }

    @Test
    func `Failed Redis write still attempts temporary key cleanup`() {
        let runner = DoctorCommandRunner(results: [
            .success("PONG"),
            .failure("SET failed"),
            .success("0")
        ])

        let finding = makeRunner(commandRunner: runner).checkRedis(
            makeContext(),
            mode: .full
        )

        #expect(finding.status == .failure)
        #expect(runner.invocations.count == 3)
        #expect(runner.invocations[2].arguments.suffix(2) == [
            "DEL", "vernissage:doctor:test:fixed"
        ])
    }

    @Test
    func `Full S3 doctor uploads downloads and deletes a temporary object`() {
        let payload = "vernissage-storage-doctor-fixed"
        let runner = DoctorCommandRunner(results: [
            .success(""),
            .success(""),
            .success(payload),
            .success("")
        ])

        let finding = makeRunner(commandRunner: runner).checkStorage(
            makeContext(),
            mode: .full
        )

        #expect(finding.status == .ok)
        #expect(runner.invocations.count == 4)
        #expect(runner.invocations[0].arguments.suffix(4) == [
            "s3api", "head-bucket", "--bucket", "vernissage"
        ])
        #expect(runner.invocations[1].standardInput == payload)
        #expect(runner.invocations[1].arguments.contains(
            "s3://vernissage/vernissage-doctor/fixed.txt"
        ))
        #expect(runner.invocations[3].arguments.suffix(6) == [
            "s3api", "delete-object", "--bucket", "vernissage",
            "--key", "vernissage-doctor/fixed.txt"
        ])
        #expect(runner.invocations.allSatisfy {
            $0.arguments.contains("storage-secret") == false
        })
    }

    @Test
    func `Failed S3 upload still attempts temporary object cleanup`() {
        let runner = DoctorCommandRunner(results: [
            .success(""),
            .failure("upload failed"),
            .success("")
        ])

        let finding = makeRunner(commandRunner: runner).checkStorage(
            makeContext(),
            mode: .full
        )

        #expect(finding.status == .failure)
        #expect(runner.invocations.count == 3)
        #expect(runner.invocations[2].arguments.suffix(6) == [
            "s3api", "delete-object", "--bucket", "vernissage",
            "--key", "vernissage-doctor/fixed.txt"
        ])
    }

    @Test
    func `Unavailable Docker skips dependent checks but retains DNS warnings`() {
        let runner = DoctorCommandRunner(results: [
            .failure("Cannot connect to the Docker daemon")
        ])
        let context = makeContext()
        let doctor = DoctorDiagnosticRunner(
            commandRunner: runner,
            dnsResolver: DoctorDNSResolver(
                lookups: [
                    DNSLookup(
                        family: .ipv4,
                        addresses: ["203.0.113.10"],
                        error: nil
                    ),
                    DNSLookup(
                        family: .ipv6,
                        addresses: [],
                        error: "No AAAA record"
                    )
                ]
            ),
            fileSystem: DoctorFileSystem(
                fileExists: { _ in true },
                permissions: { _ in 0o600 }
            ),
            operatingSystem: .linux,
            makeToken: { "fixed" }
        )

        let report = doctor.run(context: context, mode: .standard)

        #expect(report.findings.contains {
            $0.check == "Docker daemon" && $0.status == .failure
        })
        #expect(report.findings.contains {
            $0.check == "PostgreSQL" && $0.status == .skipped
        })
        #expect(report.findings.contains {
            $0.check == "DNS A" && $0.status == .ok
        })
        #expect(report.findings.contains {
            $0.check == "DNS AAAA" && $0.status == .warning
        })
        #expect(report.findings.contains {
            $0.check == "HTTPS endpoint" && $0.status == .skipped
        })
    }

    private func makeRunner(
        commandRunner: DoctorCommandRunner
    ) -> DoctorDiagnosticRunner {
        DoctorDiagnosticRunner(
            commandRunner: commandRunner,
            dnsResolver: DoctorDNSResolver(lookups: []),
            fileSystem: DoctorFileSystem(
                fileExists: { _ in true },
                permissions: { _ in 0o600 }
            ),
            operatingSystem: .linux,
            makeToken: { "fixed" }
        )
    }

    private func makeContext() -> InstallationContext {
        let context = InstallationContext(instanceIdentifier: "abcdefgh")
        context.summaryFilePath = "/srv/vernissage/vernissage.yml"
        context.secretsFilePath = "/srv/vernissage/vernissage.secrets.yml"
        context.server = ServerConfiguration(domain: "social.example.com")
        context.administrator = AdministratorConfiguration(
            userId: 42,
            name: "Admin",
            email: "admin@example.com",
            username: "adminuser",
            password: nil,
            accessToken: nil
        )
        context.database = DatabaseConfiguration(
            mode: .localContainer,
            host: "vernissage-abcdefgh-postgres",
            port: 5432,
            database: "vernissage",
            username: "vernissage",
            password: Secret(value: "database-secret"),
            tlsMode: .disable,
            localResources: LocalPostgreSQLResources(
                image: "postgres:18",
                containerName: "vernissage-abcdefgh-postgres",
                volumeName: "vernissage-abcdefgh-postgres-data",
                networkName: "vernissage-abcdefgh-network"
            )
        )
        context.redis = RedisConfiguration(
            mode: .localContainer,
            url: Secret(
                value: "redis://default:redis-secret@vernissage-abcdefgh-redis:6379/0"
            ),
            username: "default",
            host: "vernissage-abcdefgh-redis",
            port: 6379,
            database: 0,
            password: Secret(value: "redis-secret"),
            usesTLS: false,
            localResources: LocalRedisResources(
                image: "redis:8.8.1-alpine",
                containerName: "vernissage-abcdefgh-redis",
                volumeName: "vernissage-abcdefgh-redis-data",
                networkName: "vernissage-abcdefgh-network"
            )
        )
        context.storage = StorageConfiguration(
            provider: .localMinIO,
            address: "http://vernissage-abcdefgh-minio:9000",
            region: nil,
            bucket: "vernissage",
            accessKeyId: "minio",
            secretAccessKey: Secret(value: "storage-secret"),
            http1OnlyMode: false,
            localResources: LocalMinIOResources(
                image: "vernissage/minio:release",
                containerName: "vernissage-abcdefgh-minio",
                volumeName: "vernissage-abcdefgh-minio-data",
                networkName: "vernissage-abcdefgh-network"
            )
        )
        context.serverServices = ServerServicesConfiguration(
            image: "mczachurski/vernissage-server:latest",
            networkName: "vernissage-abcdefgh-network",
            apiContainerName: "vernissage-abcdefgh-api",
            jobsContainerName: "vernissage-abcdefgh-jobs",
            apiNetworkAlias: "vernissage-api.internal",
            jobsNetworkAlias: "vernissage-jobs.internal",
            baseAddress: "https://social.example.com",
            apiHealth: nil,
            jobsHealth: nil,
            databaseTables: nil
        )
        context.web = WebConfiguration(
            image: "mczachurski/vernissage-web:latest",
            containerName: "vernissage-abcdefgh-web",
            networkName: "vernissage-abcdefgh-network",
            networkAlias: "vernissage-web.internal",
            allowedHosts: "social.example.com,*.social.example.com",
            cspImageSource: nil
        )
        context.push = PushConfiguration(
            image: "mczachurski/vernissage-push:latest",
            containerName: "vernissage-abcdefgh-push",
            networkName: "vernissage-abcdefgh-network",
            networkAlias: "vernissage-push.internal",
            endpoint: "http://vernissage-push.internal:3000/send",
            secretKey: Secret(value: "push-secret"),
            isEnabled: false
        )
        context.publicAccess = PublicAccessConfiguration(httpsMode: .manual)
        context.proxy = ProxyConfiguration(
            image: "vernissage-proxy:abcdefgh",
            containerName: "vernissage-abcdefgh-proxy",
            networkName: "vernissage-abcdefgh-network",
            networkAlias: "vernissage-proxy.internal",
            hostPort: 8080,
            containerPort: 8080,
            apiUpstream: "vernissage-api.internal:8080",
            webUpstream: "vernissage-web.internal:8080",
            publicHTTPAddress: "http://social.example.com:8080",
            buildContextPath: "/srv/vernissage/proxy"
        )
        return context
    }
}

private struct DoctorCommandInvocation: Equatable {
    let executable: String
    let arguments: [String]
    let environment: [String: String]
    let standardInput: String?
}

private enum DoctorCommandRunnerError: Error {
    case resultNotConfigured
}

private final class DoctorCommandRunner: CommandRunning {
    private var results: [CommandResult]
    private(set) var invocations: [DoctorCommandInvocation] = []

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
            DoctorCommandInvocation(
                executable: executable,
                arguments: arguments,
                environment: environment,
                standardInput: standardInput
            )
        )
        guard results.isEmpty == false else {
            throw DoctorCommandRunnerError.resultNotConfigured
        }
        return results.removeFirst()
    }
}

private struct DoctorDNSResolver: DNSResolving {
    let lookups: [DNSLookup]

    func resolve(domain: String) -> [DNSLookup] {
        lookups
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
