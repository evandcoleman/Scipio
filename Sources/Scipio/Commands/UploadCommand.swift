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

        static var packages: [Package]?

        func run() throws {
            log.useColors = !options.noColors
            log.level = options.logLevel

            if let path = options.config {
                Config.setPath(Path(path), buildDirectory: options.buildPath)
            } else {
                Config.readConfig()
            }

            guard let projectPath = options.project ?? Config.current.directory.glob("*.xcodeproj").first?.string else {
                log.fatal("No project specified and couldn't find one in the current directory.")
            }

            let project = try Project(path: Path(projectPath))

            let packages: [Package]
            if let p = Upload.packages {
                packages = p
            } else {
                log.info("🧮 Loading dependencies...")
                packages = try project.getPackages().wait() ?? []
            }
            let uploadOnlyPackageNames = options.packages ?? packages.map(\.name)
            let parentPackage = try Package(path: Config.current.directory)

            for package in packages where uploadOnlyPackageNames.contains(package.name) {
                try package.upload(parent: parentPackage, force: options.force).wait()
            }
        }
    }
}

extension Command.Upload {
    struct Options: ParsableArguments {
        @Flag(help: "If true will force uploading dependencies")
        var forceUpload: Bool = false
    }
}
