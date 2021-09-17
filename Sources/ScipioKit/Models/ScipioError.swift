import Foundation

public enum ScipioError: LocalizedError {
    case zipFailure(AnyArtifact)
    case commandFailed(command: String, status: Int, output: String?, error: String?)
    case checksumMismatch(product: String)
    case unknownPackage(String)
    case conflictingDependencies(product: String, conflictingDependencies: [String])
    case invalidFramework(String)
    case missingArchitectures(String, [Architecture])

    public var errorDescription: String? {
        switch self {
        case .zipFailure(let artifact):
            return "Failed to zip artifact (\(artifact.name)) at \(artifact.path)"
        case .commandFailed(let command, let status, _, let error):
            return "Command `\(command)` failed with status \(status)\(error == nil ? "" : ": \(error!)")"
        case .checksumMismatch(let product):
            return "Checksum does not match for \"\(product)\""
        case .unknownPackage(let name):
            return "Unknown package \"\(name)\""
        case .conflictingDependencies(let product, let dependencies):
            return "\(dependencies.count) dependencies (\(dependencies.joined(separator: ", "))) produce \(product). It is recommended to add \(product) as an explicit dependency and/or exclude it from the conflicting packages via the configuration file."
        case .invalidFramework(let name):
            return "Invalid framework \(name)"
        case .missingArchitectures(let name, let archs):
            return "\(name) is missing required architectures \(archs.map(\.description).joined(separator: ", "))"
        }
    }
}
