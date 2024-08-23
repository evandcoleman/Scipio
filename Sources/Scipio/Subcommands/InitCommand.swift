//
//  InitCommand.swift
//
//
//  Created by Evan Coleman on 8/21/24.
//

import ArgumentParser
import PathKit
import ScipioKit

struct InitCommand: AsyncParsableCommand {

    static var configuration: CommandConfiguration {
        .init(
            commandName: "init",
            abstract: "Initializes a Scipio configuration file"
        )
    }

    @OptionGroup var options: RunCommand.Options
    @OptionGroup var initOptions: Options

    func run() async throws {
        log.useColors = !options.noColors
        log.level = options.logLevel

        let path =
            if let project = initOptions.projectPath {
                try createConfigFromProject(path: project)
            } else {
                try createBlankConfig()
            }

        log.success("✅  Done! Config written to \(path.string)")
    }

    private func createConfigFromProject(path: Path) throws -> Path {
        let config = try Config(
            name: initOptions.name,
            projectPath: path, 
            cache: LocalCacheEngine(
                path: initOptions.outputDirectory + initOptions.name,
                relativeTo: initOptions.outputDirectory
            )
        )

        return try config.write(to: initOptions.outputPath)
    }

    private func createBlankConfig() throws -> Path {
        let config = Config(
            name: initOptions.name,
            cache: LocalCacheEngine(
                path: initOptions.outputDirectory + initOptions.name,
                relativeTo: initOptions.outputDirectory
            ),
            deploymentTarget: [
                "iOS": "16.0",
            ]
        )
        
        return try config.write(to: initOptions.outputPath)
    }
}

extension InitCommand {

    struct Options: ParsableArguments {
        @Option(help: "Name of dependencies package (defaults to 'Dependencies')")
        var name: String = "Dependencies"

        @Option(help: "Path to an Xcode project file to read packages from")
        var project: String?

        @Option(help: "Path to write Scipio config file to")
        var output: String?

        fileprivate var projectPath: Path? {
            if let project {
                return Path(project)
            } else if let path = Path.current.glob("*.xcodeproj").first {
                return path
            } else {
                return nil
            }
        }

        fileprivate var outputPath: Path {
            return outputDirectory + "scipio.yml"
        }

        fileprivate var outputDirectory: Path {
            if let output {
                return Path(output)
            } else if let projectPath {
                return projectPath.parent()
            } else {
                return .current
            }
        }
    }
}

