import Foundation
import PathKit

@discardableResult
func sh(_ command: Path, _ arguments: String..., in path: Path? = nil, passEnvironment: Bool = false, file: StaticString = #file, line: UInt = #line, lineReader: ((String) -> Void)? = nil) throws -> ShellCommand {
    try ShellCommand.sh(command: command.string, arguments: arguments, in: path, passEnvironment: passEnvironment, file: file, line: line, lineReader: lineReader)
}

@discardableResult
func sh(_ command: Path, _ arguments: [String], in path: Path? = nil, passEnvironment: Bool = false, file: StaticString = #file, line: UInt = #line, lineReader: ((String) -> Void)? = nil) throws -> ShellCommand {
    try ShellCommand.sh(command: command.string, arguments: arguments, in: path, passEnvironment: passEnvironment, file: file, line: line, lineReader: lineReader)
}

@discardableResult
func sh(_ command: String, _ arguments: String..., in path: Path? = nil, passEnvironment: Bool = false, file: StaticString = #file, line: UInt = #line, lineReader: ((String) -> Void)? = nil) throws -> ShellCommand {
    try ShellCommand.sh(command: command, arguments: arguments, in: path, passEnvironment: passEnvironment, file: file, line: line, lineReader: lineReader)
}

@discardableResult
func sh(_ command: String, _ arguments: [String], in path: Path? = nil, passEnvironment: Bool = false, file: StaticString = #file, line: UInt = #line, lineReader: ((String) -> Void)? = nil) throws -> ShellCommand {
    try ShellCommand.sh(command: command, arguments: arguments, in: path, passEnvironment: passEnvironment, file: file, line: line, lineReader: lineReader)
}

@discardableResult
func which(_ command: String, file: StaticString = #file, line: UInt = #line) throws -> Path {
    do {
        let output = try sh("/usr/bin/which", command, passEnvironment: true, file: file, line: line)
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
    static func sh(
        command: String,
        arguments: [String],
        in path: Path? = nil,
        passEnvironment: Bool = false,
        file: StaticString = #file,
        line: UInt = #line,
        lineReader: ((String) -> Void)? = nil
    ) throws -> ShellCommand {
        let shell = ShellCommand(command: command, arguments: arguments)
        try shell.run(in: path, passEnvironment: passEnvironment, file: file, line: line, lineReader: lineReader)
        return shell
    }

    let command: String
    let arguments: [String]

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    let inputPipe = Pipe()

    private let task = Process()
    private var outputString: String = ""
    private var errorString: String = ""
    private var outputQueue = DispatchQueue(label: "outputQueue")

    init(command: String, arguments: [String]) {
        self.command = command
        self.arguments = arguments
    }

    func run(
        in path: Path? = nil,
        passEnvironment: Bool = false,
        file: StaticString = #file,
        line: UInt = #line,
        lineReader: ((String) -> Void)? = nil
    ) throws {

        defer {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
        }

        task.standardOutput = outputPipe
        task.standardError = errorPipe

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            if let lineString = String(data: handle.availableData, encoding: .utf8), !lineString.isEmpty {
                log.verbose(file: file, line: line, lineString)
                lineReader?(lineString)
                self?.outputQueue.async {
                    self?.outputString.append(lineString)
                }
            }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            if let lineString = String(data: handle.availableData, encoding: .utf8), !lineString.isEmpty {
                log.verbose(file: file, line: line, lineString)
                lineReader?(lineString)
                self?.outputQueue.async {
                    self?.errorString.append(lineString)
                }
            }
        }

        if passEnvironment {
            task.environment = ProcessInfo.processInfo.environment
        }

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

        task.launch()
        task.waitUntilExit()

        if task.terminationStatus != EXIT_SUCCESS {
            try outputQueue.sync {
                throw ScipioError.commandFailed(
                    command: ([command] + arguments).joined(separator: " "),
                    status: Int(task.terminationStatus),
                    output: outputString,
                    error: errorString
                )
            }
        }
    }

    func output(stdout: Bool = true, stderr: Bool = false) throws -> Data {
        return outputQueue.sync {
            let out = stdout ? outputString.data(using: .utf8) ?? Data() : Data()
            let err = stderr ? errorString.data(using: .utf8) ?? Data() : Data()

            return out + err
        }
    }

    func outputString(stdout: Bool = true, stderr: Bool = false) throws -> String {
        return String(data: try output(stdout: stdout, stderr: stderr), encoding: .utf8) ?? ""
    }
}
