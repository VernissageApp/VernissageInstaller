import Testing
@testable import VernissageCore

struct ConsoleTests {
    @Test
    func `Completion banner is separated and readable without colors`() {
        let output = ConsoleOutputBuffer()
        let console = Console(
            colorsEnabled: false,
            writeOutput: output.append
        )

        console.completion(
            "Vernissage is available through Caddy over HTTPS.",
            values: [("HTTPS endpoint", "https://social.example.com")]
        )

        #expect(output.text.hasPrefix("\n"))
        #expect(output.text.hasSuffix("\n\n"))
        #expect(output.text.contains("✓ Vernissage is available through Caddy over HTTPS."))
        #expect(output.text.contains("  HTTPS endpoint: https://social.example.com"))
        #expect(output.text.components(separatedBy: String(repeating: "━", count: 64)).count == 3)
        #expect(output.text.contains("\u{001B}[") == false)
    }

    @Test
    func `Completion banner is bold and green when colors are enabled`() {
        let output = ConsoleOutputBuffer()
        let console = Console(
            colorsEnabled: true,
            writeOutput: output.append
        )

        console.completion("Installation completed.")

        #expect(output.text.contains("\u{001B}[1m\u{001B}[32m"))
        #expect(output.text.contains("✓ Installation completed."))
        #expect(output.text.hasPrefix("\n"))
        #expect(output.text.hasSuffix("\n\n"))
    }

    @Test
    func `Installation next steps explain the remaining administrator configuration`() {
        let output = ConsoleOutputBuffer()
        let console = Console(
            colorsEnabled: false,
            writeOutput: output.append
        )

        console.installationNextSteps()

        #expect(output.text.contains("Next steps"))
        #expect(output.text.contains("still needs to be configured"))
        #expect(output.text.contains("administrator account"))
        #expect(output.text.contains("Settings"))
        #expect(output.text.contains("email delivery"))
        #expect(output.text.contains("optional AI support"))
        #expect(output.text.contains("Web Push"))
        #expect(output.text.contains("Thank you for choosing Vernissage"))
        #expect(output.text.hasSuffix("\n\n"))
    }
}

private final class ConsoleOutputBuffer {
    private(set) var text = ""

    func append(_ value: String) {
        text += value
    }
}
