import Foundation

enum AdministratorAccountStepError: LocalizedError, Equatable {
    case missingConfiguration(String)
    case apiRequestFailed(action: String, details: String?)
    case invalidAccessToken(String)
    case missingAdministratorRole
    case databaseUpdateFailed(String?)
    case invalidDatabaseResponse

    var errorDescription: String? {
        switch self {
        case .missingConfiguration(let name):
            "The \(name) configuration is missing. Complete all previous installer steps first."
        case .apiRequestFailed(let action, let details):
            Self.message("The Vernissage API could not \(action).", details: details)
        case .invalidAccessToken(let account):
            "The Vernissage API did not return an access token for \(account)."
        case .missingAdministratorRole:
            "The new account can sign in, but its access token does not contain the administrator role."
        case .databaseUpdateFailed(let details):
            Self.message("The installer could not activate the new administrator account.", details: details)
        case .invalidDatabaseResponse:
            "PostgreSQL activated the account, but did not return its user identifier."
        }
    }

    private static func message(_ summary: String, details: String?) -> String {
        guard let details, details.isEmpty == false else { return summary }
        return "\(summary) Details: \(details)"
    }
}

struct AdministratorAccountStep {
    static let defaultAdministratorUsername = "admin"
    static let defaultAdministratorPassword = "admin"
    static let administratorUserRoleId: Int64 = 7_669_802_715_723_076_318
    static let postgresImage = "postgres:18"

    private let console: Console
    private let commandRunner: any CommandRunning
    private let operatingSystem: HostOperatingSystem

    init(
        console: Console,
        commandRunner: any CommandRunning,
        operatingSystem: HostOperatingSystem
    ) {
        self.console = console
        self.commandRunner = commandRunner
        self.operatingSystem = operatingSystem
    }

    static func live(colorsEnabled: Bool) -> AdministratorAccountStep {
        AdministratorAccountStep(
            console: .live(colorsEnabled: colorsEnabled),
            commandRunner: ProcessCommandRunner(),
            operatingSystem: .current
        )
    }

    func run(
        context: InstallationContext,
        providedName: String?,
        providedEmail: String?,
        providedUsername: String?,
        providedPassword: Secret? = nil
    ) throws {
        let installation = try collectedInstallation(from: context)

        console.section("Administrator account")
        console.guidance(InstallationStepGuidance.administratorAccount)

        let name = try optionalValue(
            provided: providedName,
            question: "Administrator name (optional, for example Jan Kowalski):",
            validator: AdministratorValidator.validateName
        )
        let email = try requiredValue(
            provided: providedEmail,
            field: "administrator email",
            question: "Administrator email:",
            validator: AdministratorValidator.validateEmail
        )
        let username = try requiredValue(
            provided: providedUsername,
            field: "administrator username",
            question: "Administrator username (letters and digits only):",
            validator: validateNewAdministratorUsername
        )
        let password = try providedPassword.map { try AdministratorValidator.validatePassword($0.value) }
            ?? readPassword()

        console.info("Signing in with the temporary built-in administrator account…")
        let bootstrapAccessToken = try login(
            username: Self.defaultAdministratorUsername,
            password: Secret(value: Self.defaultAdministratorPassword),
            accountDescription: "the temporary administrator",
            apiContainerName: installation.serverServices.apiContainerName
        )
        console.success("Authenticated the temporary administrator account.")

        console.info("Creating the new administrator through the Vernissage API…")
        try registerAdministrator(
            name: name,
            email: email,
            username: username,
            password: password,
            baseAddress: installation.serverServices.baseAddress,
            accessToken: bootstrapAccessToken,
            apiContainerName: installation.serverServices.apiContainerName
        )
        console.success("The Vernissage API created the new account and its cryptographic keys.")

        console.info("Confirming the account, assigning the administrator role, and disabling the temporary account…")
        let userId = try activateAdministrator(
            username: username,
            database: installation.database,
            defaultNetworkName: installation.serverServices.networkName
        )
        console.success("The new account is confirmed, approved, and assigned to the administrator role.")
        console.success("The temporary admin account has been blocked.")
        console.success("The new administrator is configured as the system default user.")

        console.info("Verifying sign-in with the new administrator account…")
        let accessToken = try login(
            username: username,
            password: password,
            accountDescription: "the new administrator",
            requiredRole: "administrator",
            apiContainerName: installation.serverServices.apiContainerName
        )

        context.administrator = AdministratorConfiguration(
            userId: userId,
            name: name,
            email: email,
            username: username,
            password: password,
            accessToken: accessToken
        )

        console.success("The new administrator account is ready and its sign-in was verified.")
        console.value(label: "Name", value: name ?? "not specified")
        console.value(label: "Email", value: email)
        console.value(label: "Username", value: username)
        console.value(label: "Password", value: "configured (hidden)")
        console.info("The credentials and access token are kept only in the in-memory installation context.")
    }

