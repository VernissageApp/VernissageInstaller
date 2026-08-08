import ArgumentParser
import Foundation

enum InstallationAutomationError: LocalizedError, Equatable {
    case missingOption(String)
    case invalidOption(String)
    case secretsFileRequired
    case secretsFileUnreadable(String)
    case insecureSecretsFile(String)
    case malformedSecret(line: Int)
    case unknownSecret(key: String, line: Int)
    case duplicateSecret(key: String, line: Int)
    case missingSecret(String)

    var errorDescription: String? {
        switch self {
        case .missingOption(let option):
            "The required option --\(option) is missing in non-interactive mode."
        case .invalidOption(let message):
            message
        case .secretsFileRequired:
            "The --secrets-file option is required in non-interactive mode. Passwords are never read from command-line arguments or environment variables."
        case .secretsFileUnreadable(let details):
            "The secrets file could not be read. Details: \(details)"
        case .insecureSecretsFile(let path):
            "The secrets file \(path) is accessible by other users. Run 'chmod 600 \(path)' and try again."
        case .malformedSecret(let line):
            "The secrets file contains an invalid assignment on line \(line). Use KEY='value'."
        case .unknownSecret(let key, let line):
            "The secrets file contains unknown key \(key) on line \(line)."
        case .duplicateSecret(let key, let line):
            "The secrets file contains duplicate key \(key) on line \(line)."
        case .missingSecret(let key):
            "The required secret \(key) is missing or empty in the secrets file."
        }
    }
}

enum DatabaseModeOption: String, ExpressibleByArgument {
    case existing
    case local
}

enum RedisModeOption: String, ExpressibleByArgument {
    case existing
    case local
}

enum StorageModeOption: String, ExpressibleByArgument {
    case aws
    case s3
    case minio
}

enum TLSModeOption: String, ExpressibleByArgument {
    case require
    case disable
}

enum HTTPVersionOption: String, ExpressibleByArgument {
    case automatic
    case http1
}

enum HTTPSModeOption: String, ExpressibleByArgument {
    case development
    case production
    case manual
}

struct InstallationCommandOptions: ParsableArguments {
    @Flag(name: .customLong("non-interactive"), help: "Run without reading from standard input. Requires all applicable options and --secrets-file.")
    var nonInteractive = false

    @Option(name: .customLong("secrets-file"), help: "Path to the mode-0600 file containing installation passwords.")
    var secretsFile: String?

    @Option(name: .customLong("install-directory"), help: "Directory in which the vernissage deployment directory is created.")
    var installDirectory: String = "."

    @Option(name: .customLong("instance-id"), help: "Optional eight-letter installation identifier. A random identifier is generated when omitted.")
    var instanceIdentifier: String?

    @Option(name: .long, help: "The permanent domain of the Vernissage instance.")
    var domain: String?

    @Option(name: .customLong("admin-email"), help: "The administrator email address.")
    var administratorEmail: String?

    @Option(name: .customLong("admin-name"), help: "The optional administrator display name.")
    var administratorName: String?

    @Option(name: .customLong("admin-username"), help: "The administrator username.")
    var administratorUsername: String?

    @Option(name: .customLong("database-mode"), help: "PostgreSQL mode: existing or local.")
    var databaseMode: DatabaseModeOption?

    @Option(name: .customLong("postgres-host"), help: "Existing PostgreSQL hostname or IP address.")
    var postgresHost: String?

    @Option(name: .customLong("postgres-port"), help: "Existing PostgreSQL port.")
    var postgresPort: UInt16 = 5432

    @Option(name: .customLong("postgres-database"), help: "Existing PostgreSQL database name.")
    var postgresDatabase: String?

    @Option(name: .customLong("postgres-username"), help: "PostgreSQL username.")
    var postgresUsername: String?

    @Option(name: .customLong("postgres-tls"), help: "Existing PostgreSQL TLS mode: require or disable.")
    var postgresTLS: TLSModeOption = .require

    @Option(name: .customLong("redis-mode"), help: "Redis mode: existing or local.")
    var redisMode: RedisModeOption?

    @Option(name: .customLong("redis-username"), help: "Existing Redis ACL username. Vernissage currently supports default.")
    var redisUsername: String = "default"

