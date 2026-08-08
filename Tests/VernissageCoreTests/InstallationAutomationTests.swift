import Foundation
import Testing
@testable import VernissageCore

struct InstallationAutomationTests {
    @Test
    func `Quoted secrets file is parsed without exposing values`() throws {
        let fixture = try SecretsFileFixture(
            contents: """
            # Created for unattended installation.
            VERNISSAGE_ADMIN_PASSWORD='Admin-1234'
            VERNISSAGE_POSTGRES_PASSWORD='Postgres-1234'
            VERNISSAGE_REDIS_PASSWORD='Redis-1234'
            VERNISSAGE_S3_SECRET_ACCESS_KEY='S3-secret-value'
            VERNISSAGE_MINIO_ROOT_PASSWORD='Minio-1234'
            """
        )
        defer { fixture.remove() }

        let secrets = try InstallationSecrets.load(from: fixture.url)

        #expect(try secrets.required(InstallationSecrets.administratorPasswordKey).value == "Admin-1234")
        #expect(try secrets.required(InstallationSecrets.postgresPasswordKey).value == "Postgres-1234")
        #expect(try secrets.required(InstallationSecrets.redisPasswordKey).value == "Redis-1234")
        #expect(try secrets.required(InstallationSecrets.s3SecretAccessKey).value == "S3-secret-value")
        #expect(try secrets.required(InstallationSecrets.minIORootPasswordKey).value == "Minio-1234")
        #expect(String(describing: try secrets.required(InstallationSecrets.administratorPasswordKey)) == "<redacted>")
    }