    private func collectedInstallation(from context: InstallationContext) throws -> CollectedAdministratorInstallation {
        guard let server = context.server else {
            throw AdministratorAccountStepError.missingConfiguration("server and domain")
        }
        guard let database = context.database else {
            throw AdministratorAccountStepError.missingConfiguration("PostgreSQL database")
        }
        guard let serverServices = context.serverServices else {
            throw AdministratorAccountStepError.missingConfiguration("Vernissage API and Jobs")
        }
        return CollectedAdministratorInstallation(
            server: server,
            database: database,
            serverServices: serverServices
        )
    }

    private func validateNewAdministratorUsername(_ input: String) throws -> String {
        let username = try AdministratorValidator.validateUsername(input)
        guard username.lowercased() != Self.defaultAdministratorUsername else {
            throw ConfigurationValidationError.invalidUsername(
                "Choose a username other than admin because the temporary admin account will be blocked."
            )
        }
        return username
    }

    private func login(
        username: String,
        password: Secret,
        accountDescription: String,
        requiredRole: String? = nil,
        apiContainerName: String
    ) throws -> Secret {
        let body = try encodedJSON(
            LoginRequest(userNameOrEmail: username, password: password.value)
        )
        let result = try performAPIRequest(
            path: "/api/v1/account/login",
            body: body,
            accessToken: nil,
            action: "sign in to \(accountDescription) account",
            apiContainerName: apiContainerName
        )

        let response: AccessTokenResponse
        do {
            response = try JSONDecoder().decode(AccessTokenResponse.self, from: Data(result.standardOutput.utf8))
        } catch {
            throw AdministratorAccountStepError.invalidAccessToken(accountDescription)
        }
        guard let accessToken = response.accessToken, accessToken.isEmpty == false else {
            throw AdministratorAccountStepError.invalidAccessToken(accountDescription)
        }
        if let requiredRole,
           response.userPayload?.roles.contains(requiredRole) != true {
            throw AdministratorAccountStepError.missingAdministratorRole
        }
        return Secret(value: accessToken)
    }

    private func registerAdministrator(
        name: String?,
        email: String,
        username: String,
        password: Secret,
        baseAddress: String,
        accessToken: Secret,
        apiContainerName: String
    ) throws {
        let request = RegisterAdministratorRequest(
            userName: username,
            email: email,
            password: password.value,
            redirectBaseUrl: baseAddress,
            agreement: true,
            name: name,
            securityToken: "",
            locale: "en_US"
        )
        let body = try encodedJSON(request)
        _ = try performAPIRequest(
            path: "/api/v1/register",
            body: body,
            accessToken: accessToken,
            action: "register the new administrator",
            apiContainerName: apiContainerName
        )
    }

