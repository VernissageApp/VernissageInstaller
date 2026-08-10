import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

struct Console {
    private enum ANSI {
        static let reset = "\u{001B}[0m"
        static let bold = "\u{001B}[1m"
        static let blue = "\u{001B}[34m"
        static let cyan = "\u{001B}[36m"
        static let green = "\u{001B}[32m"
        static let red = "\u{001B}[31m"
        static let yellow = "\u{001B}[33m"
        static let dim = "\u{001B}[2m"
    }

    private let colorsEnabled: Bool
    private let readInput: () -> String?
    private let readSecureInput: () -> String?
    private let writeOutput: (String) -> Void
    private let flushOutput: () -> Void

    init(
        colorsEnabled: Bool,
        readInput: @escaping () -> String? = { readLine() },
        readSecureInput: @escaping () -> String? = { SecureTerminalInput.readLine() },
        writeOutput: @escaping (String) -> Void = { text in
            print(text, terminator: "")
        },
        flushOutput: @escaping () -> Void = { StandardStreams.flush() }
    ) {
        self.colorsEnabled = colorsEnabled
        self.readInput = readInput
        self.readSecureInput = readSecureInput
        self.writeOutput = writeOutput
        self.flushOutput = flushOutput
    }

    static func live(colorsEnabled: Bool) -> Console {
        Console(colorsEnabled: colorsEnabled && supportsColors)
    }

    func section(_ title: String) {
        line("")
        line(styled("◆ \(title)", ANSI.bold + ANSI.cyan))
        line(styled(String(repeating: "─", count: title.count + 2), ANSI.cyan))
    }

    func guidance(_ message: String) {
        line(styled(message, ANSI.bold + ANSI.blue))
        line("")
    }

    func optionListHeader() {
        line(styled("Choose your option:", ANSI.bold))
    }

    func success(_ message: String) {
        line("\(styled("✓", ANSI.green)) \(message)")
    }

    func completion(
        _ message: String,
        values: [(label: String, value: String)] = []
    ) {
        let divider = String(repeating: "━", count: 64)
        let style = ANSI.bold + ANSI.green

        line("")
        line(styled(divider, style))
        line(styled("✓ \(message)", style))
        for value in values {
            line(styled("  \(value.label): \(value.value)", style))
        }
        line(styled(divider, style))
        line("")
    }

    func installationNextSteps() {
        line(styled("Next steps", ANSI.bold + ANSI.cyan))
        line("")
        line("The technical installation is complete, but your Vernissage instance still needs to be configured.")
        line("Sign in with your administrator account and open Settings to configure the basic instance details, email delivery, optional AI support, Web Push, and other available features.")
        line("")
        line(styled("Thank you for choosing Vernissage. We wish you many wonderful photos to share!", ANSI.bold + ANSI.green))
        line("")
    }

    func installationBetaNotice() {
        line("")
        warning(
            "The Vernissage installer is currently in beta. Please report any errors or suggestions for improvement at https://github.com/VernissageApp/VernissageInstaller/issues"
        )
        line("")
    }

    func warning(_ message: String) {
        line("\(styled("!", ANSI.bold + ANSI.yellow)) \(message)")
    }

    func info(_ message: String) {
        line("\(styled("i", ANSI.blue)) \(message)")
    }

    func pending(_ message: String) {
        line("\(styled("…", ANSI.dim)) \(styled(message, ANSI.dim))")
    }

    func diagnosticOK(_ message: String) {
        line("\(styled("[OK]", ANSI.bold + ANSI.green))   \(message)")
    }

    func diagnosticWarning(_ message: String) {
        line("\(styled("[WARN]", ANSI.bold + ANSI.yellow)) \(message)")
    }

    func diagnosticFailure(_ message: String) {
        line("\(styled("[FAIL]", ANSI.bold + ANSI.red)) \(message)")
    }

    func diagnosticSkipped(_ message: String) {
        line("\(styled("[SKIP]", ANSI.bold + ANSI.blue)) \(message)")
    }

    func coloredContainerState(_ text: String, state: String) -> String {
        switch state.lowercased() {
        case "running":
            styled(text, ANSI.green)
        case "exited":
            styled(text, ANSI.red)
        default:
            text
        }
    }

    func value(label: String, value: String) {
        line("  \(styled(label + ":", ANSI.bold)) \(value)")
    }

    func prompt(_ question: String) -> String? {
        writeOutput("\(styled("›", ANSI.cyan)) \(question) ")
        flushOutput()
        return readInput()?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func securePrompt(_ question: String) -> String? {
        writeOutput("\(styled("›", ANSI.cyan)) \(question) ")
        flushOutput()
        return readSecureInput()
    }

    func line(_ text: String) {
        writeOutput(text + "\n")
    }

    private func styled(_ text: String, _ style: String) -> String {
        guard colorsEnabled else {
            return text
        }

        return style + text + ANSI.reset
    }

    private static var supportsColors: Bool {
        let environment = ProcessInfo.processInfo.environment

        guard environment["NO_COLOR"] == nil,
              environment["TERM"]?.lowercased() != "dumb" else {
            return false
        }

        #if canImport(Darwin)
        return Darwin.isatty(Darwin.STDOUT_FILENO) == 1
        #elseif canImport(Glibc)
        return Glibc.isatty(Glibc.STDOUT_FILENO) == 1
        #elseif canImport(Musl)
        return Musl.isatty(Musl.STDOUT_FILENO) == 1
        #else
        return false
        #endif
    }
}

private enum StandardStreams {
    static func flush() {
        #if canImport(Darwin)
        _ = Darwin.fflush(nil)
        #elseif canImport(Glibc)
        _ = Glibc.fflush(nil)
        #elseif canImport(Musl)
        _ = Musl.fflush(nil)
        #endif
    }
}

private enum SecureTerminalInput {
    static func readLine() -> String? {
        guard isInputTerminal else {
            let value = Swift.readLine()
            print("")
            return value
        }

        var originalSettings = termios()
        guard tcgetattr(STDIN_FILENO, &originalSettings) == 0 else {
            return Swift.readLine()
        }

        var hiddenSettings = originalSettings
        hiddenSettings.c_lflag &= ~tcflag_t(ECHO)

        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &hiddenSettings) == 0 else {
            return Swift.readLine()
        }

        defer {
            _ = tcsetattr(STDIN_FILENO, TCSANOW, &originalSettings)
            print("")
        }

        return Swift.readLine()
    }

    private static var isInputTerminal: Bool {
        #if canImport(Darwin)
        Darwin.isatty(Darwin.STDIN_FILENO) == 1
        #elseif canImport(Glibc)
        Glibc.isatty(Glibc.STDIN_FILENO) == 1
        #elseif canImport(Musl)
        Musl.isatty(Musl.STDIN_FILENO) == 1
        #else
        false
        #endif
    }
}
