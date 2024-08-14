import ArgumentParser
import PathKit
import ScipioKit

struct BuildCommand: AsyncParsableCommand {
    
    static var configuration: CommandConfiguration {
        .init(
            commandName: "build",
            abstract: "Builds some or all packages"
        )
    }

    @OptionGroup var options: RunCommand.Options
    @OptionGroup var buildOptions: Options

    func run() async throws {
        log.useColors = !options.noColors
        log.level = options.logLevel

        if let path = options.config {
            Config.setPath(Path(path), buildDirectory: options.buildPath)
        } else {
            Config.readConfig()
        }

        _ = try await Runner.build(
            dependencies: options.packages,
            platforms: Config.current.platforms,
            force: options.force || buildOptions.forceBuild,
            skipClean: options.skipClean
        )

        log.success("✅  Done!")
    }
}

extension BuildCommand {

    struct Options: ParsableArguments {
        @Flag(help: "If true will force building dependencies")
        var forceBuild: Bool = false
    }
}
