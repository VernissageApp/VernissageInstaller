import Foundation
import Testing
@testable import VernissageCore

@Suite(.tags(.networking))
struct AdministratorAccountStepTests {
    @Test
    func `Administrator is registered promoted and verified`() throws {
        let runner = AdministratorCommandRunner(results: successfulResults())
        let output = AdministratorOutputBuffer()
        let step = makeStep(
            runner: runner,
            secureInput: AdministratorInputQueue(["Password1!", "Password1!"]),
            output: output
        )
        let context = makeContext()

        try step.run(
            context: context,
            providedName: "Jan Kowalski",
            providedEmail: "jan@example.com",
            providedUsername: "jankowalski"
        )

        let administrator = try #require(context.administrator)
        let password = try #require(administrator.password)
        let accessToken = try #require(administrator.accessToken)
        #expect(administrator.userId == 8_123_456_789)
        #expect(administrator.name == "Jan Kowalski")
        #expect(administrator.email == "jan@example.com")
        #expect(administrator.username == "jankowalski")
        #expect(password.value == "Password1!")
        #expect(accessToken.value == "new-administrator-token")
        #expect(runner.invocations.count == 4)

        let bootstrapLogin = runner.invocations[0]
        #expect(bootstrapLogin.arguments.last == "http://127.0.0.1:8080/api/v1/account/login")
        #expect(bootstrapLogin.standardInput?.contains("\"userNameOrEmail\":\"admin\"") == true)
        #expect(bootstrapLogin.standardInput?.contains("\"password\":\"admin\"") == true)

        let registration = runner.invocations[1]
        let registrationBody = try #require(registration.standardInput)
        #expect(registrationBody.contains("\"bio\"") == false)
        let registrationRequest = try JSONDecoder().decode(
            TestRegistrationRequest.self,
            from: Data(registrationBody.utf8)
        )
        #expect(registrationRequest.userName == "jankowalski")
        #expect(registrationRequest.email == "jan@example.com")
        #expect(registrationRequest.password == "Password1!")
        #expect(registrationRequest.redirectBaseUrl == "https://social.example.com")
        #expect(registrationRequest.agreement)
        #expect(registrationRequest.name == "Jan Kowalski")
        #expect(registrationRequest.securityToken.isEmpty)
        #expect(registrationRequest.locale == "en_US")
        #expect(registration.environment["VERNISSAGE_INSTALLER_ACCESS_TOKEN"] == "bootstrap-token")
        #expect(registration.arguments.contains("VERNISSAGE_INSTALLER_ACCESS_TOKEN"))

        let databaseUpdate = runner.invocations[2]
        let sql = try #require(databaseUpdate.value(after: "--command"))
        #expect(sql.contains("\"emailWasConfirmed\" = TRUE"))
        #expect(sql.contains("\"isApproved\" = TRUE"))
        #expect(sql.contains("\"code\" = 'administrator'"))
        #expect(sql.contains("VALUES (7669802715723076318, target_user_id, administrator_role_id"))
        #expect(sql.contains("\"isBlocked\" = TRUE"))
        #expect(sql.contains("\"userName\" = 'admin'"))
        #expect(sql.contains("\"value\" = target_user_id::TEXT"))
        #expect(sql.contains("\"key\" = 'systemDefaultUserId'"))
        #expect(sql.contains("bio") == false)
        #expect(databaseUpdate.environment["PGPASSWORD"] == "db-secret")
        #expect(databaseUpdate.environment["PGSSLMODE"] == "require")

        let finalLogin = runner.invocations[3]
        #expect(finalLogin.standardInput?.contains("\"userNameOrEmail\":\"jankowalski\"") == true)
        #expect(finalLogin.standardInput?.contains("\"password\":\"Password1!\"") == true)

        let secrets = ["Password1!", "bootstrap-token", "new-administrator-token", "db-secret"]
        for invocation in runner.invocations {
            let arguments = invocation.arguments.joined(separator: " ")
            for secret in secrets {
                #expect(arguments.contains(secret) == false)
            }
        }
        for secret in secrets {
            #expect(output.text.contains(secret) == false)
        }
        #expect(output.text.contains(InstallationStepGuidance.administratorAccount))
        #expect(output.text.contains("temporary admin account has been blocked"))
        #expect(output.text.contains("configured as the system default user"))
    }