    private func encodedJSON<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    private func performAPIRequest(
        path: String,
        body: String,
        accessToken: Secret?,
        action: String,
        apiContainerName: String
    ) throws -> CommandResult {
        var arguments = ["exec", "--interactive"]
        var environment: [String: String] = [:]

        if let accessToken {
            arguments += ["--env", "VERNISSAGE_INSTALLER_ACCESS_TOKEN"]
            environment["VERNISSAGE_INSTALLER_ACCESS_TOKEN"] = accessToken.value
        }

        arguments.append(apiContainerName)
        if accessToken == nil {
            arguments += curlArguments(path: path)
        } else {
            arguments += [
                "sh", "-c",
                "curl --fail-with-body --silent --show-error --max-time 15 --request POST --header 'Content-Type: application/json' --header \"Authorization: Bearer $VERNISSAGE_INSTALLER_ACCESS_TOKEN\" --data-binary @- http://127.0.0.1:8080\(path)"
            ]
        }

        let result: CommandResult
        do {
            result = try commandRunner.run(
                "docker",
                arguments: arguments,
                environment: environment,
                standardInput: body
            )
        } catch {
            throw AdministratorAccountStepError.apiRequestFailed(
                action: action,
                details: error.localizedDescription
            )
        }
        guard result.succeeded else {
            throw AdministratorAccountStepError.apiRequestFailed(
                action: action,
                details: details(from: result)
            )
        }
        return result
    }

    private func curlArguments(path: String) -> [String] {
        [
            "curl",
            "--fail-with-body", "--silent", "--show-error",
            "--max-time", "15",
            "--request", "POST",
            "--header", "Content-Type: application/json",
            "--data-binary", "@-",
            "http://127.0.0.1:8080\(path)"
        ]
    }

