import Foundation

public enum ScipioError: LocalizedError {
    case zipFailure(Artifact)
    case commandFailed(command: String, status: Int, output: String?)

    public var errorDescription: String? {
        switch self {
        case .zipFailure(let artifact):
            return "Failed to zip artifact (\(artifact.name)) at \(artifact.path)"
        case .commandFailed(let command, let status, let output):
            return "Command `\(command)` failed with status \(status)\(output == nil ? "" : ": \(output!)")"
        }
    }
}
