import Testing
@testable import VernissageCore

struct NetworkDiagnosticsTests {
    @Test(
        arguments: [
            (family: IPAddressFamily.ipv4, address: "127.0.0.1", accepted: true),
            (family: IPAddressFamily.ipv6, address: "2001:db8::1", accepted: true),
            (family: IPAddressFamily.ipv6, address: "::ffff:127.0.0.1", accepted: false),
            (family: IPAddressFamily.ipv6, address: "::FFFF:192.0.2.1", accepted: false)
        ]
    )
    func `DNS family excludes mapped IPv4 from AAAA results`(
        family: IPAddressFamily,
        address: String,
        accepted: Bool
    ) {
        #expect(family.accepts(numericAddress: address) == accepted)
    }
}
