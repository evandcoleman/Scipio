import Foundation

public enum Architecture: String, CaseIterable, CustomStringConvertible {
    case armv7
    case i386
    case x86_64
    case arm64

    public var description: String { rawValue }

    public var sdk: Xcodebuild.SDK {
        switch self {
        case .armv7, .arm64:
            return .iphoneos
        case .x86_64, .i386:
            return .iphonesimulator
        }
    }
}

public extension Xcodebuild.SDK {
    var architectures: [Architecture] {
        switch self {
        case .iphoneos:
            return [.armv7, .arm64]
        case .iphonesimulator, .macos:
            return [.x86_64, .i386]
        }
    }
}

extension Collection where Iterator.Element == Architecture {
    public var sdkArchitectures: [Xcodebuild.SDK: [Architecture]] {
        return reduce(into: [:]) { $0[$1.sdk, default: []].append($1) }
    }
}