    @Option(name: .customLong("redis-host"), help: "Existing Redis hostname or IP address.")
    var redisHost: String?

    @Option(name: .customLong("redis-port"), help: "Existing Redis port.")
    var redisPort: UInt16 = 6379

    @Option(name: .customLong("redis-tls"), help: "Existing Redis TLS mode: require or disable.")
    var redisTLS: TLSModeOption = .require

    @Option(name: .customLong("storage-mode"), help: "Object storage mode: aws, s3, or minio.")
    var storageMode: StorageModeOption?

    @Option(name: .customLong("s3-address"), help: "Address of an S3-compatible service.")
    var s3Address: String?

    @Option(name: .customLong("s3-region"), help: "AWS S3 region.")
    var s3Region: String?

    @Option(name: .customLong("s3-bucket"), help: "S3 bucket name.")
    var s3Bucket: String?

    @Option(name: .customLong("s3-access-key-id"), help: "S3 access key ID.")
    var s3AccessKeyID: String?

    @Option(name: .customLong("s3-http-version"), help: "S3-compatible HTTP mode: automatic or http1.")
    var s3HTTPVersion: HTTPVersionOption = .automatic

    @Option(name: .customLong("minio-root-username"), help: "Root username for local MinIO.")
    var minIORootUsername: String?

    @Option(name: .customLong("images-url"), help: "Optional public image or CDN base URL for AWS S3 and S3-compatible storage.")
    var imagesURL: String?

    @Option(name: .customLong("web-csp-image-source"), help: "Optional additional HTTP(S) image origin for the Web CSP.")
    var webCSPImageSource: String?

    @Option(name: .customLong("https-mode"), help: "Public HTTPS mode: development, production, or manual.")
    var httpsMode: HTTPSModeOption?

    @Option(name: .customLong("proxy-port"), help: "Host port exposed by Proxy when --https-mode manual is used.")
    var proxyPort: UInt16 = ProxyStep.defaultHostPort

    var containsNonInteractiveOnlyValues: Bool {
        secretsFile != nil ||
            databaseMode != nil || postgresHost != nil || postgresPort != 5432 ||
            postgresDatabase != nil || postgresUsername != nil || postgresTLS != .require ||
            redisMode != nil || redisUsername != "default" || redisHost != nil ||
            redisPort != 6379 || redisTLS != .require || storageMode != nil ||
            s3Address != nil || s3Region != nil || s3Bucket != nil || s3AccessKeyID != nil ||
            s3HTTPVersion != .automatic || minIORootUsername != nil ||
            imagesURL != nil || webCSPImageSource != nil || httpsMode != nil ||
            proxyPort != ProxyStep.defaultHostPort
    }
}

struct InstallationSecrets: Equatable {
    static let administratorPasswordKey = "VERNISSAGE_ADMIN_PASSWORD"
    static let postgresPasswordKey = "VERNISSAGE_POSTGRES_PASSWORD"
    static let redisPasswordKey = "VERNISSAGE_REDIS_PASSWORD"
    static let s3SecretAccessKey = "VERNISSAGE_S3_SECRET_ACCESS_KEY"
    static let minIORootPasswordKey = "VERNISSAGE_MINIO_ROOT_PASSWORD"

    private static let supportedKeys: Set<String> = [
        administratorPasswordKey,
        postgresPasswordKey,
        redisPasswordKey,
        s3SecretAccessKey,
        minIORootPasswordKey
    ]

    private let values: [String: Secret]

    init(values: [String: Secret]) {
        self.values = values
    }

