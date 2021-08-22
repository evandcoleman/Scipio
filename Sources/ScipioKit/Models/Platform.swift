import Foundation

public enum Platform: String {
    case iOS = "ios"
    case macOS = "macos"

    public var sdks: [Xcodebuild.SDK] {
        switch self {
        case .iOS:
            return [.iphoneos, .iphoneos]
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
}
