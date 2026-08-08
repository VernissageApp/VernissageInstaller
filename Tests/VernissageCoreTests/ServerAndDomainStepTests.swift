import Testing
@testable import VernissageCore

@Suite(.tags(.networking))
struct ServerAndDomainStepTests {
    @Test
    func `Domain is stored in shared context`() throws {
        let regularInput = InputQueue([
            "Social.Example.com."
        ])
        let output = OutputBuffer()
        let context = InstallationContext(instanceIdentifier: "abcdefgh")
        let serverStep = makeServerStep(
            regularInput: regularInput,
            output: output
        )

        try serverStep.run(
            context: context,
            providedDomain: nil
        )

        #expect(context.server == ServerConfiguration(domain: "social.example.com"))
        #expect(output.text.contains(InstallationStepGuidance.serverAndDomain))
    }

    @Test
    func `Diagnostic failures do not stop step`() throws {
        let regularInput = InputQueue([])
        let output = OutputBuffer()
        let context = InstallationContext(instanceIdentifier: "abcdefgh")
        let step = makeServerStep(
            regularInput: regularInput,
            output: output
        )

        try step.run(
            context: context,
            providedDomain: "social.example.com"
        )

        #expect(context.server != nil)
        #expect(output.text.contains("This does not stop the installer"))
    }

    @Test
    func `Invalid provided domain stops step`() {
        let step = makeServerStep(
            regularInput: InputQueue([]),
            output: OutputBuffer()
        )

        #expect(throws: ConfigurationValidationError.self) {
            try step.run(
                context: InstallationContext(instanceIdentifier: "abcdefgh"),
                providedDomain: "localhost"
            )
        }
    }

    private func makeServerStep(
        regularInput: InputQueue,
        output: OutputBuffer
    ) -> ServerAndDomainStep {
        ServerAndDomainStep(
            console: Console(
                colorsEnabled: false,
                readInput: regularInput.next,
                writeOutput: output.append
            ),
            dnsResolver: FailingDNSResolver(),
            localAddressProvider: EmptyLocalAddressProvider(),
            portChecker: UnavailablePortChecker()
        )
    }
}

private final class InputQueue {
    private var values: [String]

    init(_ values: [String]) {
        self.values = values
    }

    func next() -> String? {
        guard !values.isEmpty else { return nil }
        return values.removeFirst()
    }
}

private final class OutputBuffer {
    private(set) var text = ""

    func append(_ value: String) {
        text += value
    }
}

private struct FailingDNSResolver: DNSResolving {
    func resolve(domain: String) -> [DNSLookup] {
        [
            DNSLookup(family: .ipv4, addresses: [], error: "test failure"),
            DNSLookup(family: .ipv6, addresses: [], error: "test failure")
        ]
    }
}

private struct EmptyLocalAddressProvider: LocalAddressProviding {
    func addresses() -> Set<String> { [] }
}

private struct UnavailablePortChecker: PortAvailabilityChecking {
    func check(port: UInt16) -> PortAvailability {
        PortAvailability(
            port: port,
            ipv4: .unavailable(errorCode: 98),
            ipv6: .unavailable(errorCode: 98)
        )
    }
}
