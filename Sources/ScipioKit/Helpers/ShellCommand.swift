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
    let outputPipe = Pipe()
    let errorPipe = Pipe()

    private let task = Process()

    func run() {
        task.standardOutput = outputPipe
        task.standardError = errorPipe
        task.arguments = ["-c", command]
        task.launchPath = "/bin/bash"
        task.launch()
    }

    func waitForOutput() throws -> Data {
        try waitUntilExit()

        return outputPipe.fileHandleForReading.readDataToEndOfFile()
    }

    func waitForOutputString() throws -> String {
        return String(data: try waitForOutput(), encoding: .utf8) ?? ""
    }

    @discardableResult
    func onReadLine(pipe: Pipe? = nil, _ handler: @escaping (String) -> Void) -> ShellCommand {
        (pipe ?? outputPipe).fileHandleForReading.readabilityHandler = { handle in
            if let line = String(data: handle.availableData, encoding: .utf8), !line.isEmpty {
                handler(line)
            }
        }
        if pipe == nil {
            errorPipe.fileHandleForReading.readabilityHandler = { handle in
                if let line = String(data: handle.availableData, encoding: .utf8), !line.isEmpty {
                    handler(line)
                }
            }
        }

        return self
    }

    @discardableResult
    func logOutput() -> ShellCommand {
        onReadLine { log.verbose($0) }
    }

    func waitUntilExit() throws {
        task.waitUntilExit()

        if task.terminationStatus > 0 {
            throw ScipioError.commandFailed(command: command, status: Int(task.terminationStatus), output: String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8))
        }
    }
}
