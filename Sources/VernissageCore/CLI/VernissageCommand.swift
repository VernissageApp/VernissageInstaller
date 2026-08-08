import ArgumentParser
import Foundation

public struct VernissageCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "vernissagectl",
        abstract: "Command-line installer and administration tool for Vernissage.",
        version: VernissageVersion.formatted,
        subcommands: [
            BackupCommand.self,
            DoctorCommand.self,
            InstallCommand.self,
            LogsCommand.self,
            OutdatedCommand.self,
            RestartCommand.self,
            ServicesCommand.self,
            StartCommand.self,
            StatusCommand.self,
            StopCommand.self,
            RestoreCommand.self,
            UpdateCommand.self,
            VersionCommand.self
        ]
    )

    @OptionGroup
    var configurationOptions: ConfigurationOptions

    public init() {}

    public mutating func run() throws {
        if configurationOptions.configPath != nil {
            do {
                let context = try configurationOptions.loadContext()
                print("Loaded Vernissage configuration from \(context.summaryFilePath ?? "vernissage.yml").")
                return
            } catch {
                throw ValidationError(error.localizedDescription)
            }
        }

        print(
            """
            \(VernissageVersion.formatted)
            The Vernissage installer is ready.
            """
        )
    }
}

struct ConfigurationOptions: ParsableArguments {
    @Option(
        name: [.customShort("f"), .customLong("config")],
        help: "Path to vernissage.yml. Defaults to VERNISSAGE_CONFIG, ./vernissage.yml, then ./vernissage/vernissage.yml."
    )
    var configPath: String?

    func loadContext(
        using loader: InstallationConfigurationLoader = InstallationConfigurationLoader()
    ) throws -> InstallationContext {
        try loader.load(configPath: configPath)
    }
}

public struct InstallCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Configure and install a Vernissage instance."
    )

    @OptionGroup
    var options: InstallationCommandOptions

    @Flag(
        name: .long,
        help: "Disable ANSI colors in terminal output."
    )
    var noColor = false

    public init() {}

    public mutating func run() throws {
        let originalWorkingDirectory = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        let plan: NonInteractiveInstallationPlan?
        if options.nonInteractive {
            guard let secretsPath = options.secretsFile else {
                throw ValidationError(InstallationAutomationError.secretsFileRequired.localizedDescription)
            }
            let secretsURL = URL(
                fileURLWithPath: secretsPath,
                relativeTo: originalWorkingDirectory
            ).standardizedFileURL
            do {
                let secrets = try InstallationSecrets.load(from: secretsURL)
                plan = try NonInteractiveInstallationPlan.resolve(options: options, secrets: secrets)
            } catch {
                throw ValidationError(error.localizedDescription)
            }
        } else {
            guard options.containsNonInteractiveOnlyValues == false else {
                throw ValidationError(
                    "Automation-only installation options require --non-interactive. Without it, the terminal wizard collects those values securely."
                )
            }
            plan = nil
        }

        let instanceIdentifier = options.instanceIdentifier ?? InstallationIdentity.generate()
        guard InstallationIdentity.isValid(instanceIdentifier) else {
            throw ValidationError("The --instance-id value must contain exactly eight lowercase ASCII letters.")
        }

        let installationDirectory = URL(
            fileURLWithPath: options.installDirectory,
            relativeTo: originalWorkingDirectory
        ).standardizedFileURL
        do {
            try FileManager.default.createDirectory(
                at: installationDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw ValidationError("The installation directory could not be created. Details: \(error.localizedDescription)")
        }
        guard FileManager.default.changeCurrentDirectoryPath(installationDirectory.path) else {
            throw ValidationError("The installer could not use \(installationDirectory.path) as its working directory.")
        }
        defer {
            _ = FileManager.default.changeCurrentDirectoryPath(originalWorkingDirectory.path)
        }

        let context = InstallationContext(
            instanceIdentifier: instanceIdentifier
        )
        let console = Console.live(colorsEnabled: !noColor)
        console.info("Generated installation identifier: \(instanceIdentifier)")
        console.value(label: "Installation directory", value: installationDirectory.path)
        if options.nonInteractive {
            console.info("Non-interactive installation plan validated. No values will be read from standard input.")
        }
        let prerequisitesStep = PrerequisitesStep.live(colorsEnabled: !noColor)
        let serverAndDomainStep = ServerAndDomainStep.live(colorsEnabled: !noColor)
        let administratorAccountStep = AdministratorAccountStep.live(colorsEnabled: !noColor)
        let databaseStep = DatabaseStep.live(colorsEnabled: !noColor)
        let redisStep = RedisStep.live(colorsEnabled: !noColor)
        let storageStep = StorageStep.live(colorsEnabled: !noColor)
        let serverServicesStep = ServerServicesStep.live(colorsEnabled: !noColor)
        let webStep = WebStep.live(colorsEnabled: !noColor)
        let pushStep = PushStep.live(colorsEnabled: !noColor)
        let publicAccessStep = PublicAccessStep.live(colorsEnabled: !noColor)
        let proxyStep = ProxyStep.live(colorsEnabled: !noColor)
        let caddyStep = CaddyStep.live(colorsEnabled: !noColor)
        let installationSummaryStep = InstallationSummaryStep.live(colorsEnabled: !noColor)

        do {
            try prerequisitesStep.run(context: context)
            try serverAndDomainStep.run(
                context: context,
                providedDomain: plan?.domain ?? options.domain
            )
            try databaseStep.run(context: context, input: plan?.database)
            try redisStep.run(context: context, input: plan?.redis)
            try storageStep.run(context: context, input: plan?.storage)
            try serverServicesStep.run(context: context)
            try administratorAccountStep.run(
                context: context,
                providedName: plan?.administratorName ?? options.administratorName,
                providedEmail: plan?.administratorEmail ?? options.administratorEmail,
                providedUsername: plan?.administratorUsername ?? options.administratorUsername,
                providedPassword: plan?.administratorPassword
            )
            try webStep.run(
                context: context,
                input: plan.map { WebStepInput(cspImageSource: $0.webCSPImageSource) }
            )
            try pushStep.run(context: context)
            try publicAccessStep.run(context: context, providedMode: plan?.httpsMode)
            try proxyStep.run(context: context, providedHostPort: plan?.proxyPort)
            try caddyStep.run(context: context)
            try installationSummaryStep.run(context: context)
        } catch {
            throw ValidationError(error.localizedDescription)
        }
    }
}

public struct VersionCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "version",
        abstract: "Show the installed vernissagectl version."
    )

    public init() {}

    public mutating func run() throws {
        print(VernissageVersion.formatted)
    }
}
