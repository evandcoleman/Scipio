import Foundation

func sh(_ command: String) -> ShellCommand {
    ShellCommand.sh(command)
}

struct ShellCommand {

    static func sh(_ command: String) -> ShellCommand {
        let shell = ShellCommand(command: command)
        shell.run()
        return shell
    }

    let command: String
    let pipe = Pipe()

    private let task = Process()

    func run() {
        print(command)
        task.standardOutput = pipe
        task.standardError = pipe
        task.arguments = ["-c", command]
        task.launchPath = "/bin/bash"
        task.launch()
    }

    func waitForOutput() -> Data {
        waitUntilExit()

        return pipe.fileHandleForReading.readDataToEndOfFile()
    }

    func logOutput() -> ShellCommand {
        pipe.fileHandleForReading.readabilityHandler = { handle in
            if let line = String(data: handle.availableData, encoding: .utf8) {
                print(line)
            }
        }

        return self
    }

    func waitUntilExit() {
        task.waitUntilExit()
    }
}
