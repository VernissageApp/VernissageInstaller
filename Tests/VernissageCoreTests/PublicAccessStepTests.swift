import Testing
@testable import VernissageCore

@Suite(.tags(.https))
struct PublicAccessStepTests {
    @Test
    func `Development HTTPS is stored in context`() throws {
        let context = InstallationContext(instanceIdentifier: "abcdefgh")
        let output = PublicAccessOutputBuffer()
        let step = makeStep(input: ["1"], output: output)

        try step.run(context: context)

        #expect(context.publicAccess == PublicAccessConfiguration(httpsMode: .development))
        #expect(output.text.contains(InstallationStepGuidance.publicAccess))
        #expect(output.text.contains("internal certificate authority"))
    }

    @Test
    func `Production HTTPS is the default option`() throws {
        let context = InstallationContext(instanceIdentifier: "abcdefgh")
        let step = makeStep(input: [""], output: PublicAccessOutputBuffer())

        try step.run(context: context)

        #expect(context.publicAccess == PublicAccessConfiguration(httpsMode: .production))
    }

    @Test
    func `Manually managed HTTPS is stored in context`() throws {
        let context = InstallationContext(instanceIdentifier: "abcdefgh")
        let step = makeStep(input: ["3"], output: PublicAccessOutputBuffer())

        try step.run(context: context)

        #expect(context.publicAccess == PublicAccessConfiguration(httpsMode: .manual))
    }

    @Test
    func `Invalid HTTPS option is requested again`() throws {
        let context = InstallationContext(instanceIdentifier: "abcdefgh")
        let output = PublicAccessOutputBuffer()
        let step = makeStep(input: ["invalid", "dev"], output: output)

        try step.run(context: context)

        #expect(context.publicAccess?.httpsMode == .development)
        #expect(output.text.contains("Choose 1 for Development HTTPS"))
    }

    @Test
    func `Ended input leaves public access unconfigured`() {
        let context = InstallationContext(instanceIdentifier: "abcdefgh")
        let step = makeStep(input: [], output: PublicAccessOutputBuffer())

        let error = #expect(throws: PublicAccessStepError.self) {
            try step.run(context: context)
        }

        #expect(error == .inputEnded)
        #expect(context.publicAccess == nil)
    }

    private func makeStep(
        input: [String],
        output: PublicAccessOutputBuffer
    ) -> PublicAccessStep {
        let queue = PublicAccessInputQueue(input)
        return PublicAccessStep(
            console: Console(
                colorsEnabled: false,
                readInput: queue.next,
                writeOutput: output.append
            )
        )
    }
}

private final class PublicAccessInputQueue {
    private var values: [String]

    init(_ values: [String]) {
        self.values = values
    }

    func next() -> String? {
        guard values.isEmpty == false else { return nil }
        return values.removeFirst()
    }
}

private final class PublicAccessOutputBuffer {
    private(set) var text = ""

    func append(_ value: String) {
        text += value
    }
}
