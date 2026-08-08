import Testing
@testable import VernissageCore

struct InstallationIdentityTests {
    @Test
    func `Generated installation identifier contains eight lowercase letters`() {
        var generator = PredictableRandomNumberGenerator()

        let identifier = InstallationIdentity.generate(using: &generator)

        #expect(identifier.count == 8)
        #expect(identifier.allSatisfy { $0.isASCII && $0.isLowercase })
        #expect(InstallationIdentity.isValid(identifier))
    }

    @Test(
        arguments: [
            "abcdefg",
            "abcdefghi",
            "abcd1234",
            "ABCDEFGH",
            "abcd-efg",
            "ąbcdefgh"
        ]
    )
    func `Invalid installation identifier is rejected`(_ identifier: String) {
        #expect(InstallationIdentity.isValid(identifier) == false)
    }

    @Test
    func `Installation identifier namespaces every Docker resource`() {
        let names = InstallationResourceNames(instanceIdentifier: "jtivmgre")

        #expect(names.networkName == "vernissage-jtivmgre-network")
        #expect(names.postgresqlContainerName == "vernissage-jtivmgre-postgres")
        #expect(names.postgresqlVolumeName == "vernissage-jtivmgre-postgres-data")
        #expect(names.redisContainerName == "vernissage-jtivmgre-redis")
        #expect(names.redisVolumeName == "vernissage-jtivmgre-redis-data")
        #expect(names.minIOContainerName == "vernissage-jtivmgre-minio")
        #expect(names.minIOVolumeName == "vernissage-jtivmgre-minio-data")
        #expect(names.apiContainerName == "vernissage-jtivmgre-api")
        #expect(names.jobsContainerName == "vernissage-jtivmgre-jobs")
        #expect(names.webContainerName == "vernissage-jtivmgre-web")
        #expect(names.pushContainerName == "vernissage-jtivmgre-push")
        #expect(names.proxyContainerName == "vernissage-jtivmgre-proxy")
        #expect(names.caddyContainerName == "vernissage-jtivmgre-caddy")
        #expect(names.caddyDataVolumeName == "vernissage-jtivmgre-caddy-data")
        #expect(names.caddyConfigVolumeName == "vernissage-jtivmgre-caddy-config")
        #expect(names.proxyImage == "vernissage-proxy:jtivmgre")
    }
}

private struct PredictableRandomNumberGenerator: RandomNumberGenerator {
    private var value: UInt64 = 0

    mutating func next() -> UInt64 {
        defer { value &+= 1 }
        return value
    }
}
