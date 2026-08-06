import XCTest
@testable import VernissageCore

final class CommandRunnerTests: XCTestCase {
    private let runner = CommandRunner()

    func testNoArgumentsReportsThatInstallerIsReady() {
        let result = runner.run(arguments: [])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.standardOutput.contains("vernissagectl 0.1.0"))
        XCTAssertTrue(result.standardOutput.contains("The Vernissage installer is ready."))
        XCTAssertEqual(result.standardError, "")
    }

    func testVersionOptionPrintsVersion() {
        let result = runner.run(arguments: ["--version"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.standardOutput, "vernissagectl 0.1.0\n")
        XCTAssertEqual(result.standardError, "")
    }

    func testVersionCommandPrintsVersion() {
        let result = runner.run(arguments: ["version"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.standardOutput, "vernissagectl 0.1.0\n")
    }

    func testHelpListsAvailableCommands() {
        let result = runner.run(arguments: ["--help"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.standardOutput.contains("USAGE: vernissagectl <command>"))
        XCTAssertTrue(result.standardOutput.contains("version"))
        XCTAssertTrue(result.standardOutput.contains("help"))
    }

    func testUnknownCommandFailsWithUsageError() {
        let result = runner.run(arguments: ["install"])

        XCTAssertEqual(result.exitCode, 64)
        XCTAssertEqual(result.standardOutput, "")
        XCTAssertTrue(result.standardError.contains("Unknown command: install"))
        XCTAssertTrue(result.standardError.contains("USAGE: vernissagectl <command>"))
    }
}
