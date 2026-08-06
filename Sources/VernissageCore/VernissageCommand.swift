import ArgumentParser
import Foundation

public enum VernissageVersion {
    public static let current = "0.1.2"
    public static let formatted = "vernissagectl \(current)"
}

public struct VernissageCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "vernissagectl",
        abstract: "Command-line installer and administration tool for Vernissage.",
        version: VernissageVersion.formatted,
        subcommands: [VersionCommand.self]
    )

    public init() {}

    public mutating func run() throws {
        print(
            """
            \(VernissageVersion.formatted)
            The Vernissage installer is ready.
            """
        )
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
