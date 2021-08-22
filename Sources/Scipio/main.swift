import ArgumentParser
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
        let build = Build(options: _options, buildOptions: _buildOptions)
        let upload = Upload(options: _options, uploadOptions: _uploadOptions)

        try build.run()
        try upload.run()
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

        @Option(help: "Path to the Xcode project containing package dependencies")
        var project: String?
        
        @Argument(help: "An array of packages or products to build", transform: { $0.components(separatedBy: ",") })
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