    @Test
    func `Secrets file readable by other users is rejected`() throws {
        let fixture = try SecretsFileFixture(
            contents: "VERNISSAGE_ADMIN_PASSWORD='Admin-1234'\n",
            permissions: 0o644
        )
        defer { fixture.remove() }

        #expect(throws: InstallationAutomationError.insecureSecretsFile(fixture.url.path)) {
            _ = try InstallationSecrets.load(from: fixture.url)
        }
    }

    @Test
    func `Unknown secret key is rejected`() throws {
        let fixture = try SecretsFileFixture(contents: "PASSWORD='do-not-accept'\n")
        defer { fixture.remove() }

        #expect(throws: InstallationAutomationError.unknownSecret(key: "PASSWORD", line: 1)) {
            _ = try InstallationSecrets.load(from: fixture.url)
        }
    }

    @Test
    func `Existing managed services produce a complete installation plan`() throws {
        let command = try InstallCommand.parse([
            "--non-interactive",
            "--secrets-file", "secrets.env",
            "--domain", "Social.Example.com",
            "--admin-email", "jan@example.com",
            "--admin-username", "jankowalski",
            "--database-mode", "existing",
            "--postgres-host", "postgres.example.com",
            "--postgres-database", "vernissage",
            "--postgres-username", "vernissage_user",
            "--redis-mode", "existing",
            "--redis-host", "redis.example.com",
            "--storage-mode", "aws",
            "--s3-region", "EU-CENTRAL-1",
            "--s3-bucket", "vernissage-media",
            "--s3-access-key-id", "access-key",
            "--images-url", "https://cdn.example.com/vernissage",
            "--https-mode", "production"
        ])
        let secrets = completeSecrets()

        let plan = try NonInteractiveInstallationPlan.resolve(
            options: command.options,
            secrets: secrets
        )

        #expect(plan.domain == "social.example.com")
        #expect(plan.administratorName == nil)
        #expect(plan.administratorPassword.description == "<redacted>")
        #expect(plan.database == .existing(
            host: "postgres.example.com",
            port: 5432,
            database: "vernissage",
            username: "vernissage_user",
            password: Secret(value: "Postgres-1234"),
            tlsMode: .require
        ))
        #expect(plan.redis == .existing(
            username: "default",
            password: Secret(value: "Redis-1234"),
            host: "redis.example.com",
            port: 6379,
            usesTLS: true
        ))
        #expect(plan.storage == .aws(
            region: "eu-central-1",
            bucket: "vernissage-media",
            accessKeyID: "access-key",
            secretAccessKey: Secret(value: "S3-secret-value"),
            imagesURL: "https://cdn.example.com/vernissage/"
        ))
        #expect(plan.httpsMode == .production)
        #expect(plan.proxyPort == nil)
    }

    @Test
    func `Local services use passwords from the secrets file`() throws {
        let command = try InstallCommand.parse([
            "--non-interactive",
            "--secrets-file", "secrets.env",
            "--domain", "social.example.com",
            "--admin-email", "jan@example.com",
            "--admin-username", "jankowalski",
            "--database-mode", "local",
            "--postgres-username", "vernissage",
            "--redis-mode", "local",
            "--storage-mode", "minio",
            "--minio-root-username", "vernissage",
            "--https-mode", "manual",
            "--proxy-port", "9080"
        ])

        let plan = try NonInteractiveInstallationPlan.resolve(
            options: command.options,
            secrets: completeSecrets()
        )

        #expect(plan.database == .local(
            username: "vernissage",
            password: Secret(value: "Postgres-1234")
        ))
        #expect(plan.redis == .local(password: Secret(value: "Redis-1234")))
        #expect(plan.storage == .minIO(
            rootUsername: "vernissage",
            rootPassword: Secret(value: "Minio-1234")
        ))
        #expect(plan.httpsMode == .manual)
        #expect(plan.proxyPort == 9080)
    }

    @Test
    func `Missing conditional option fails before installation begins`() throws {
        let command = try InstallCommand.parse([
            "--non-interactive",
            "--secrets-file", "secrets.env",
            "--domain", "social.example.com",
            "--admin-email", "jan@example.com",
            "--admin-username", "jankowalski",
            "--database-mode", "existing",
            "--postgres-database", "vernissage",
            "--postgres-username", "vernissage",
            "--redis-mode", "local",
            "--storage-mode", "minio",
            "--minio-root-username", "vernissage",
            "--https-mode", "development"
        ])

        #expect(throws: InstallationAutomationError.missingOption("postgres-host")) {
            _ = try NonInteractiveInstallationPlan.resolve(
                options: command.options,
                secrets: completeSecrets()
            )
        }
    }

    @Test
    func `Local MinIO rejects a custom images URL`() throws {
        let command = try InstallCommand.parse([
            "--non-interactive",
            "--secrets-file", "secrets.env",
            "--domain", "social.example.com",
            "--admin-email", "jan@example.com",
            "--admin-username", "jankowalski",
            "--database-mode", "local",
            "--postgres-username", "vernissage",
            "--redis-mode", "local",
            "--storage-mode", "minio",
            "--minio-root-username", "vernissage",
            "--images-url", "https://cdn.example.com/",
            "--https-mode", "development"
        ])

        #expect(throws: InstallationAutomationError.invalidOption(
            "Do not use --images-url with local MinIO. The installer exposes it automatically at https://<domain>/static-resource/."
        )) {
            _ = try NonInteractiveInstallationPlan.resolve(
                options: command.options,
                secrets: completeSecrets()
            )
        }
    }

    private func completeSecrets() -> InstallationSecrets {
        InstallationSecrets(values: [
            InstallationSecrets.administratorPasswordKey: Secret(value: "Admin-1234"),
            InstallationSecrets.postgresPasswordKey: Secret(value: "Postgres-1234"),
            InstallationSecrets.redisPasswordKey: Secret(value: "Redis-1234"),
            InstallationSecrets.s3SecretAccessKey: Secret(value: "S3-secret-value"),
            InstallationSecrets.minIORootPasswordKey: Secret(value: "Minio-1234")
        ])
    }
}

private struct SecretsFileFixture {
    let directory: URL
    let url: URL

    init(contents: String, permissions: Int = 0o600) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vernissage-secrets-tests-\(UUID().uuidString)", isDirectory: true)
        url = directory.appendingPathComponent("secrets.env")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: permissions)],
            ofItemAtPath: url.path
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
