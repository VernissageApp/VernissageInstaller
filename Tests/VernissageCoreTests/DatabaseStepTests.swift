import Testing
@testable import VernissageCore

@Suite(.tags(.database))
struct DatabaseStepTests {
    @Test
    func `Existing PostgreSQL configuration is tested and stored`() throws {
        let input = DatabaseInputQueue([
            "1",
            "db.example.com",
            "",
            "vernissage",
            "vernissage_user",
            ""
        ])
        let secureInput = DatabaseInputQueue(["database-secret"])
        let output = DatabaseOutputBuffer()
        let runner = DatabaseCommandRunner(results: [.success("permission test completed")])
        let context = InstallationContext(instanceIdentifier: "abcdefgh")
        let step = makeStep(
            input: input,
            secureInput: secureInput,
            output: output,
            runner: runner,
            operatingSystem: .macOS
        )

        try step.run(context: context)

        let configuration = try #require(context.database)
        #expect(configuration.mode == .existing)
        #expect(configuration.host == "db.example.com")
        #expect(configuration.port == 5432)
        #expect(configuration.database == "vernissage")
        #expect(configuration.username == "vernissage_user")
        #expect(configuration.password.value == "database-secret")
        #expect(configuration.tlsMode == .require)
        #expect(configuration.localResources == nil)

        let invocation = try #require(runner.invocations.first)
        #expect(invocation.arguments.starts(with: ["run", "--rm", "--interactive"]))
        #expect(invocation.arguments.contains("postgres:18"))
        #expect(invocation.arguments.contains("db.example.com"))
        #expect(invocation.environment["PGPASSWORD"] == "database-secret")
        #expect(invocation.environment["PGSSLMODE"] == "require")
        #expect(invocation.standardInput?.contains("SELECT 1;") == true)
        #expect(invocation.standardInput?.contains("CREATE TABLE test_schema.migration_permission_test") == true)
        #expect(invocation.standardInput?.contains("DROP TABLE test_schema.migration_permission_test") == true)
        #expect(invocation.arguments.contains("database-secret") == false)
        #expect(output.text.contains(InstallationStepGuidance.database))
        #expect(output.text.contains("Choose your option:"))
        #expect(output.text.contains("database-secret") == false)
    }

    @Test
    func `Localhost PostgreSQL on macOS is reached through the Docker host gateway`() throws {
        let runner = DatabaseCommandRunner(results: [.success("permission test completed")])
        let context = InstallationContext(instanceIdentifier: "abcdefgh")
        let step = makeExistingDatabaseStep(
            host: "localhost",
            runner: runner,
            operatingSystem: .macOS
        )

        try step.run(context: context)

        let invocation = try #require(runner.invocations.first)
        #expect(invocation.value(after: "--host") == "host.docker.internal")
        #expect(invocation.arguments.contains("--network") == false)
        #expect(context.database?.host == "localhost")
    }

    @Test
    func `Localhost PostgreSQL on Linux is reached through the host network`() throws {
        let runner = DatabaseCommandRunner(results: [.success("permission test completed")])
        let context = InstallationContext(instanceIdentifier: "abcdefgh")
        let step = makeExistingDatabaseStep(
            host: "localhost",
            runner: runner,
            operatingSystem: .linux
        )

        try step.run(context: context)

        let invocation = try #require(runner.invocations.first)
        #expect(invocation.value(after: "--host") == "localhost")
        #expect(invocation.value(after: "--network") == "host")
        #expect(context.database?.host == "localhost")
    }

