import Foundation

struct CommandResult: Equatable {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String

    var succeeded: Bool { exitCode == 0 }
}

protocol CommandRunning {
    func run(
        _ executable: String,
        arguments: [String],
        environment: [String: String],
        standardInput: String?
    ) throws -> CommandResult
}

extension CommandRunning {
    func run(_ executable: String, arguments: [String]) throws -> CommandResult {
        try run(
            executable,
            arguments: arguments,
            environment: [:],
            standardInput: nil
        )
    }
}

struct ProcessCommandRunner: CommandRunning {
    func run(
        _ executable: String,
        arguments: [String],
        environment: [String: String],
        standardInput: String?
    ) throws -> CommandResult {
        let process = Process()
        let input = Pipe()
        let standardOutput = Pipe()
        let standardError = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        if standardInput != nil {
            process.standardInput = input
        }
        process.standardOutput = standardOutput
        process.standardError = standardError

        try process.run()

        if let standardInput {
            input.fileHandleForWriting.write(Data(standardInput.utf8))
            try input.fileHandleForWriting.close()
        }

        let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return CommandResult(
            exitCode: process.terminationStatus,
            standardOutput: decoded(outputData),
            standardError: decoded(errorData)
        )
    }

    private func decoded(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
