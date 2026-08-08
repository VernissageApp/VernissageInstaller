enum HostOperatingSystem: Equatable {
    case macOS
    case linux

    static var current: HostOperatingSystem {
#if os(macOS)
        .macOS
#elseif os(Linux)
        .linux
#else
#error("Vernissage Installer supports only macOS and Linux.")
#endif
    }
}