    @Test
    func `Local PostgreSQL container is created tested and stored`() throws {
        let input = DatabaseInputQueue(["2", "vernissage_user"])
        let secureInput = DatabaseInputQueue(["database-secret", "database-secret"])
        let output = DatabaseOutputBuffer()
        let runner = DatabaseCommandRunner(results: [
            .failure("container not found"),
            .failure("volume not found"),
            .failure("network not found"),
            .success("vernissage-abcdefgh-network"),
            .success("vernissage-abcdefgh-postgres-data"),
            .success("container-id"),
            .failure("no response"),
            .success("accepting connections"),
            .success("permission test completed")
        ])
        let context = InstallationContext(instanceIdentifier: "abcdefgh")
        let step = makeStep(
            input: input,
            secureInput: secureInput,
            output: output,
            runner: runner
        )

        try step.run(context: context)

        let configuration = try #require(context.database)
        let resources = try #require(configuration.localResources)
        #expect(configuration.mode == .localContainer)
        #expect(configuration.host == "vernissage-abcdefgh-postgres")
        #expect(configuration.port == 5432)
        #expect(configuration.database == "vernissage")
        #expect(configuration.username == "vernissage_user")
        #expect(configuration.tlsMode == .disable)
        #expect(resources.image == "postgres:18")
        #expect(resources.containerName == "vernissage-abcdefgh-postgres")
        #expect(resources.volumeName == "vernissage-abcdefgh-postgres-data")
        #expect(resources.networkName == "vernissage-abcdefgh-network")
        #expect(runner.invocations.count == 9)

        let containerCreation = runner.invocations[5]
        #expect(containerCreation.arguments.contains("--restart"))
        #expect(containerCreation.arguments.contains("unless-stopped"))
        #expect(
            containerCreation.arguments.contains {
                $0.contains("target=/var/lib/postgresql")
            }
        )
        #expect(containerCreation.environment["POSTGRES_DB"] == "vernissage")
        #expect(containerCreation.environment["POSTGRES_USER"] == "vernissage_user")
        #expect(containerCreation.environment["POSTGRES_PASSWORD"] == "database-secret")