    static func load(from url: URL, fileManager: FileManager = .default) throws -> InstallationSecrets {
        do {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            if let permissions = attributes[.posixPermissions] as? NSNumber,
               permissions.intValue & 0o077 != 0 {
                throw InstallationAutomationError.insecureSecretsFile(url.path)
            }
        } catch let error as InstallationAutomationError {
            throw error
        } catch {
            throw InstallationAutomationError.secretsFileUnreadable(error.localizedDescription)
        }

        let contents: String
        do {
            contents = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw InstallationAutomationError.secretsFileUnreadable(error.localizedDescription)
        }

        var parsed: [String: Secret] = [:]
        for (index, rawLine) in contents.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let lineNumber = index + 1
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.isEmpty == false, line.hasPrefix("#") == false else { continue }
            guard let separator = line.firstIndex(of: "=") else {
                throw InstallationAutomationError.malformedSecret(line: lineNumber)
            }

            let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            guard supportedKeys.contains(key) else {
                throw InstallationAutomationError.unknownSecret(key: key, line: lineNumber)
            }
            guard parsed[key] == nil else {
                throw InstallationAutomationError.duplicateSecret(key: key, line: lineNumber)
            }

            if value.hasPrefix("'") || value.hasPrefix("\"") {
                guard value.count >= 2, value.last == value.first else {
                    throw InstallationAutomationError.malformedSecret(line: lineNumber)
                }
                value.removeFirst()
                value.removeLast()
            }
            guard value.contains(where: { $0.isNewline }) == false else {
                throw InstallationAutomationError.malformedSecret(line: lineNumber)
            }
            parsed[key] = Secret(value: value)
        }
        return InstallationSecrets(values: parsed)
    }

    func required(_ key: String) throws -> Secret {
        guard let secret = values[key], secret.value.isEmpty == false else {
            throw InstallationAutomationError.missingSecret(key)
        }
        return secret
    }
}

enum DatabaseStepInput: Equatable {
    case existing(host: String, port: UInt16, database: String, username: String, password: Secret, tlsMode: DatabaseTLSMode)
    case local(username: String, password: Secret)
}

enum RedisStepInput: Equatable {
    case existing(username: String, password: Secret, host: String, port: UInt16, usesTLS: Bool)
    case local(password: Secret)
}

enum StorageStepInput: Equatable {
    case aws(region: String, bucket: String, accessKeyID: String, secretAccessKey: Secret, imagesURL: String?)
    case compatible(address: String, bucket: String, accessKeyID: String, secretAccessKey: Secret, http1Only: Bool, imagesURL: String?)
    case minIO(rootUsername: String, rootPassword: Secret)
}

struct WebStepInput: Equatable {
    let cspImageSource: String?
}

struct NonInteractiveInstallationPlan: Equatable {
    let domain: String
    let administratorName: String?
    let administratorEmail: String
    let administratorUsername: String
    let administratorPassword: Secret
    let database: DatabaseStepInput
    let redis: RedisStepInput
    let storage: StorageStepInput
    let webCSPImageSource: String?
    let httpsMode: HTTPSMode
    let proxyPort: UInt16?

