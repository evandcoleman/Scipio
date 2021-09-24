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

        @OptionGroup var options: Run.Options
        @OptionGroup var uploadOptions: Options

        func run() throws {
            log.useColors = !options.noColors
            log.level = options.logLevel

            if let path = options.config {
                Config.setPath(Path(path), buildDirectory: options.buildPath)
            } else {
                Config.readConfig()
            }

            let processorOptions = ProcessorOptions(
                platforms: Config.current.platforms,
                force: options.force || uploadOptions.forceUpload,
                skipClean: options.skipClean
            )

            var artifacts: [AnyArtifact] = []

            if let packages = Config.current.packages, !packages.isEmpty {
                let processor = PackageProcessor(dependencies: packages, options: processorOptions)
                let filtered = options.packages?
                    .compactMap { name in packages.first { $0.name == name } }
                artifacts <<< try processor.existingArtifacts(dependencies: filtered).wait()
            }

            if let binaries = Config.current.binaries, !binaries.isEmpty {
                let processor = BinaryProcessor(dependencies: binaries, options: processorOptions)
                let filtered = options.packages?
                    .compactMap { name in binaries.first { $0.name == name } }
                artifacts <<< try processor.existingArtifacts(dependencies: filtered).wait()
            }

            if let pods = Config.current.pods, !pods.isEmpty {
                let processor = CocoaPodProcessor(dependencies: pods, options: processorOptions)
                let filtered = options.packages?
                    .compactMap { name in pods.first { $0.name == name } }
                artifacts <<< try processor.existingArtifacts(dependencies: filtered).wait()
            }

            let cachedArtifacts = try Runner.upload(
                artifacts: artifacts,
                force: options.force || uploadOptions.forceUpload,
                skipClean: options.skipClean
            )

            try Runner.updatePackageManifest(
                at: Config.current.packageRoot,
                with: cachedArtifacts,
                removeMissing: options.packages?.isEmpty != false
            )

            log.success("✅  Done!")
        }
    }
}

extension Command.Upload {
    struct Options: ParsableArguments {
        @Flag(help: "If true will force uploading dependencies")
        var forceUpload: Bool = false
    }
}
