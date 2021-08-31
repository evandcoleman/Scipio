import Foundation
import PathKit

func sh(_ command: String, _ arguments: String..., asAdministrator: Bool = false) -> ShellCommand {
    ShellCommand.sh(command: command, arguments: arguments, asAdministrator: asAdministrator)
}

func sh(_ command: String, _ arguments: [String], asAdministrator: Bool = false) -> ShellCommand {
    ShellCommand.sh(command: command, arguments: arguments, asAdministrator: asAdministrator)
}

struct ShellCommand {

    static func sh(command: String, arguments: [String], asAdministrator: Bool) -> ShellCommand {
        let shell = ShellCommand(command: command, arguments: arguments)
        shell.run(asAdministrator: asAdministrator)
        return shell
    }

    let command: String
    let arguments: [String]

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    let inputPipe = Pipe()

    private let task = Process()

    func run(asAdministrator: Bool = false) {
        task.standardOutput = outputPipe
        task.standardError = errorPipe
        if asAdministrator {
            var buf = [CChar](repeating: 0, count: 8192)
            if let passphrase = readpassphrase("Password:", &buf, buf.count, 0),
                let passphraseStr = String(validatingUTF8: passphrase),
                let data = "\(passphraseStr)\n".data(using: .utf8) {

                task.arguments = ["-S"] + [command] + arguments
                task.launchPath = "/usr/bin/sudo"
                task.standardInput = inputPipe

                task.launch()

                inputPipe.fileHandleForWriting.write(data)
            } else {
                log.fatal("Command failed")
            }
        } else {
            if command.contains("/") {
                task.arguments = arguments
                task.launchPath = command
            } else {
                task.arguments = ["-c", command] + arguments
                task.launchPath = "/bin/bash"
            }

            task.launch()
        }
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
            throw ScipioError.commandFailed(command: ([command] + arguments).joined(separator: " "), status: Int(task.terminationStatus), output: String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8))
        }
    }
}
