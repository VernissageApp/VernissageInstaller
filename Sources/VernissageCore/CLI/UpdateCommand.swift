import ArgumentParser

public struct UpdateCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Replace an installer-managed container with its prepared image."
    )

    @OptionGroup
    var configurationOptions: ConfigurationOptions

    @Argument(help: "Component to update: server, web, push, proxy, caddy, redis, postgres, or minio.")
    var component: UpdateComponent

    @Flag(name: .long, help: "Disable ANSI colors in terminal output.")
    var noColor = false

    public init() {}

    public mutating func run() throws {
        let console = Console.live(colorsEnabled: noColor == false)

        do {
            let context = try configurationOptions.loadContext()
            let plan = try ContainerUpdatePlanFactory(
                operatingSystem: .current
            ).plan(for: component, context: context)

            console.pending("Preparing the \(component.rawValue) image…")
            let result = try ContainerUpdateExecutor(
                commandRunner: ProcessCommandRunner()
            ).execute(plan)

            console.section("Vernissage container update")
            if result.updatedServices.isEmpty {
                console.success(
                    "\(result.currentServices.joined(separator: " and ")) already uses the prepared image."
                )
            } else {
                for service in result.updatedServices {
                    console.success("Updated \(service).")
                }
                for service in result.currentServices {
                    console.info("\(service) already used the prepared image.")
                }
                console.value(label: "Image", value: result.image)
                console.warning(
                    "No automatic database, object-storage, or volume backup was created."
                )
            }
        } catch {
            throw ValidationError(error.localizedDescription)
        }
    }
}
