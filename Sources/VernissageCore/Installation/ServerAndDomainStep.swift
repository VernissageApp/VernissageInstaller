import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

struct ServerAndDomainStep {
    private let console: Console
    private let dnsResolver: any DNSResolving
    private let localAddressProvider: any LocalAddressProviding
    private let portChecker: any PortAvailabilityChecking

    init(
        console: Console,
        dnsResolver: any DNSResolving,
        localAddressProvider: any LocalAddressProviding,
        portChecker: any PortAvailabilityChecking
    ) {
        self.console = console
        self.dnsResolver = dnsResolver
        self.localAddressProvider = localAddressProvider
        self.portChecker = portChecker
    }

    static func live(colorsEnabled: Bool) -> ServerAndDomainStep {
        ServerAndDomainStep(
            console: .live(colorsEnabled: colorsEnabled),
            dnsResolver: SystemDNSResolver(),
            localAddressProvider: SystemLocalAddressProvider(),
            portChecker: SystemPortAvailabilityChecker()
        )
    }

    func run(
        context: InstallationContext,
        providedDomain: String?
    ) throws {
        console.section("Server and domain")
        console.guidance(InstallationStepGuidance.serverAndDomain)

        let domain = try requiredValue(
            provided: providedDomain,
            field: "domain",
            question: "Instance domain (for example social.example.com):",
            validator: DomainValidator.validate
        )

        context.server = ServerConfiguration(domain: domain)
        console.success("Instance domain: \(domain)")

        runDNSChecks(domain: domain)
        runPortChecks()
    }

    private func runDNSChecks(domain: String) {
        console.info("Checking DNS A and AAAA records…")

        let lookups = dnsResolver.resolve(domain: domain)
        var resolvedAddresses = Set<String>()

        for lookup in lookups {
            resolvedAddresses.formUnion(lookup.addresses)

            if !lookup.addresses.isEmpty {
                console.success("DNS \(lookup.family.rawValue): \(lookup.addresses.joined(separator: ", "))")
            } else if let error = lookup.error {
                console.warning("DNS \(lookup.family.rawValue): \(error)")
            } else {
                console.warning("DNS \(lookup.family.rawValue): no record found.")
            }
        }

        guard !resolvedAddresses.isEmpty else {
            console.warning("The domain does not currently resolve. You can continue and configure DNS before exposing Vernissage publicly.")
            return
        }

        let localAddresses = localAddressProvider.addresses()
        guard !localAddresses.isEmpty else {
            console.info("Local interface addresses could not be determined, so the DNS target comparison was skipped.")
            return
        }

        if !resolvedAddresses.isDisjoint(with: localAddresses) {
            console.success("At least one DNS record points to a local network interface.")
        } else {
            console.info(
                "DNS does not point directly to a local interface. This is expected when the server is behind NAT, a load balancer, or a CDN."
            )
        }
    }

    private func runPortChecks() {
        console.info("Checking whether this process can bind locally to ports 80 and 443…")

        for port in [UInt16(80), UInt16(443)] {
            let availability = portChecker.check(port: port)
            report(availability.ipv4, port: port, family: "IPv4")
            report(availability.ipv6, port: port, family: "IPv6")
        }

        console.pending(
            "Public reachability, firewall rules, router forwarding, and TLS will be checked after the proxy is running."
        )
    }

    private func report(_ result: BindResult, port: UInt16, family: String) {
        switch result {
        case .available:
            console.success("Port \(port)/tcp is locally available on \(family).")
        case .unavailable(let errorCode):
            console.warning(
                "Port \(port)/tcp is not locally available on \(family) (\(portFailureDescription(errorCode))). This does not stop the installer."
            )
        }
    }

    private func portFailureDescription(_ errorCode: Int32) -> String {
        switch errorCode {
        case EACCES, EPERM:
            "permission denied"
        case EADDRINUSE:
            "address already in use"
        case EAFNOSUPPORT:
            "address family not supported"
        default:
            "system error \(errorCode)"
        }
    }

    private func requiredValue(
        provided: String?,
        field: String,
        question: String,
        validator: (String) throws -> String
    ) throws -> String {
        if let provided {
            return try validator(provided)
        }

        while true {
            guard let input = console.prompt(question) else {
                throw ConfigurationValidationError.inputEnded(field)
            }

            do {
                return try validator(input)
            } catch {
                console.warning(error.localizedDescription)
            }
        }
    }
}
