import Foundation

public enum Platform: String {
    case iOS = "ios"
    case macOS = "macos"

    public var sdks: [Xcodebuild.SDK] {
        switch self {
        case .iOS:
            return [.iphoneos, .iphonesimulator]
        case .macOS:
            return [.macos]
        }
    }

    public init?(rawValue: String) {
        switch rawValue.lowercased() {
        case "ios":
            self = .iOS
        case "macos", "mac", "osx":
            self = .macOS
        default:
            return nil
        }
    }

    public func asPackagePlatformString(version: String) -> String {
        return ".\(packagePlatformRawValue)(.v\(version.components(separatedBy: ".0").dropLast().joined().replacingOccurrences(of: ".", with: "_")))"
    }

    private var packagePlatformRawValue: String {
        switch self {
        case .iOS:
            return "iOS"
        case .macOS:
            return "macOS"
        }
    }
}

extension Sequence where Element == Platform {
    public var sdks: [Xcodebuild.SDK] {
        return flatMap(\.sdks)
    }
}
