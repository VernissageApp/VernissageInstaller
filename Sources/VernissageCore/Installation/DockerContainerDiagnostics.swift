import Foundation

enum DockerContainerDiagnostics {
    static func startupFailureDetails(
        _ details: String?,
        containerName: String
    ) -> String {
        var sections: [String] = []

        if let details = details?.trimmingCharacters(in: .whitespacesAndNewlines),
           details.isEmpty == false {
            sections.append(details)
        }

        sections.append(
            """
            Inspect the container logs with:
              docker logs --tail 200 \(containerName)
            If Docker requires elevated permissions:
              sudo docker logs --tail 200 \(containerName)
            """
        )

        return sections.joined(separator: "\n")
    }
}
