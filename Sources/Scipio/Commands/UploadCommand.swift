import ArgumentParser
import PathKit
import ScipioKit

extension Command {
    struct Upload: ParsableCommand {
        static var configuration: CommandConfiguration {
            .init(
                commandName: "upload",
                abstract: "Uploads some or all packages"
            )
        }

        @OptionGroup var options: Main.Options
        @OptionGroup var uploadOptions: Options

        func run() throws {
            log.useColors = !options.noColors
            log.level = options.logLevel

            if let path = options.config {
                Config.setPath(Path(path), buildDirectory: options.buildPath)
            } else {
                Config.readConfig()
            }

            log.fatal("Not yet implemented")
        }
    }
}

extension Command.Upload {
    struct Options: ParsableArguments {
        @Flag(help: "If true will force uploading dependencies")
        var forceUpload: Bool = false
    }
}