    static func resolve(
        options: InstallationCommandOptions,
        secrets: InstallationSecrets
    ) throws -> NonInteractiveInstallationPlan {
        let domain = try DomainValidator.validate(required(options.domain, "domain"))
        let administratorName = try AdministratorValidator.validateName(options.administratorName)
        let administratorEmail = try AdministratorValidator.validateEmail(required(options.administratorEmail, "admin-email"))
        let administratorUsername = try validateAdministratorUsername(required(options.administratorUsername, "admin-username"))
        let administratorPassword = try AdministratorValidator.validatePassword(
            secrets.required(InstallationSecrets.administratorPasswordKey).value
        )

        let postgresPassword = try InstallationInputValidator.postgresPassword(
            secrets.required(InstallationSecrets.postgresPasswordKey).value
        )
        let postgresUsername = try InstallationInputValidator.postgresName(
            required(options.postgresUsername, "postgres-username"),
            label: "database username"
        )
        let database: DatabaseStepInput
        switch try required(options.databaseMode, "database-mode") {
        case .existing:
            database = .existing(
                host: try InstallationInputValidator.host(required(options.postgresHost, "postgres-host"), service: "PostgreSQL"),
                port: try InstallationInputValidator.port(options.postgresPort, service: "PostgreSQL"),
                database: try InstallationInputValidator.postgresName(required(options.postgresDatabase, "postgres-database"), label: "database name"),
                username: postgresUsername,
                password: postgresPassword,
                tlsMode: options.postgresTLS == .require ? .require : .disable
            )
        case .local:
            database = .local(username: postgresUsername, password: postgresPassword)
        }

        let redisPassword = try InstallationInputValidator.redisPassword(
            secrets.required(InstallationSecrets.redisPasswordKey).value
        )
        let redis: RedisStepInput
        switch try required(options.redisMode, "redis-mode") {
        case .existing:
            let username = try InstallationInputValidator.redisUsername(options.redisUsername)
            redis = .existing(
                username: username,
                password: redisPassword,
                host: try InstallationInputValidator.host(required(options.redisHost, "redis-host"), service: "Redis"),
                port: try InstallationInputValidator.port(options.redisPort, service: "Redis"),
                usesTLS: options.redisTLS == .require
            )
        case .local:
            redis = .local(password: redisPassword)
        }

        let storage: StorageStepInput
        let imagesURL = try InstallationInputValidator.imagesURL(options.imagesURL)
        switch try required(options.storageMode, "storage-mode") {
        case .aws:
            storage = .aws(
                region: try InstallationInputValidator.awsRegion(required(options.s3Region, "s3-region")),
                bucket: try InstallationInputValidator.bucket(required(options.s3Bucket, "s3-bucket")),
                accessKeyID: try InstallationInputValidator.accessKey(required(options.s3AccessKeyID, "s3-access-key-id")),
                secretAccessKey: try InstallationInputValidator.storageSecret(
                    secrets.required(InstallationSecrets.s3SecretAccessKey).value,
                    minimumLength: 1
                ),
                imagesURL: imagesURL
            )
        case .s3:
            storage = .compatible(
                address: try InstallationInputValidator.s3Address(required(options.s3Address, "s3-address")),
                bucket: try InstallationInputValidator.bucket(required(options.s3Bucket, "s3-bucket")),
                accessKeyID: try InstallationInputValidator.accessKey(required(options.s3AccessKeyID, "s3-access-key-id")),
                secretAccessKey: try InstallationInputValidator.storageSecret(
                    secrets.required(InstallationSecrets.s3SecretAccessKey).value,
                    minimumLength: 1
                ),
                http1Only: options.s3HTTPVersion == .http1,
                imagesURL: imagesURL
            )
        case .minio:
            guard imagesURL == nil else {
                throw InstallationAutomationError.invalidOption(
                    "Do not use --images-url with local MinIO. The installer exposes it automatically at https://<domain>/static-resource/."
                )
            }
            storage = .minIO(
                rootUsername: try InstallationInputValidator.minIOUsername(required(options.minIORootUsername, "minio-root-username")),
                rootPassword: try InstallationInputValidator.storageSecret(
                    secrets.required(InstallationSecrets.minIORootPasswordKey).value,
                    minimumLength: 8
                )
            )
        }

        let csp = try InstallationInputValidator.cspImageSource(options.webCSPImageSource)
        let httpsMode: HTTPSMode
        switch try required(options.httpsMode, "https-mode") {
        case .development: httpsMode = .development
        case .production: httpsMode = .production
        case .manual: httpsMode = .manual
        }
        let proxyPort = httpsMode == .manual
            ? try InstallationInputValidator.port(options.proxyPort, service: "Proxy")
            : nil

        return NonInteractiveInstallationPlan(
            domain: domain,
            administratorName: administratorName,
            administratorEmail: administratorEmail,
            administratorUsername: administratorUsername,
            administratorPassword: administratorPassword,
            database: database,
            redis: redis,
            storage: storage,
            webCSPImageSource: csp,
            httpsMode: httpsMode,
            proxyPort: proxyPort
        )
    }

    private static func required<T>(_ value: T?, _ option: String) throws -> T {
        guard let value else { throw InstallationAutomationError.missingOption(option) }
        return value
    }

    private static func validateAdministratorUsername(_ input: String) throws -> String {
        let username = try AdministratorValidator.validateUsername(input)
        guard username.lowercased() != AdministratorAccountStep.defaultAdministratorUsername else {
            throw ConfigurationValidationError.invalidUsername(
                "Choose a username other than admin because the temporary admin account will be blocked."
            )
        }
        return username
    }
}

