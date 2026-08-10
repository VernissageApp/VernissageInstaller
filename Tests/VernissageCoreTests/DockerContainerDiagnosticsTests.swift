import Testing
@testable import VernissageCore

struct DockerContainerDiagnosticsTests {
    @Test
    func `Startup diagnostics include the reported failure and executable log commands`() {
        let details = DockerContainerDiagnostics.startupFailureDetails(
            "connection refused\n",
            containerName: "vernissage-abcdefgh-api"
        )

        #expect(
            details == """
            connection refused
            Inspect the container logs with:
              docker logs --tail 200 vernissage-abcdefgh-api
            If Docker requires elevated permissions:
              sudo docker logs --tail 200 vernissage-abcdefgh-api
            """
        )
    }

    @Test
    func `Startup diagnostics remain actionable without a reported failure`() {
        let details = DockerContainerDiagnostics.startupFailureDetails(
            nil,
            containerName: "vernissage-abcdefgh-postgres"
        )

        #expect(
            details == """
            Inspect the container logs with:
              docker logs --tail 200 vernissage-abcdefgh-postgres
            If Docker requires elevated permissions:
              sudo docker logs --tail 200 vernissage-abcdefgh-postgres
            """
        )
    }
}
