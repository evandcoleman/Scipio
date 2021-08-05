import ArgumentParser

enum Command {}

extension Command {
  struct Main: ParsableCommand {
    static var configuration: CommandConfiguration {
      .init(
        commandName: "Scipio",
        abstract: "A program to pre-build and cache Swift packages",
        version: "0.1.0",
        subcommands: []
      )
    }
  }
}

Command.Main.main()