enum InstallationInputValidator {
    static func host(_ input: String, service: String) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.isEmpty == false,
              value.count <= 253,
              value.contains(where: { $0.isWhitespace || $0.isNewline }) == false,
              value.contains("://") == false,
              value.contains("/") == false else {
            throw InstallationAutomationError.invalidOption(
                "Enter a \(service) hostname or IP address without a scheme, port, or path."
            )
        }
        return value
    }

    static func port(_ value: UInt16, service: String) throws -> UInt16 {
        guard value > 0 else {
            throw InstallationAutomationError.invalidOption("The \(service) port must be between 1 and 65535.")
        }
        return value
    }

    static func postgresName(_ input: String, label: String) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...63).contains(value.count),
              value.utf8.allSatisfy({ byte in
                  (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) ||
                  (byte >= 48 && byte <= 57) || byte == 45 || byte == 95
              }) else {
            throw InstallationAutomationError.invalidOption(
                "The \(label) must contain 1–63 ASCII letters, digits, hyphens, or underscores."
            )
        }
        return value
    }

    static func postgresPassword(_ input: String) throws -> Secret {
        guard input.isEmpty == false, input.count <= 256, input.contains(where: { $0.isNewline }) == false else {
            throw InstallationAutomationError.invalidOption(
                "The PostgreSQL password is required, cannot contain a newline, and cannot exceed 256 characters."
            )
        }
        return Secret(value: input)
    }

    static func redisUsername(_ input: String) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.isEmpty || value == "default" else {
            throw InstallationAutomationError.invalidOption(
                "Vernissage currently supports only the default Redis ACL user."
            )
        }
        return "default"
    }

    static func redisPassword(_ input: String) throws -> Secret {
        guard input.isEmpty == false, input.contains(where: { $0.isNewline }) == false else {
            throw InstallationAutomationError.invalidOption("The Redis password is required and cannot contain a newline.")
        }
        return Secret(value: input)
    }

    static func s3Address(_ input: String) throws -> String {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw InstallationAutomationError.invalidOption(
                "Enter a complete HTTP or HTTPS S3 address without credentials, query parameters, or a fragment."
            )
        }
        return value
    }

    static func awsRegion(_ input: String) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard (3...63).contains(value.count),
              value.utf8.allSatisfy({ byte in
                  (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57) || byte == 45
              }), value.first != "-", value.last != "-" else {
            throw InstallationAutomationError.invalidOption("Enter a valid AWS region such as eu-central-1.")
        }
        return value
    }

    static func bucket(_ input: String) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (3...63).contains(value.count),
              value.utf8.allSatisfy({ byte in
                  (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57) || byte == 45 || byte == 46
              }),
              value.first?.isLetter == true || value.first?.isNumber == true,
              value.last?.isLetter == true || value.last?.isNumber == true,
              value.contains("..") == false else {
            throw InstallationAutomationError.invalidOption(
                "The bucket name must contain 3–63 lowercase letters, digits, dots, or hyphens and start and end with a letter or digit."
            )
        }
        return value
    }

    static func accessKey(_ input: String) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...256).contains(value.count),
              value.contains(where: { $0.isWhitespace || $0.isNewline }) == false else {
            throw InstallationAutomationError.invalidOption("The S3 access key ID is required and cannot contain whitespace.")
        }
        return value
    }

    static func minIOUsername(_ input: String) throws -> String {
        let value = try accessKey(input)
        guard value.count >= 3 else {
            throw InstallationAutomationError.invalidOption("The MinIO root username must contain at least 3 characters.")
        }
        return value
    }

    static func storageSecret(_ input: String, minimumLength: Int) throws -> Secret {
        guard (minimumLength...512).contains(input.count), input.contains(where: { $0.isNewline }) == false else {
            throw InstallationAutomationError.invalidOption(
                "The secret is required, must contain at least \(minimumLength) characters, cannot contain a newline, and cannot exceed 512 characters."
            )
        }
        return Secret(value: input)
    }

    static func cspImageSource(_ input: String?) throws -> String? {
        var value = input?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard value.isEmpty == false else { return nil }
        guard value.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) == false }),
              let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            throw InstallationAutomationError.invalidOption(
                "Enter an HTTP or HTTPS CSP image origin without credentials, a path, query, or fragment."
            )
        }
        if value.hasSuffix("/") { value.removeLast() }
        return value
    }

    static func imagesURL(_ input: String?) throws -> String? {
        var value = input?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard value.isEmpty == false else { return nil }
        guard value.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) == false }),
              let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw InstallationAutomationError.invalidOption(
                "Enter a complete HTTP or HTTPS public image base URL without credentials, query parameters, or a fragment."
            )
        }
        if value.hasSuffix("/") == false { value.append("/") }
        return value
    }
}
