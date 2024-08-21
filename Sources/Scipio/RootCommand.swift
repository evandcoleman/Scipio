import ArgumentParser
import PathKit
import ScipioKit

@main
struct RootCommand: AsyncParsableCommand {
    
    static var configuration: CommandConfiguration {
        .init(
            commandName: "Scipio",
            abstract: "A program to pre-build and cache Swift packages",
            version: "0.4.0",
            subcommands: [
                InitCommand.self,
                RunCommand.self,
                BuildCommand.self,
                UploadCommand.self,
            ],
            defaultSubcommand: RunCommand.self
        )
    }
}
