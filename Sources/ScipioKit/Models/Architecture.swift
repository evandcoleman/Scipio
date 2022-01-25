import Foundation

public enum Architecture: String, CaseIterable, CustomStringConvertible {
    case armv7
    case x86_64
    case arm64

    public var description: String { rawValue }

    public var possibleSDKs: [Xcodebuild.SDK] {
        switch self {
        case .armv7:
            return [.iphoneos]
        case .x86_64:
            return [.iphonesimulator]
        case .arm64:
            return [.iphoneos, .iphonesimulator]
        }
    }
}

public extension Xcodebuild.SDK {
    var architectures: [Architecture] {
        switch self {
        case .iphoneos:
            return [.armv7, .arm64]
        case .iphonesimulator, .macos:
            return [.x86_64, .arm64]
        }
    }
}

extension Collection where Iterator.Element == Architecture {
    public var sdkArchitectures: [Xcodebuild.SDK: [Architecture]] {
        return Set(flatMap(\.possibleSDKs))
            .reduce(into: [:]) { $0[$1] = $1.architectures }
    }
}
