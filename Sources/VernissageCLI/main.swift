import VernissageCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

let result = CommandRunner().run(arguments: Array(CommandLine.arguments.dropFirst()))

if !result.standardOutput.isEmpty {
    print(result.standardOutput, terminator: "")
}

if !result.standardError.isEmpty {
    fputs(result.standardError, stderr)
}

exit(result.exitCode)
