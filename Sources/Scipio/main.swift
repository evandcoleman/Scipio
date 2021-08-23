import ArgumentParser
import PathKit
import ScipioKit

enum Command {}

extension Command {
  struct Main: ParsableCommand {
    static var configuration: CommandConfiguration {
      .init(
        commandName: "Scipio",
        abstract: "A program to pre-build and cache Swift packages",
        version: "0.0.5",
        subcommands: [
            Command.Build.self,
            Command.Upload.self,
        ]
      )
    }

    @OptionGroup var options: Options
    @OptionGroup var buildOptions: Build.Options
    @OptionGroup var uploadOptions: Upload.Options

    func run() throws {
        log.useColors = !options.noColors
        log.level = options.logLevel

        if let path = options.config {
            Config.setPath(Path(path), buildDirectory: options.buildPath)
        } else {
            Config.readConfig()
        }

        let artifacts = try Runner.build(
            dependencies: options.packages,
            platforms: buildOptions.platform,
            force: options.force || buildOptions.forceBuild
        )

        let cachedArtifacts = try Runner.upload(
            artifacts: artifacts,
            force: options.force || uploadOptions.forceUpload
        )

        try Runner.updatePackageManifest(at: Config.current.directory, with: cachedArtifacts)
    }
  }
}

extension Command.Main {
    struct Options: ParsableArguments {
        @Flag(help: "Enable verbose logging.")
        var verbose: Bool = false

        @Flag(help: "Enable quiet logging.")
        var quiet: Bool = false

        @Flag(help: "Disable color output")
        var noColors: Bool = false

        @Option(help: "Path to a config file")
        var config: String?

        @Argument(help: "An array of dependencies to process", transform: { $0.components(separatedBy: ",") })
        var packages: [String]?

        @Option(help: "Path to store and find build artifacts")
        var buildPath: String?

        @Flag(help: "If true will force build and upload packages")
        var force: Bool = false

        var logLevel: Log.Level {
            if verbose {
                return .verbose
            } else if quiet {
                return .error
            } else {
                return .info
            }
        }
    }
}

Command.Main.main()
