import Foundation

enum DoctorMode: Equatable {
    case standard
    case full
}

enum DoctorFindingStatus: String, Equatable {
    case ok
    case warning
    case failure
    case skipped
}

struct DoctorFinding: Equatable {
    let check: String
    let status: DoctorFindingStatus
    let message: String
    let details: String?

    init(
        check: String,
        status: DoctorFindingStatus,
        message: String,
        details: String? = nil
    ) {
        self.check = check
        self.status = status
        self.message = message
        self.details = details
    }

    var renderedMessage: String {
        var value = "\(check): \(message)"
        if let details, details.isEmpty == false {
            value += " Details: \(details)"
        }
        return value
    }
}

struct DoctorReport: Equatable {
    let mode: DoctorMode
    let findings: [DoctorFinding]

    var failureCount: Int {
        findings.count { $0.status == .failure }
    }

    var warningCount: Int {
        findings.count { $0.status == .warning }
    }

    var hasFailures: Bool { failureCount > 0 }
}

struct DoctorReportRenderer {
    private let console: Console

    init(console: Console) {
        self.console = console
    }

    func render(_ report: DoctorReport) {
        console.section("Vernissage doctor")
        console.value(
            label: "Mode",
            value: report.mode == .full ? "full" : "standard"
        )
        console.line("")

        for finding in report.findings {
            switch finding.status {
            case .ok:
                console.diagnosticOK(finding.renderedMessage)
            case .warning:
                console.diagnosticWarning(finding.renderedMessage)
            case .failure:
                console.diagnosticFailure(finding.renderedMessage)
            case .skipped:
                console.diagnosticSkipped(finding.renderedMessage)
            }
        }

        console.line("")
        if report.hasFailures {
            console.diagnosticFailure(
                "Doctor completed with \(report.failureCount) failure(s) and \(report.warningCount) warning(s)."
            )
        } else if report.warningCount > 0 {
            console.diagnosticWarning(
                "Doctor completed without failures and with \(report.warningCount) warning(s)."
            )
        } else {
            console.diagnosticOK("Doctor completed successfully.")
        }
    }
}

struct DoctorFileSystem: Sendable {
    let fileExists: @Sendable (String) -> Bool
    let permissions: @Sendable (String) -> Int?

    static let live = DoctorFileSystem(
        fileExists: { FileManager.default.fileExists(atPath: $0) },
        permissions: { path in
            guard let value = try? FileManager.default.attributesOfItem(
                atPath: path
            )[.posixPermissions] as? NSNumber else {
                return nil
            }
            return value.intValue
        }
    )
}
