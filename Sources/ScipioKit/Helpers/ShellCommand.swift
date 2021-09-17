import Foundation
import PathKit

@discardableResult
func sh(_ command: Path, _ arguments: String..., in path: Path? = nil, asAdministrator: Bool = false, passEnvironment: Bool = false, lineReader: ((String) -> Void)? = nil) throws -> ShellCommand {
    try ShellCommand.sh(command: command.string, arguments: arguments, in: path, asAdministrator: asAdministrator, passEnvironment: passEnvironment, lineReader: lineReader)
}

@discardableResult
func sh(_ command: Path, _ arguments: [String], in path: Path? = nil, asAdministrator: Bool = false, passEnvironment: Bool = false, lineReader: ((String) -> Void)? = nil) throws -> ShellCommand {
    try ShellCommand.sh(command: command.string, arguments: arguments, in: path, asAdministrator: asAdministrator, passEnvironment: passEnvironment, lineReader: lineReader)
}

@discardableResult
func sh(_ command: String, _ arguments: String..., in path: Path? = nil, asAdministrator: Bool = false, passEnvironment: Bool = false, lineReader: ((String) -> Void)? = nil) throws -> ShellCommand {
    try ShellCommand.sh(command: command, arguments: arguments, in: path, asAdministrator: asAdministrator, passEnvironment: passEnvironment, lineReader: lineReader)
}

@discardableResult
func sh(_ command: String, _ arguments: [String], in path: Path? = nil, asAdministrator: Bool = false, passEnvironment: Bool = false, lineReader: ((String) -> Void)? = nil) throws -> ShellCommand {
    try ShellCommand.sh(command: command, arguments: arguments, in: path, asAdministrator: asAdministrator, passEnvironment: passEnvironment, lineReader: lineReader)
}

@discardableResult
func which(_ command: String) throws -> Path {
    do {
        let output = try sh("/usr/bin/which", command, passEnvironment: true)
            .outputString()
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

final class ShellCommand {

    @discardableResult
    static func sh(command: String, arguments: [String], in path: Path? = nil, asAdministrator: Bool = false, passEnvironment: Bool = false, lineReader: ((String) -> Void)? = nil) throws -> ShellCommand {
        let shell = ShellCommand(command: command, arguments: arguments)
        try shell.run(in: path, asAdministrator: asAdministrator, passEnvironment: passEnvironment, lineReader: lineReader)
        return shell
    }

    let command: String
    let arguments: [String]

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    let inputPipe = Pipe()

    private let task = Process()
    private var outputString: String?
    private var outputQueue = DispatchQueue(label: "outputQueue")

    init(command: String, arguments: [String]) {
        self.command = command
        self.arguments = arguments
    }

    func run(in path: Path? = nil, asAdministrator: Bool = false, passEnvironment: Bool = false, lineReader: ((String) -> Void)? = nil) throws {
        task.standardOutput = outputPipe
        task.standardError = errorPipe
        logOutput()
        if let lineReader = lineReader {
            onReadLine(lineReader)
        }

        if passEnvironment {
            task.environment = ProcessInfo.processInfo.environment
        }

        do {
            if asAdministrator {
                let launch: () throws -> Void = {
                    if let path = path {
                        self.task.currentDirectoryURL = path.url
                    }

                    self.task.arguments = ["-S"] + [self.command] + self.arguments
                    self.task.launchPath = "/usr/bin/sudo"
                    self.task.standardInput = self.inputPipe

                    log.verbose(self.task.launchPath ?? "", self.task.arguments?.joined(separator: " ") ?? "")

                    try self.task.run()
                }
                do {
                    try ShellCommand.sh(command: "/usr/bin/sudo", arguments: ["-n", "true"])
                    try launch()
                } catch ScipioError.commandFailed {
                    var buf = [CChar](repeating: 0, count: 8192)
                    if let passphrase = readpassphrase("Password:", &buf, buf.count, 0),
                        let passphraseStr = String(validatingUTF8: passphrase),
                        let data = "\(passphraseStr)\n".data(using: .utf8) {

                        try launch()

                        inputPipe.fileHandleForWriting.write(data)
                    } else {
                        log.fatal("Command failed")
                    }
                }
            } else {
                if let path = path {
                    task.currentDirectoryURL = path.url
                }

                if command.contains("/") {
                    task.arguments = arguments
                    task.launchPath = command
                } else {
                    task.launchPath = "/bin/bash"
                    task.arguments = ["-c", command] + arguments
                }

                log.verbose(task.launchPath ?? "", task.arguments?.joined(separator: " ") ?? "")

                try task.run()
            }
        } catch {
            let outputHandle = outputPipe.fileHandleForReading
            let errorHandle = errorPipe.fileHandleForReading

            throw ScipioError.commandFailed(
                command: ([command] + arguments).joined(separator: " "),
                status: Int(task.terminationStatus),
                output: outputString ?? String(
                    data: outputHandle.readDataToEndOfFile(),
                    encoding: .utf8
                ),
                error: String(
                    data: errorHandle.readDataToEndOfFile(),
                    encoding: .utf8
                )
            )
        }
    }

    func output(stdout: Bool = true, stderr: Bool = false) throws -> Data {
        let out = stdout ? outputPipe.fileHandleForReading.readDataToEndOfFile() : Data()
        let err = stderr ? errorPipe.fileHandleForReading.readDataToEndOfFile() : Data()

        return out + err
    }

    func outputString(stdout: Bool = true, stderr: Bool = false) throws -> String {
        return String(data: try output(stdout: stdout, stderr: stderr), encoding: .utf8) ?? ""
    }

    @discardableResult
    private func onReadLine(pipe: Pipe? = nil, _ handler: @escaping (String) -> Void) -> ShellCommand {
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
    private func logOutput() -> ShellCommand {
        outputQueue.async {
            self.outputString = ""
        }
        
        return onReadLine { [weak self] line in
            self?.outputQueue.async {
                self?.outputString?.append(line)
            }
            log.verbose(line)
        }
    }
}
