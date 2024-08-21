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

        if let xcodegenConfig = initOptions.xcodegenConfig {
            try createConfigFromXcodeGen(path: Path(xcodegenConfig))
        } else {
            try createBlankConfig()
        }

        log.success("✅  Done!")
    }

    private func createConfigFromXcodeGen(path: Path) throws {
        let config = try Config(
            name: initOptions.name,
            xcodegenConfig: path
        )
        try config.write()
    }

    private func createBlankConfig() throws {
        let config = Config(
            name: initOptions.name,
            cache: LocalCacheEngine(
                path: .current
            ),
            deploymentTarget: [
                "iOS": "16.0",
            ]
        )
        
        try config.write()
    }
}

extension InitCommand {

    struct Options: ParsableArguments {
        @Option(help: "Name of dependencies package (defaults to 'Dependencies')")
        var name: String = "Dependencies"

        @Option(help: "Path to an XcodeGen config file")
        var xcodegenConfig: String?
    }
}

