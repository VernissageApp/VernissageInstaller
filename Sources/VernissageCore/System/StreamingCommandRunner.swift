import Dispatch
import Foundation
import Synchronization

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

struct StreamingCommandResult: Equatable {
    let exitCode: Int32
    let wasInterrupted: Bool

    init(exitCode: Int32, wasInterrupted: Bool = false) {
        self.exitCode = exitCode
        self.wasInterrupted = wasInterrupted
    }

    var succeeded: Bool { exitCode == 0 || wasInterrupted }
}

protocol StreamingCommandRunning {
    func runStreaming(
        _ executable: String,
        arguments: [String],
        environment: [String: String]
    ) throws -> StreamingCommandResult
}

extension StreamingCommandRunning {
    func runStreaming(
        _ executable: String,
        arguments: [String]
    ) throws -> StreamingCommandResult {
        try runStreaming(
            executable,
            arguments: arguments,
            environment: [:]
        )
    }
}

struct ProcessStreamingCommandRunner: StreamingCommandRunning {
    func runStreaming(
        _ executable: String,
        arguments: [String],
        environment: [String: String]
    ) throws -> StreamingCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "trap - INT; exec \"$@\"",
            "vernissagectl-streaming-command",
            executable,
        ] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging(
            environment
        ) { _, new in new }
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        let childProcessIdentifier = Mutex<pid_t?>(nil)
        let interruptionReceived = Mutex(false)
        let previousInterruptHandler = signal(SIGINT, SIG_IGN)
        let interruptSource = DispatchSource.makeSignalSource(
            signal: SIGINT,
            queue: DispatchQueue.global(qos: .userInitiated)
        )

        interruptSource.setEventHandler {
            interruptionReceived.withLock { received in
                received = true
            }

            guard let processIdentifier = childProcessIdentifier.withLock({
                $0
            }) else {
                return
            }

            _ = kill(processIdentifier, SIGINT)
        }
        interruptSource.resume()

        defer {
            interruptSource.cancel()
            _ = signal(SIGINT, previousInterruptHandler)
        }

        try process.run()
        childProcessIdentifier.withLock { processIdentifier in
            processIdentifier = process.processIdentifier
        }
        if interruptionReceived.withLock({ $0 }) {
            _ = kill(process.processIdentifier, SIGINT)
        }
        process.waitUntilExit()

        return StreamingCommandResult(
            exitCode: process.terminationStatus,
            wasInterrupted: interruptionReceived.withLock { $0 }
        )
    }
}
