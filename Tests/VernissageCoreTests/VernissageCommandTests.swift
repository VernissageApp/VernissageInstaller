import ArgumentParser
import Testing
@testable import VernissageCore

struct VernissageCommandTests {
    @Test
    func `Current version is formatted`() {
        #expect(VernissageVersion.current == "0.1.3")
        #expect(VernissageVersion.formatted == "vernissagectl 0.1.3")
    }

    @Test
    func `Root command accepts no arguments`() throws {
        _ = try VernissageCommand.parse([])
    }

    @Test
    func `Root command parses long configuration option`() throws {
        let command = try VernissageCommand.parse([
            "--config", "/srv/vernissage/vernissage.yml"
        ])

        #expect(command.configurationOptions.configPath == "/srv/vernissage/vernissage.yml")
    }

    @Test
    func `Root command parses short configuration option`() throws {
        let command = try VernissageCommand.parse([
            "-f", "/srv/vernissage/vernissage.yml"
        ])

        #expect(command.configurationOptions.configPath == "/srv/vernissage/vernissage.yml")
    }

    @Test
    func `Version command accepts no arguments`() throws {
        _ = try VersionCommand.parse([])
    }

    @Test
    func `Install command parses non-secret options`() throws {
        let command = try InstallCommand.parse([
            "--domain", "social.example.com",
            "--admin-name", "Jan Kowalski",
            "--admin-email", "jan@example.com",
            "--admin-username", "jankowalski",
            "--no-color"
        ])

        #expect(command.options.domain == "social.example.com")
        #expect(command.options.administratorName == "Jan Kowalski")
        #expect(command.options.administratorEmail == "jan@example.com")
        #expect(command.options.administratorUsername == "jankowalski")
        #expect(command.noColor)
    }

    @Test
    func `Install command parses every non-interactive option`() throws {
        let command = try InstallCommand.parse([
            "--non-interactive",
            "--secrets-file", "/run/secrets/vernissage",
            "--install-directory", "/srv/vernissage-one",
            "--instance-id", "abcdefgh",
            "--domain", "social.example.com",
            "--admin-name", "Jan Kowalski",
            "--admin-email", "jan@example.com",
            "--admin-username", "jankowalski",
            "--database-mode", "existing",
            "--postgres-host", "postgres.example.com",
            "--postgres-port", "5433",
            "--postgres-database", "vernissage",
            "--postgres-username", "vernissage",
            "--postgres-tls", "require",
            "--redis-mode", "existing",
            "--redis-username", "default",
            "--redis-host", "redis.example.com",
            "--redis-port", "6380",
            "--redis-tls", "disable",
            "--storage-mode", "s3",
            "--s3-address", "https://objects.example.com",
            "--s3-bucket", "vernissage-media",
            "--s3-access-key-id", "access-key",
            "--s3-http-version", "http1",
            "--web-csp-image-source", "https://media.example.com",
            "--https-mode", "manual",
            "--proxy-port", "8443"
        ])

        #expect(command.options.nonInteractive)
        #expect(command.options.secretsFile == "/run/secrets/vernissage")
        #expect(command.options.installDirectory == "/srv/vernissage-one")
        #expect(command.options.instanceIdentifier == "abcdefgh")
        #expect(command.options.databaseMode == .existing)
        #expect(command.options.postgresPort == 5433)
        #expect(command.options.redisMode == .existing)
        #expect(command.options.redisPort == 6380)
        #expect(command.options.storageMode == .s3)
        #expect(command.options.s3HTTPVersion == .http1)
        #expect(command.options.httpsMode == .manual)
        #expect(command.options.proxyPort == 8443)
    }

    @Test
    func `Unknown option fails parsing`() {
        do {
            _ = try VernissageCommand.parse(["--unknown-option"])
            Issue.record("Expected parsing to fail for an unknown option.")
        } catch {
            // Any parser error is sufficient for this invalid invocation.
        }
    }

    @Test
    func `Passwords cannot be supplied as command-line options`() {
        do {
            _ = try InstallCommand.parse([
                "--non-interactive",
                "--admin-password", "visible-secret"
            ])
            Issue.record("Expected a password command-line option to be rejected.")
        } catch {
            // Rejection is the security contract; passwords are loaded only from --secrets-file.
        }
    }

    @Test
    func `Version option exits successfully`() {
        do {
            _ = try VernissageCommand.parseAsRoot(["--version"])
            Issue.record("Expected --version to produce a clean parser exit.")
        } catch {
            #expect(VernissageCommand.exitCode(for: error) == .success)
            #expect(VernissageCommand.message(for: error) == VernissageVersion.formatted)
        }
    }
}
