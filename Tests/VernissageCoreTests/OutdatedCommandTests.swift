import Testing
@testable import VernissageCore

struct OutdatedCommandTests {
    @Test
    func `Registry digests are compared once per image and PostgreSQL keeps major tag`() throws {
        let currentServerDigest = digest("a")
        let currentPostgresDigest = digest("b")
        let registryPostgresDigest = digest("c")
        let containers = [
            ManagedContainer(
                service: "API",
                name: "vernissage-abcdefgh-api",
                expectedImage: "mczachurski/vernissage-server:latest"
            ),
            ManagedContainer(
                service: "Jobs",
                name: "vernissage-abcdefgh-jobs",
                expectedImage: "mczachurski/vernissage-server:latest"
            ),
            ManagedContainer(
                service: "PostgreSQL",
                name: "vernissage-abcdefgh-postgres",
                expectedImage: "postgres:18"
            ),
            ManagedContainer(
                service: "Proxy",
                name: "vernissage-abcdefgh-proxy",
                expectedImage: "vernissage-proxy:abcdefgh",
                imageUpdateSource: .localBuild
            ),
            ManagedContainer(
                service: "Web",
                name: "vernissage-abcdefgh-web",
                expectedImage: "mczachurski/vernissage-web:latest"
            )
        ]
        let statuses = [
            makeStatus(containers[0], digest: currentServerDigest),
            makeStatus(containers[1], digest: currentServerDigest),
            makeStatus(containers[2], digest: currentPostgresDigest),
            makeStatus(containers[3], digest: digest("d")),
            .missing(containers[4])
        ]
        let runner = OutdatedCommandRunner(results: [
            .success(#"["linux","aarch64"]"#),
            .success(manifest(arm64Digest: currentServerDigest)),
            .success(manifest(arm64Digest: registryPostgresDigest))
        ])

        let updates = try DockerRegistryUpdateChecker(
            commandRunner: runner
        ).check(containers: containers, statuses: statuses)

        #expect(updates.map(\.state) == [
            .upToDate, .upToDate, .outdated, .localBuild, .missing
        ])
        #expect(updates[0].registryDigest == currentServerDigest)
        #expect(updates[1].registryDigest == currentServerDigest)
        #expect(updates[2].currentDigest == currentPostgresDigest)
        #expect(updates[2].registryDigest == registryPostgresDigest)
        #expect(runner.invocations == [
            OutdatedDockerInvocation(
                executable: "docker",
                arguments: [
                    "info", "--format",
                    "[{{json .OSType}},{{json .Architecture}}]"
                ]
            ),
            OutdatedDockerInvocation(
                executable: "docker",
                arguments: [
                    "manifest", "inspect", "--verbose",
                    "mczachurski/vernissage-server:latest"
                ]
            ),
            OutdatedDockerInvocation(
                executable: "docker",
                arguments: ["manifest", "inspect", "--verbose", "postgres:18"]
            )
        ])
    }

    @Test
    func `Missing and local images do not contact registry`() throws {
        let proxy = ManagedContainer(
            service: "Proxy",
            name: "vernissage-abcdefgh-proxy",
            expectedImage: "vernissage-proxy:abcdefgh",
            imageUpdateSource: .localBuild
        )
        let api = ManagedContainer(
            service: "API",
            name: "vernissage-abcdefgh-api",
            expectedImage: "server:latest"
        )
        let runner = OutdatedCommandRunner(results: [])

        let updates = try DockerRegistryUpdateChecker(
            commandRunner: runner
        ).check(
            containers: [proxy, api],
            statuses: [
                makeStatus(proxy, digest: digest("a")),
                .missing(api)
            ]
        )

        #expect(updates.map(\.state) == [.localBuild, .missing])
        #expect(runner.invocations.isEmpty)
    }

    @Test
    func `Registry failure is reported for image without stopping other rows`() throws {
        let api = ManagedContainer(
            service: "API",
            name: "vernissage-abcdefgh-api",
            expectedImage: "server:latest"
        )
        let runner = OutdatedCommandRunner(results: [
            .success(#"["linux","amd64"]"#),
            CommandResult(
                exitCode: 1,
                standardOutput: "",
                standardError: "manifest unknown"
            )
        ])

        let updates = try DockerRegistryUpdateChecker(
            commandRunner: runner
        ).check(
            containers: [api],
            statuses: [makeStatus(api, digest: digest("a"))]
        )

        #expect(updates == [
            ImageUpdateStatus(
                service: "API",
                container: "vernissage-abcdefgh-api",
                image: "server:latest",
                currentDigest: digest("a"),
                registryDigest: nil,
                state: .unavailable,
                details: "manifest unknown"
            )
        ])
    }

    @Test
    func `Invalid Docker platform response stops registry comparison`() {
        let api = ManagedContainer(
            service: "API",
            name: "vernissage-abcdefgh-api",
            expectedImage: "server:latest"
        )
        let runner = OutdatedCommandRunner(results: [.success("linux/amd64")])

        let error = #expect(throws: DockerRegistryUpdateError.self) {
            try DockerRegistryUpdateChecker(commandRunner: runner).check(
                containers: [api],
                statuses: [makeStatus(api, digest: digest("a"))]
            )
        }

        #expect(error == .invalidPlatformResponse("linux/amd64"))
    }

    @Test
    func `Manifest parser selects image configuration for Docker platform`() throws {
        let expectedDigest = digest("c")

        let selected = try RegistryManifestParser().configurationDigest(
            from: manifest(arm64Digest: expectedDigest),
            platform: DockerPlatform(
                operatingSystem: "linux",
                architecture: "aarch64"
            )
        )

        #expect(selected == expectedDigest)
    }

    @Test
    func `Manifest parser supports a single schema version two manifest`() throws {
        let expectedDigest = digest("e")
        let response = #"{"SchemaV2Manifest":{"config":{"digest":"\#(expectedDigest)"}}}"#

        let selected = try RegistryManifestParser().configurationDigest(
            from: response,
            platform: DockerPlatform(
                operatingSystem: "linux",
                architecture: "amd64"
            )
        )

        #expect(selected == expectedDigest)
    }

    @Test
    func `Manifest without current platform is rejected`() {
        let error = #expect(throws: RegistryManifestParsingError.self) {
            try RegistryManifestParser().configurationDigest(
                from: manifest(arm64Digest: digest("a")),
                platform: DockerPlatform(
                    operatingSystem: "linux",
                    architecture: "s390x"
                )
            )
        }

        #expect(
            error == .platformNotFound(
                DockerPlatform(operatingSystem: "linux", architecture: "s390x")
            )
        )
    }

    @Test
    func `Outdated report renders comparison and warnings`() {
        let context = InstallationContext(instanceIdentifier: "abcdefgh")
        context.summaryFilePath = "/srv/vernissage/vernissage.yml"
        let output = OutdatedOutputBuffer()
        let updates = [
            ImageUpdateStatus(
                service: "API",
                container: "vernissage-abcdefgh-api",
                image: "server:latest",
                currentDigest: digest("a"),
                registryDigest: digest("b"),
                state: .outdated,
                details: nil
            ),
            ImageUpdateStatus(
                service: "Proxy",
                container: "vernissage-abcdefgh-proxy",
                image: "vernissage-proxy:abcdefgh",
                currentDigest: digest("c"),
                registryDigest: nil,
                state: .localBuild,
                details: nil
            )
        ]

        OutdatedReportRenderer(
            console: Console(
                colorsEnabled: false,
                readInput: { nil },
                writeOutput: output.append
            )
        ).render(context: context, updates: updates)

        #expect(output.text.contains("◆ Vernissage image updates"))
        #expect(output.text.contains("CURRENT DIGEST"))
        #expect(output.text.contains("REGISTRY DIGEST"))
        #expect(output.text.contains("sha256:aaaaaaaaaaaa"))
        #expect(output.text.contains("sha256:bbbbbbbbbbbb"))
        #expect(output.text.contains("outdated"))
        #expect(output.text.contains("local build"))
        #expect(output.text.contains("1 container image update is available."))
    }

    @Test
    func `Outdated command parses shared configuration and color option`() throws {
        let parsed = try VernissageCommand.parseAsRoot([
            "outdated", "--config", "/srv/vernissage/vernissage.yml", "--no-color"
        ])
        let command = try #require(parsed as? OutdatedCommand)

        #expect(command.configurationOptions.configPath == "/srv/vernissage/vernissage.yml")
        #expect(command.noColor)
    }

    private func makeStatus(
        _ container: ManagedContainer,
        digest: String
    ) -> ContainerStatus {
        ContainerStatus(
            service: container.service,
            container: container.name,
            state: "running",
            health: "healthy",
            image: container.expectedImage,
            digest: digest,
            ports: [],
            uptime: 60
        )
    }

    private func manifest(arm64Digest: String) -> String {
        #"""
        [
          {
            "Descriptor": {
              "platform": { "architecture": "amd64", "os": "linux" }
            },
            "OCIManifest": {
              "config": { "digest": "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd" }
            }
          },
          {
            "Descriptor": {
              "platform": { "architecture": "unknown", "os": "unknown" }
            },
            "OCIManifest": {
              "config": { "digest": "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" }
            }
          },
          {
            "Descriptor": {
              "platform": { "architecture": "arm64", "os": "linux" }
            },
            "OCIManifest": {
              "config": { "digest": "\#(arm64Digest)" }
            }
          }
        ]
        """#
    }

    private func digest(_ character: Character) -> String {
        "sha256:" + String(repeating: String(character), count: 64)
    }
}

private struct OutdatedDockerInvocation: Equatable {
    let executable: String
    let arguments: [String]
}

private enum OutdatedCommandRunnerError: Error {
    case resultNotConfigured
}

private final class OutdatedCommandRunner: CommandRunning {
    private var results: [CommandResult]
    private(set) var invocations: [OutdatedDockerInvocation] = []

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
            OutdatedDockerInvocation(
                executable: executable,
                arguments: arguments
            )
        )
        guard results.isEmpty == false else {
            throw OutdatedCommandRunnerError.resultNotConfigured
        }
        return results.removeFirst()
    }
}

private final class OutdatedOutputBuffer {
    private(set) var text = ""

    func append(_ value: String) {
        text += value
    }
}

private extension CommandResult {
    static func success(_ output: String) -> CommandResult {
        CommandResult(exitCode: 0, standardOutput: output, standardError: "")
    }
}
