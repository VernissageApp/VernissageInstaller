import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

enum IPAddressFamily: String, CaseIterable, Sendable {
    case ipv4 = "A"
    case ipv6 = "AAAA"

    var systemFamily: Int32 {
        switch self {
        case .ipv4: AF_INET
        case .ipv6: AF_INET6
        }
    }

    func accepts(numericAddress: String) -> Bool {
        self != .ipv6
            || numericAddress.lowercased().hasPrefix("::ffff:") == false
    }
}

struct DNSLookup: Equatable, Sendable {
    let family: IPAddressFamily
    let addresses: [String]
    let error: String?
}

protocol DNSResolving {
    func resolve(domain: String) -> [DNSLookup]
}

struct SystemDNSResolver: DNSResolving {
    func resolve(domain: String) -> [DNSLookup] {
        IPAddressFamily.allCases.map { family in
            resolve(domain: domain, family: family)
        }
    }

    private func resolve(domain: String, family: IPAddressFamily) -> DNSLookup {
        var hints = addrinfo()
        hints.ai_family = family.systemFamily
        hints.ai_socktype = streamSocketType

        var result: UnsafeMutablePointer<addrinfo>?
        let returnCode = getaddrinfo(domain, nil, &hints, &result)

        guard returnCode == 0 else {
            return DNSLookup(
                family: family,
                addresses: [],
                error: DNSFailureFormatter.message(for: returnCode)
            )
        }

        defer { freeaddrinfo(result) }

        var addresses = Set<String>()
        var current = result

        while let entry = current {
            if let address = entry.pointee.ai_addr,
               let formatted = NumericAddressFormatter.string(
                   address: address,
                   length: entry.pointee.ai_addrlen
               ) {
                if family.accepts(numericAddress: formatted) {
                    addresses.insert(formatted)
                }
            }

            current = entry.pointee.ai_next
        }

        return DNSLookup(
            family: family,
            addresses: addresses.sorted(),
            error: nil
        )
    }
}

protocol LocalAddressProviding {
    func addresses() -> Set<String>
}

struct SystemLocalAddressProvider: LocalAddressProviding {
    func addresses() -> Set<String> {
        var firstInterface: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstInterface) == 0 else {
            return []
        }

        defer { freeifaddrs(firstInterface) }

        var result = Set<String>()
        var current = firstInterface

        while let interface = current {
            defer { current = interface.pointee.ifa_next }

            guard let address = interface.pointee.ifa_addr else {
                continue
            }

            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else {
                continue
            }

            let isLoopback = interface.pointee.ifa_flags & UInt32(IFF_LOOPBACK) != 0
            guard !isLoopback else {
                continue
            }

            let length: socklen_t = family == AF_INET
                ? socklen_t(MemoryLayout<sockaddr_in>.size)
                : socklen_t(MemoryLayout<sockaddr_in6>.size)

            if let formatted = NumericAddressFormatter.string(address: address, length: length) {
                result.insert(formatted)
            }
        }

        return result
    }
}

struct PortAvailability: Equatable, Sendable {
    let port: UInt16
    let ipv4: BindResult
    let ipv6: BindResult
}

enum BindResult: Equatable, Sendable {
    case available
    case unavailable(errorCode: Int32)
}

protocol PortAvailabilityChecking {
    func check(port: UInt16) -> PortAvailability
}

struct SystemPortAvailabilityChecker: PortAvailabilityChecking {
    func check(port: UInt16) -> PortAvailability {
        PortAvailability(
            port: port,
            ipv4: bindIPv4(port: port),
            ipv6: bindIPv6(port: port)
        )
    }

    private func bindIPv4(port: UInt16) -> BindResult {
        let descriptor = socket(AF_INET, streamSocketType, 0)
        guard descriptor >= 0 else {
            return .unavailable(errorCode: errno)
        }
        defer { close(descriptor) }

        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_ANY)

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                bind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        return result == 0 ? .available : .unavailable(errorCode: errno)
    }

    private func bindIPv6(port: UInt16) -> BindResult {
        let descriptor = socket(AF_INET6, streamSocketType, 0)
        guard descriptor >= 0 else {
            return .unavailable(errorCode: errno)
        }
        defer { close(descriptor) }

        var address = sockaddr_in6()
        #if canImport(Darwin)
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        #endif
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = port.bigEndian
        address.sin6_addr = in6_addr()

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                bind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }

        return result == 0 ? .available : .unavailable(errorCode: errno)
    }
}

private enum NumericAddressFormatter {
    static func string(
        address: UnsafePointer<sockaddr>,
        length: socklen_t
    ) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let returnCode = getnameinfo(
            address,
            length,
            &host,
            socklen_t(host.count),
            nil,
            0,
            NI_NUMERICHOST
        )

        guard returnCode == 0 else {
            return nil
        }

        let bytes = host.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

private enum DNSFailureFormatter {
    static func message(for errorCode: Int32) -> String {
        switch errorCode {
        case EAI_AGAIN:
            "The DNS server returned a temporary failure."
        case EAI_NONAME:
            "The domain has no record for this address family."
        case EAI_FAIL:
            "The DNS server returned a permanent failure."
        case EAI_SYSTEM:
            "The DNS lookup failed with a system error."
        default:
            "DNS lookup failed (code \(errorCode))."
        }
    }
}

private var streamSocketType: Int32 {
    #if canImport(Musl)
    SOCK_STREAM
    #elseif os(Linux)
    Int32(SOCK_STREAM.rawValue)
    #else
    SOCK_STREAM
    #endif
}
