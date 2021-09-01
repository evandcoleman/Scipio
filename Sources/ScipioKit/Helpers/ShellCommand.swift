import Foundation
import PathKit

func sh(_ command: Path, _ arguments: String..., in path: Path? = nil, asAdministrator: Bool = false, passEnvironment: Bool = false) -> ShellCommand {
    ShellCommand.sh(command: command.string, arguments: arguments, in: path, asAdministrator: asAdministrator, passEnvironment: passEnvironment)
}

func sh(_ command: Path, _ arguments: [String], in path: Path? = nil, asAdministrator: Bool = false, passEnvironment: Bool = false) -> ShellCommand {
    ShellCommand.sh(command: command.string, arguments: arguments, in: path, asAdministrator: asAdministrator, passEnvironment: passEnvironment)
}

func sh(_ command: String, _ arguments: String..., in path: Path? = nil, asAdministrator: Bool = false, passEnvironment: Bool = false) -> ShellCommand {
    ShellCommand.sh(command: command, arguments: arguments, in: path, asAdministrator: asAdministrator, passEnvironment: passEnvironment)
}

func sh(_ command: String, _ arguments: [String], in path: Path? = nil, asAdministrator: Bool = false, passEnvironment: Bool = false) -> ShellCommand {
    ShellCommand.sh(command: command, arguments: arguments, in: path, asAdministrator: asAdministrator, passEnvironment: passEnvironment)
}

@discardableResult
func which(_ command: String) throws -> Path {
    do {
        let output = try sh("/usr/bin/which", command, passEnvironment: true)
            .waitForOutputString()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return Path(output)
    } catch {
        throw ShellError.commandNotFound(command)
    }
}

public enum ShellError: LocalizedError {
    case commandNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .commandNotFound(let command):
            return "Command '\(command)' could not be found."
        }
    }
}

struct ShellCommand {

    static func sh(command: String, arguments: [String], in path: Path? = nil, asAdministrator: Bool = false, passEnvironment: Bool = false) -> ShellCommand {
        let shell = ShellCommand(command: command, arguments: arguments)
        shell.run(in: path, asAdministrator: asAdministrator, passEnvironment: passEnvironment)
        return shell
    }

    let command: String
    let arguments: [String]

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    let inputPipe = Pipe()

    private let task = Process()

    func run(in path: Path? = nil, asAdministrator: Bool = false, passEnvironment: Bool = false) {
        task.standardOutput = outputPipe
        task.standardError = errorPipe

        if passEnvironment {
            task.environment = ProcessInfo.processInfo.environment
        }

        if asAdministrator {
            let launch: () -> Void = {
                if let path = path {
                    task.arguments = ["-c", #""cd \#(path.string) && /usr/bin/sudo -S \#(([command] + arguments).joined(separator: " "))""#]
                    task.launchPath = "/bin/bash"
                } else {
                    task.arguments = ["-S"] + [command] + arguments
                    task.launchPath = "/usr/bin/sudo"
                }

                task.standardInput = inputPipe

                log.verbose(task.launchPath ?? "", task.arguments?.joined(separator: " ") ?? "")

                task.launch()
            }
            do {
                try ShellCommand.sh(command: "/usr/bin/sudo", arguments: ["-n", "true"])
                    .waitUntilExit()
                launch()
            } catch {
                var buf = [CChar](repeating: 0, count: 8192)
                if let passphrase = readpassphrase("Password:", &buf, buf.count, 0),
                    let passphraseStr = String(validatingUTF8: passphrase),
                    let data = "\(passphraseStr)\n".data(using: .utf8) {

                    launch()

                    inputPipe.fileHandleForWriting.write(data)
                } else {
                    log.fatal("Command failed")
                }
            }
        } else {
            if command.contains("/"), path == nil {
                task.arguments = arguments
                task.launchPath = command
            } else if let path = path {
                task.arguments = ["-c", #""cd \#(path.string) && \#(([command] + arguments).joined(separator: " "))""#]
                task.launchPath = "/bin/bash"
            } else {
                task.arguments = ["-c", command] + arguments
            }

            log.verbose(task.launchPath ?? "", task.arguments?.joined(separator: " ") ?? "")

            task.launch()
        }
    }

    func waitForOutput(stdout: Bool = true, stderr: Bool = false) throws -> Data {
        try waitUntilExit()

        let out = stdout ? outputPipe.fileHandleForReading.readDataToEndOfFile() : Data()
        let err = stderr ? errorPipe.fileHandleForReading.readDataToEndOfFile() : Data()

        return out + err
    }

    func waitForOutputString(stdout: Bool = true, stderr: Bool = false) throws -> String {
        return String(data: try waitForOutput(stdout: stdout, stderr: stderr), encoding: .utf8) ?? ""
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
