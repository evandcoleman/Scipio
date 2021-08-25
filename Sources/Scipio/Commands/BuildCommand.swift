import ArgumentParser
import PathKit
import ScipioKit

extension Command {
    struct Build: ParsableCommand {
        static var configuration: CommandConfiguration {
            .init(
                commandName: "build",
                abstract: "Builds some or all packages"
            )
        }

        @OptionGroup var options: Main.Options
        @OptionGroup var buildOptions: Options

        func run() throws {
            log.useColors = !options.noColors
            log.level = options.logLevel

            if let path = options.config {
                Config.setPath(Path(path), buildDirectory: options.buildPath)
            } else {
                Config.readConfig()
            }

            _ = try Runner.build(
                dependencies: options.packages,
                platforms: buildOptions.platform,
                force: options.force || buildOptions.forceBuild,
                skipClean: options.skipClean
            )
        }
    }
}

extension Command.Build {
    struct Options: ParsableArguments {
        @Option(help: "The platforms to build for", transform: { $0.components(separatedBy: ",").compactMap { Platform(rawValue: $0) } })
        var platform: [Platform]

        @Flag(help: "If true will force building dependencies")
        var forceBuild: Bool = false
    }
}
