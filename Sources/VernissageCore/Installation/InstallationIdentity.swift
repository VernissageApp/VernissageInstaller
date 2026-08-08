import Foundation

enum InstallationIdentity {
    static let length = 8
    static let alphabet = Array("abcdefghijklmnopqrstuvwxyz")

    static func generate() -> String {
        var generator = SystemRandomNumberGenerator()
        return generate(using: &generator)
    }

    static func generate<Generator: RandomNumberGenerator>(
        using generator: inout Generator
    ) -> String {
        String(
            (0..<length).map { _ in
                alphabet.randomElement(using: &generator) ?? "a"
            }
        )
    }

    static func isValid(_ value: String) -> Bool {
        value.count == length && value.allSatisfy(alphabet.contains)
    }
}

struct InstallationResourceNames: Equatable {
    let instanceIdentifier: String

    private var prefix: String {
        "vernissage-\(instanceIdentifier)"
    }

    var networkName: String { "\(prefix)-network" }

    var postgresqlContainerName: String { "\(prefix)-postgres" }
    var postgresqlVolumeName: String { "\(prefix)-postgres-data" }

    var redisContainerName: String { "\(prefix)-redis" }
    var redisVolumeName: String { "\(prefix)-redis-data" }

    var minIOContainerName: String { "\(prefix)-minio" }
    var minIOVolumeName: String { "\(prefix)-minio-data" }

    var apiContainerName: String { "\(prefix)-api" }
    var jobsContainerName: String { "\(prefix)-jobs" }
    var webContainerName: String { "\(prefix)-web" }
    var pushContainerName: String { "\(prefix)-push" }
    var proxyContainerName: String { "\(prefix)-proxy" }
    var caddyContainerName: String { "\(prefix)-caddy" }

    var caddyDataVolumeName: String { "\(prefix)-caddy-data" }
    var caddyConfigVolumeName: String { "\(prefix)-caddy-config" }

    var proxyImage: String { "vernissage-proxy:\(instanceIdentifier)" }
}
