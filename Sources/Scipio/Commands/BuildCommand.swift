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
            }

            guard let projectPath = options.project ?? Config.current.directory.glob("*.xcodeproj").first?.string else {
                log.fatal("No project specified and couldn't find one in the current directory.")
            }

            let project = try Project(path: Path(projectPath))

            if !buildOptions.skipClean {
                try project.cleanBuildDirectory()
            }

            if !buildOptions.skipResolveDependencies {
                log.info("📦 Resolving dependencies...")
                project.resolvePackageDependencies(quiet: options.quiet, colors: !options.noColors)
            }

            log.info("🧮 Loading dependencies...")
            let packages = try project.getPackages().wait() ?? []
            let buildOnlyPackageNames = options.packages ?? packages.map(\.name)
            Upload.packages = packages

            for package in packages where buildOnlyPackageNames.contains(package.name) {
                try project.build(
                    package: package,
                    for: buildOptions.sdks,
                    skipClean: buildOptions.skipClean,
                    quiet: options.quiet,
                    colors: !options.noColors,
                    force: options.force
                ).wait()
            }
        }
    }
}

extension Command.Build {
    struct Options: ParsableArguments {
        @Option(help: "An array of SDKs to build for", transform: { $0.components(separatedBy: ",").compactMap { Xcodebuild.SDK(rawValue: $0) } })
        var sdks: [Xcodebuild.SDK]

        @Flag(help: "If true will skip building dependencies that are already built")
        var skipClean: Bool = false
        @Flag(help: "If true will skip resolving dependencies")
        var skipResolveDependencies: Bool = false
    }
}