    @Test
    func `Mismatched password is requested again`() throws {
        let secureInput = AdministratorInputQueue([
            "Password1!", "Different1!", "Password2!", "Password2!"
        ])
        let output = AdministratorOutputBuffer()
        let context = makeContext()
        let step = makeStep(
            runner: AdministratorCommandRunner(results: successfulResults()),
            secureInput: secureInput,
            output: output
        )

        try step.run(
            context: context,
            providedName: "",
            providedEmail: "admin@example.com",
            providedUsername: "admin1"
        )

        let administrator = try #require(context.administrator)
        let password = try #require(administrator.password)
        #expect(password.value == "Password2!")
        #expect(output.text.contains("The passwords do not match"))
        #expect(output.text.contains("Password1!") == false)
        #expect(output.text.contains("Password2!") == false)
    }

    @Test
    func `Missing running services prevents account creation`() {
        let runner = AdministratorCommandRunner(results: [])
        let step = makeStep(
            runner: runner,
            secureInput: AdministratorInputQueue([]),
            output: AdministratorOutputBuffer()
        )

        let error = #expect(throws: AdministratorAccountStepError.self) {
            try step.run(
                context: InstallationContext(instanceIdentifier: "abcdefgh"),
                providedName: nil,
                providedEmail: nil,
                providedUsername: nil
            )
        }

