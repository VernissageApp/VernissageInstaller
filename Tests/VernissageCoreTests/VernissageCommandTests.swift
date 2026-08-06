import ArgumentParser
import XCTest
@testable import VernissageCore

final class VernissageCommandTests: XCTestCase {
    func testCurrentVersion() {
        XCTAssertEqual(VernissageVersion.current, "0.1.2")
        XCTAssertEqual(VernissageVersion.formatted, "vernissagectl 0.1.2")
    }

    func testRootCommandAcceptsNoArguments() throws {
        _ = try VernissageCommand.parse([])
    }

    func testVersionCommandAcceptsNoArguments() throws {
        _ = try VersionCommand.parse([])
    }

    func testUnknownOptionFailsParsing() {
        XCTAssertThrowsError(
            try VernissageCommand.parse(["--unknown-option"])
        )
    }

    func testVersionOptionExitsSuccessfully() {
        XCTAssertThrowsError(
            try VernissageCommand.parseAsRoot(["--version"])
        ) { error in
            XCTAssertEqual(VernissageCommand.exitCode(for: error), .success)
            XCTAssertEqual(
                VernissageCommand.message(for: error),
                VernissageVersion.formatted
            )
        }
    }
}
