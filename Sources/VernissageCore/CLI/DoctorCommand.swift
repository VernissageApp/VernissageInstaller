import ArgumentParser

public struct DoctorCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Diagnose an installed Vernissage instance."
    )

    @OptionGroup
    var configurationOptions: ConfigurationOptions

    @Flag(
        name: .long,
        help: "Also test temporary PostgreSQL, Redis, and S3 writes plus ActivityPub discovery endpoints."
    )
    var full = false

    @Flag(name: .long, help: "Disable ANSI colors in terminal output.")
    var noColor = false

    public init() {}

    public mutating func run() throws {
        let renderer = DoctorReportRenderer(
            console: .live(colorsEnabled: noColor == false)
        )
        let mode: DoctorMode = full ? .full : .standard
        let context: InstallationContext

        do {
            context = try configurationOptions.loadContext()
        } catch {
            renderer.render(
                DoctorReport(
                    mode: mode,
                    findings: [
                        DoctorFinding(
                            check: "Configuration",
                            status: .failure,
                            message: "vernissage.yml or vernissage.secrets.yml could not be loaded.",
                            details: error.localizedDescription
                        )
                    ]
                )
            )
            throw ExitCode.failure
        }

        let report = DoctorDiagnosticRunner.live().run(
            context: context,
            mode: mode
        )
        renderer.render(report)
        if report.hasFailures {
            throw ExitCode.failure
        }
    }
}