        #expect(error == .missingConfiguration("server and domain"))
        #expect(runner.invocations.isEmpty)
    }

    @Test
    func `Database failure leaves administrator unconfigured and skips final login`() {
        let runner = AdministratorCommandRunner(results: [
            .success("{\"accessToken\":\"bootstrap-token\"}"),
            .success("{}"),
            .failure("reserved role identifier is already in use")
        ])
        let context = makeContext()
        let step = makeStep(
            runner: runner,
            secureInput: AdministratorInputQueue(["Password1!", "Password1!"]),
            output: AdministratorOutputBuffer()
        )

        let error = #expect(throws: AdministratorAccountStepError.self) {
            try step.run(
                context: context,
                providedName: nil,
                providedEmail: "jan@example.com",
                providedUsername: "jankowalski"
            )
        }

        #expect(error == .databaseUpdateFailed("reserved role identifier is already in use"))
        #expect(context.administrator == nil)
        #expect(runner.invocations.count == 3)
    }

    @Test
    func `Final login must contain administrator role`() {
        let runner = AdministratorCommandRunner(results: [
            .success("{\"accessToken\":\"bootstrap-token\"}"),
            .success("{}"),
            .success("8123456789"),
            .success(
                "{\"accessToken\":\"new-token\",\"userPayload\":{\"roles\":[\"member\"]}}"
            )
        ])
        let context = makeContext()
        let step = makeStep(
            runner: runner,
            secureInput: AdministratorInputQueue(["Password1!", "Password1!"]),
            output: AdministratorOutputBuffer()
        )

        let error = #expect(throws: AdministratorAccountStepError.self) {
            try step.run(
                context: context,
                providedName: nil,
                providedEmail: "jan@example.com",
                providedUsername: "jankowalski"
            )
        }

        #expect(error == .missingAdministratorRole)
        #expect(context.administrator == nil)
        #expect(runner.invocations.count == 4)
    }

    @Test
    func `Temporary admin username cannot be reused`() {
        let runner = AdministratorCommandRunner(results: [])
        let context = makeContext()
        let step = makeStep(
            runner: runner,
            secureInput: AdministratorInputQueue([]),
            output: AdministratorOutputBuffer()
        )

        #expect(throws: ConfigurationValidationError.self) {
            try step.run(
                context: context,
                providedName: nil,
                providedEmail: "jan@example.com",
                providedUsername: "ADMIN"
            )
        }
        #expect(context.administrator == nil)
        #expect(runner.invocations.isEmpty)
    }

    @Test
    func `Localhost PostgreSQL on macOS uses Docker host gateway`() throws {
        let runner = AdministratorCommandRunner(results: successfulResults())
        let context = makeContext(databaseHost: "localhost")
        let step = makeStep(
            runner: runner,
            secureInput: AdministratorInputQueue(["Password1!", "Password1!"]),
            output: AdministratorOutputBuffer(),
            operatingSystem: .macOS
        )

        try step.run(
            context: context,
            providedName: nil,
            providedEmail: "jan@example.com",
            providedUsername: "jankowalski"
        )

        let databaseUpdate = runner.invocations[2]
        #expect(databaseUpdate.value(after: "--host") == "host.docker.internal")
        #expect(databaseUpdate.arguments.contains("--network") == false)
    }

    @Test
    func `Localhost PostgreSQL on Linux uses host network`() throws {
        let runner = AdministratorCommandRunner(results: successfulResults())
        let context = makeContext(databaseHost: "localhost")
        let step = makeStep(
            runner: runner,
            secureInput: AdministratorInputQueue(["Password1!", "Password1!"]),
            output: AdministratorOutputBuffer(),
            operatingSystem: .linux
        )

        try step.run(
            context: context,
            providedName: nil,
            providedEmail: "jan@example.com",
            providedUsername: "jankowalski"
        )

        let databaseUpdate = runner.invocations[2]
        #expect(databaseUpdate.value(after: "--network") == "host")
        #expect(databaseUpdate.value(after: "--host") == "localhost")
    }

    private func makeStep(
        runner: AdministratorCommandRunner,
        secureInput: AdministratorInputQueue,
        output: AdministratorOutputBuffer,
        operatingSystem: HostOperatingSystem = .linux
    ) -> AdministratorAccountStep {
        AdministratorAccountStep(
            console: Console(
                colorsEnabled: false,
                readInput: { nil },
                readSecureInput: secureInput.next,
                writeOutput: output.append
            ),
            commandRunner: runner,
            operatingSystem: operatingSystem
        )
    }

    private func makeContext(databaseHost: String = "db.example.com") -> InstallationContext {
        let context = InstallationContext(instanceIdentifier: "abcdefgh")
        context.server = ServerConfiguration(domain: "social.example.com")
        context.database = DatabaseConfiguration(
            mode: .existing,
            host: databaseHost,
            port: 5432,
            database: "vernissage",
            username: "vernissage",
            password: Secret(value: "db-secret"),
            tlsMode: .require,
            localResources: nil
        )
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
            databaseTables: ["Users", "Roles", "UserRoles"]
        )
        return context
    }

    private func successfulResults() -> [CommandResult] {
        [
            .success("{\"accessToken\":\"bootstrap-token\"}"),
            .success("{}"),
            .success("8123456789"),
            .success(
                "{\"access_token\":\"new-administrator-token\",\"userPayload\":{\"roles\":[\"administrator\"]}}"
            )
        ]
    }
}

private struct TestRegistrationRequest: Decodable {
    let userName: String
    let email: String
    let password: String
    let redirectBaseUrl: String
    let agreement: Bool
    let name: String?
    let securityToken: String
    let locale: String
}

private struct AdministratorCommandInvocation {
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

private enum AdministratorCommandRunnerError: Error {
    case resultNotConfigured
}

private final class AdministratorCommandRunner: CommandRunning {
    private var results: [CommandResult]
    private(set) var invocations: [AdministratorCommandInvocation] = []

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
            AdministratorCommandInvocation(
                executable: executable,
                arguments: arguments,
                environment: environment,
                standardInput: standardInput
            )
        )
        guard results.isEmpty == false else {
            throw AdministratorCommandRunnerError.resultNotConfigured
        }
        return results.removeFirst()
    }
}

private final class AdministratorInputQueue {
    private var values: [String]

    init(_ values: [String]) {
        self.values = values
    }

    func next() -> String? {
        guard values.isEmpty == false else { return nil }
        return values.removeFirst()
    }
}

private final class AdministratorOutputBuffer {
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