    private func activateAdministrator(
        username: String,
        database: DatabaseConfiguration,
        defaultNetworkName: String
    ) throws -> Int64 {
        let target = databaseCommandTarget(
            for: database,
            defaultNetworkName: defaultNetworkName
        )
        let escapedUsername = sqlLiteral(username)
        let script = """
        DO $vernissage_installer$
        DECLARE
            target_user_id BIGINT;
            administrator_role_id BIGINT;
        BEGIN
            SELECT "id" INTO STRICT target_user_id
            FROM "Users"
            WHERE "userName" = '\(escapedUsername)';

            SELECT "id" INTO STRICT administrator_role_id
            FROM "Roles"
            WHERE "code" = 'administrator';

            UPDATE "Users"
            SET "emailWasConfirmed" = TRUE,
                "isApproved" = TRUE
            WHERE "id" = target_user_id;

            IF NOT EXISTS (
                SELECT 1 FROM "UserRoles"
                WHERE "userId" = target_user_id
                  AND "roleId" = administrator_role_id
            ) THEN
                IF EXISTS (
                    SELECT 1 FROM "UserRoles"
                    WHERE "id" = \(Self.administratorUserRoleId)
                ) THEN
                    RAISE EXCEPTION 'The reserved administrator UserRoles identifier is already in use.';
                END IF;

                INSERT INTO "UserRoles" ("id", "userId", "roleId", "createdAt")
                VALUES (\(Self.administratorUserRoleId), target_user_id, administrator_role_id, CURRENT_TIMESTAMP);
            END IF;

            UPDATE "Users"
            SET "isBlocked" = TRUE
            WHERE "userName" = 'admin';

            IF NOT FOUND THEN
                RAISE EXCEPTION 'The temporary admin account was not found.';
            END IF;

            UPDATE "Settings"
            SET "value" = target_user_id::TEXT,
                "updatedAt" = CURRENT_TIMESTAMP
            WHERE "key" = 'systemDefaultUserId';

            IF NOT FOUND THEN
                RAISE EXCEPTION 'The systemDefaultUserId setting was not found.';
            END IF;
        END
        $vernissage_installer$;

        SELECT "id" FROM "Users" WHERE "userName" = '\(escapedUsername)';
        """

        var arguments = ["run", "--rm"]
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
            "--set", "ON_ERROR_STOP=1",
            "--command", script
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
                standardInput: nil
            )
        } catch {
            throw AdministratorAccountStepError.databaseUpdateFailed(error.localizedDescription)
        }
        guard result.succeeded else {
            throw AdministratorAccountStepError.databaseUpdateFailed(details(from: result))
        }

        let identifier = result.standardOutput
            .split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last(where: { $0.isEmpty == false })
        guard let identifier, let userId = Int64(identifier) else {
            throw AdministratorAccountStepError.invalidDatabaseResponse
        }
        return userId
    }

    private func databaseCommandTarget(
        for configuration: DatabaseConfiguration,
        defaultNetworkName: String
    ) -> AdministratorDatabaseCommandTarget {
        if configuration.mode == .localContainer {
            return AdministratorDatabaseCommandTarget(
                host: configuration.host,
                dockerNetwork: configuration.localResources?.networkName ?? defaultNetworkName
            )
        }

        guard isLoopbackHost(configuration.host) else {
            return AdministratorDatabaseCommandTarget(host: configuration.host, dockerNetwork: nil)
        }
        switch operatingSystem {
        case .macOS:
            return AdministratorDatabaseCommandTarget(host: "host.docker.internal", dockerNetwork: nil)
        case .linux:
            return AdministratorDatabaseCommandTarget(host: configuration.host, dockerNetwork: "host")
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

    private func requiredValue(
        provided: String?,
        field: String,
        question: String,
        validator: (String) throws -> String
    ) throws -> String {
        if let provided {
            return try validator(provided)
        }

        while true {
            guard let input = console.prompt(question) else {
                throw ConfigurationValidationError.inputEnded(field)
            }

            do {
                return try validator(input)
            } catch {
                console.warning(error.localizedDescription)
            }
        }
    }

    private func optionalValue(
        provided: String?,
        question: String,
        validator: (String?) throws -> String?
    ) throws -> String? {
        if let provided {
            return try validator(provided)
        }

        while true {
            guard let input = console.prompt(question) else {
                return nil
            }

            do {
                return try validator(input)
            } catch {
                console.warning(error.localizedDescription)
            }
        }
    }

    private func readPassword() throws -> Secret {
        while true {
            guard let password = console.securePrompt("Administrator password (8–32 characters):") else {
                throw ConfigurationValidationError.inputEnded("administrator password")
            }

            let validatedPassword: Secret
            do {
                validatedPassword = try AdministratorValidator.validatePassword(password)
            } catch {
                console.warning(error.localizedDescription)
                continue
            }

            guard let confirmation = console.securePrompt("Confirm administrator password:") else {
                throw ConfigurationValidationError.inputEnded("administrator password confirmation")
            }

            guard password == confirmation else {
                console.warning(ConfigurationValidationError.passwordConfirmationMismatch.localizedDescription)
                continue
            }

            return validatedPassword
        }
    }
}

private struct CollectedAdministratorInstallation {
    let server: ServerConfiguration
    let database: DatabaseConfiguration
    let serverServices: ServerServicesConfiguration
}

private struct LoginRequest: Encodable {
    let userNameOrEmail: String
    let password: String
}

private struct RegisterAdministratorRequest: Encodable {
    let userName: String
    let email: String
    let password: String
    let redirectBaseUrl: String
    let agreement: Bool
    let name: String?
    let securityToken: String
    let locale: String
}

private struct AccessTokenResponse: Decodable {
    let accessToken: String?
    let userPayload: AccessTokenUserPayload?

    private enum CodingKeys: String, CodingKey {
        case accessToken
        case snakeCaseAccessToken = "access_token"
        case userPayload
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try container.decodeIfPresent(String.self, forKey: .accessToken)
            ?? container.decodeIfPresent(String.self, forKey: .snakeCaseAccessToken)
        userPayload = try container.decodeIfPresent(AccessTokenUserPayload.self, forKey: .userPayload)
    }
}

private struct AccessTokenUserPayload: Decodable {
    let roles: [String]
}

private struct AdministratorDatabaseCommandTarget {
    let host: String
    let dockerNetwork: String?
}
