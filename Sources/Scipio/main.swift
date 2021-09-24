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
        version: "0.2.2",
        subcommands: [
            Command.Build.self,
            Command.Upload.self,
        ],
        defaultSubcommand: Command.Run.self
      )
    }
  }
}

Command.Main.main()
