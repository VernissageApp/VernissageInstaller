public struct CommandResult: Equatable, Sendable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String

    public init(
        exitCode: Int32,
        standardOutput: String = "",
        standardError: String = ""
    ) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public enum VernissageVersion {
    public static let current = "0.1.1"
}

public struct CommandRunner: Sendable {
    public init() {}

    public func run(arguments: [String]) -> CommandResult {
        guard let command = arguments.first else {
            return CommandResult(
                exitCode: 0,
                standardOutput: """
                vernissagectl \(VernissageVersion.current)
                The Vernissage installer is ready.

                """
            )
        }

        switch command {
        case "--version", "-v", "version":
            return CommandResult(
                exitCode: 0,
                standardOutput: "vernissagectl \(VernissageVersion.current)\n"
            )
        case "--help", "-h", "help":
            return CommandResult(
                exitCode: 0,
                standardOutput: Self.help
            )
        default:
            return CommandResult(
                exitCode: 64,
                standardError: "Unknown command: \(command)\n\n\(Self.help)"
            )
        }
    }

    private static let help = """
    OVERVIEW: Command-line installer and administration tool for Vernissage.

    USAGE: vernissagectl <command>

    COMMANDS:
      version                 Show the installed vernissagectl version.
      help                    Show this help message.

    OPTIONS:
      -v, --version           Show the installed vernissagectl version.
      -h, --help              Show this help message.

    """
}