        let permissionTest = runner.invocations[8]
        #expect(permissionTest.arguments.contains("vernissage-abcdefgh-network"))
        #expect(permissionTest.environment["PGPASSWORD"] == "database-secret")
        #expect(permissionTest.environment["PGSSLMODE"] == "disable")
        #expect(runner.invocations.allSatisfy { $0.arguments.contains("database-secret") == false })
        #expect(output.text.contains("database-secret") == false)
    }

    @Test
    func `Local PostgreSQL SQL test retries while the database is finishing startup`() throws {
        let runner = DatabaseCommandRunner(
            results: localDatabaseResults(
                permissionResults: [
                    .failure("FATAL: the database system is starting up"),
                    .success("permission test completed")
                ]
            )
        )
        let output = DatabaseOutputBuffer()
        let context = InstallationContext(instanceIdentifier: "abcdefgh")
        let step = makeStep(
            input: DatabaseInputQueue(["2", "vernissage_user"]),
            secureInput: DatabaseInputQueue(["database-secret", "database-secret"]),
            output: output,
            runner: runner
        )

        try step.run(context: context)

        #expect(context.database?.mode == .localContainer)
        #expect(runner.invocations.count == 9)
        #expect(output.text.contains("PostgreSQL is still finishing startup. Retrying the SQL test…"))
    }

    @Test
    func `Local PostgreSQL SQL test does not retry permanent permission failure`() {
        let runner = DatabaseCommandRunner(
            results: localDatabaseResults(
                permissionResults: [.failure("permission denied")]
            )
        )
        let context = InstallationContext(instanceIdentifier: "abcdefgh")
        let step = makeStep(
            input: DatabaseInputQueue(["2", "vernissage_user"]),
            secureInput: DatabaseInputQueue(["database-secret", "database-secret"]),
            output: DatabaseOutputBuffer(),
            runner: runner
        )

        let error = #expect(throws: DatabaseStepError.self) {
            try step.run(context: context)
        }

        #expect(error == .databasePermissionTestFailed("permission denied"))
        #expect(runner.invocations.count == 8)
        #expect(context.database == nil)
    }

    @Test
    func `Failed PostgreSQL permission test stops database step`() {
        let input = DatabaseInputQueue([
            "1",
            "db.example.com",
            "5432",
            "vernissage",
            "vernissage_user",
            "1"
        ])
        let runner = DatabaseCommandRunner(results: [.failure("permission denied")])
        let context = InstallationContext(instanceIdentifier: "abcdefgh")
        let step = makeStep(
            input: input,
            secureInput: DatabaseInputQueue(["database-secret"]),
            output: DatabaseOutputBuffer(),
            runner: runner
        )

        let error = #expect(throws: DatabaseStepError.self) {
            try step.run(context: context)
        }
        #expect(error == .databasePermissionTestFailed("permission denied"))
        #expect(context.database == nil)
    }

    @Test
    func `Existing local PostgreSQL container is never replaced`() {
        let runner = DatabaseCommandRunner(results: [.success("existing-container")])
        let context = InstallationContext(instanceIdentifier: "abcdefgh")
        let step = makeStep(
            input: DatabaseInputQueue(["2", "vernissage_user"]),
            secureInput: DatabaseInputQueue(["database-secret", "database-secret"]),
            output: DatabaseOutputBuffer(),
            runner: runner
        )

        let error = #expect(throws: DatabaseStepError.self) {
            try step.run(context: context)
        }
        #expect(error == .localContainerAlreadyExists("vernissage-abcdefgh-postgres"))
        #expect(runner.invocations.count == 1)
        #expect(context.database == nil)
    }

    private func makeStep(
        input: DatabaseInputQueue,
        secureInput: DatabaseInputQueue,
        output: DatabaseOutputBuffer,
        runner: DatabaseCommandRunner,
        operatingSystem: HostOperatingSystem = .macOS
    ) -> DatabaseStep {
        DatabaseStep(
            console: Console(
                colorsEnabled: false,
                readInput: input.next,
                readSecureInput: secureInput.next,
                writeOutput: output.append
            ),
            commandRunner: runner,
            makeSchemaName: { "test_schema" },
            waitBeforeRetry: {},
            readinessAttempts: 3,
            operatingSystem: operatingSystem
        )
    }

    private func makeExistingDatabaseStep(
        host: String,
        runner: DatabaseCommandRunner,
        operatingSystem: HostOperatingSystem
    ) -> DatabaseStep {
        makeStep(
            input: DatabaseInputQueue([
                "1",
                host,
                "5432",
                "postgres",
                "postgres",
                "2"
            ]),
            secureInput: DatabaseInputQueue(["database-secret"]),
            output: DatabaseOutputBuffer(),
            runner: runner,
            operatingSystem: operatingSystem
        )
    }

    private func localDatabaseResults(
        permissionResults: [CommandResult]
    ) -> [CommandResult] {
        [
            .failure("container not found"),
            .failure("volume not found"),
            .failure("network not found"),
            .success("vernissage-abcdefgh-network"),
            .success("vernissage-abcdefgh-postgres-data"),
            .success("container-id"),
            .success("accepting connections")
        ] + permissionResults
    }
}

private struct DatabaseCommandInvocation {
    let executable: String
    let arguments: [String]
    let environment: [String: String]
    let standardInput: String?

    func value(after option: String) -> String? {
        guard let index = arguments.firstIndex(of: option),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}

private enum DatabaseCommandRunnerError: Error {
    case resultNotConfigured
}

private final class DatabaseCommandRunner: CommandRunning {
    private var results: [CommandResult]
    private(set) var invocations: [DatabaseCommandInvocation] = []

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
            DatabaseCommandInvocation(
                executable: executable,
                arguments: arguments,
                environment: environment,
                standardInput: standardInput
            )
        )

        guard results.isEmpty == false else {
            throw DatabaseCommandRunnerError.resultNotConfigured
        }
        return results.removeFirst()
    }
}

private final class DatabaseInputQueue {
    private var values: [String]

    init(_ values: [String]) {
        self.values = values
    }

    func next() -> String? {
        guard values.isEmpty == false else { return nil }
        return values.removeFirst()
    }
}

private final class DatabaseOutputBuffer {
    private(set) var text = ""

    func append(_ value: String) {
        text += value
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
