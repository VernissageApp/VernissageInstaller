import Foundation

enum PublicAccessStepError: LocalizedError, Equatable {
    case inputEnded

    var errorDescription: String? {
        "An HTTPS option is required."
    }
}

struct PublicAccessStep {
    private let console: Console

    init(console: Console) {
        self.console = console
    }

    static func live(colorsEnabled: Bool) -> PublicAccessStep {
        PublicAccessStep(console: .live(colorsEnabled: colorsEnabled))
    }

    func run(context: InstallationContext, providedMode: HTTPSMode? = nil) throws {
        console.section("HTTPS and public access")
        console.guidance(InstallationStepGuidance.publicAccess)

        let mode = try providedMode ?? readHTTPSMode()
        context.publicAccess = PublicAccessConfiguration(httpsMode: mode)

        switch mode {
        case .development:
            console.success("Development HTTPS will be configured with Caddy's internal certificate authority.")
        case .production:
            console.success("Production HTTPS will be configured with Caddy and Let's Encrypt.")
        case .manual:
            console.success("Certificate and public routing will be managed manually.")
        }
    }

    private func readHTTPSMode() throws -> HTTPSMode {
        console.optionListHeader()
        console.line("  1. Development HTTPS — Caddy with an internal certificate authority")
        console.line("  2. Production HTTPS — Caddy with an automatic Let's Encrypt certificate")
        console.line("  3. None — certificate and routing managed manually")

        while true {
            guard let input = console.prompt("HTTPS option [2]:") else {
                throw PublicAccessStepError.inputEnded
            }

            switch input.lowercased() {
            case "1", "development", "dev", "internal":
                return .development
            case "", "2", "production", "prod", "letsencrypt", "let's encrypt":
                return .production
            case "3", "none", "manual", "external":
                return .manual
            default:
                console.warning("Choose 1 for Development HTTPS, 2 for Production HTTPS, or 3 for manually managed certificates and routing.")
            }
        }
    }
}
