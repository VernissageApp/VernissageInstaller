import Testing
@testable import VernissageCore

@Suite(.tags(.system))
struct CommandRunnerTests {
    @Test
    func `Command runner passes environment and standard input`() throws {
        let runner = ProcessCommandRunner()

        let result = try runner.run(
            "sh",
            arguments: [
                "-c",
                "IFS= read -r input; printf '%s:%s' \"$VERNISSAGE_TEST_VALUE\" \"$input\""
            ],
            environment: ["VERNISSAGE_TEST_VALUE": "environment"],
            standardInput: "standard-input\n"
        )

        #expect(result.exitCode == 0)
        #expect(result.standardOutput == "environment:standard-input")
        #expect(result.standardError.isEmpty)
    }
}
