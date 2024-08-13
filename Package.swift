// swift-tools-version: 5.7
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let swiftVersionedDependencies: [Package.Dependency] = {
    let swiftPMURL = "https://github.com/apple/swift-package-manager"
    let swiftToolsURL = "https://github.com/apple/swift-tools-support-core"

    #if swift(>=5.9)
    return [
        .package(url: swiftPMURL, branch: "release/5.9"),
        .package(url: swiftToolsURL, branch: "release/5.9"),
    ]
    #else
    return [
        .package(url: swiftPMURL, branch: "release/5.7"),
        .package(url: swiftToolsURL, branch: "release/5.7"),
    ]
    #endif
}()

let package = Package(
    name: "Scipio",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Scipio", targets: ["Scipio"])
    ],
    dependencies: swiftVersionedDependencies + [
        .package(url: "https://github.com/kylef/PathKit", from: "1.0.0"),
        .package(url: "https://github.com/sharplet/Regex", from: "2.1.1"),
        .package(url: "https://github.com/tsolomko/SWCompression.git", from: "4.6.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.2.2"),
        .package(url: "https://github.com/thii/xcbeautify", from: "0.9.1"),
        .package(url: "https://github.com/yonaskolb/XcodeGen", from: "2.42.0"),
        .package(url: "https://github.com/tuist/XcodeProj", from: "8.0.0"),
        .package(url: "https://github.com/jpsim/Yams", from: "5.0.0"),
        .package(url: "https://github.com/marmelroy/Zip", from: "2.1.1"),
    ],
    targets: [
        .executableTarget(
            name: "Scipio",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "ScipioKit"
            ]
        ),
        .target(
            name: "ScipioKit",
            dependencies: [
                "PathKit",
                "Regex",
                "SWCompression",
                .product(name: "SwiftPM-auto", package: "swift-package-manager"),
                .product(name: "SwiftToolsSupport-auto", package: "swift-tools-support-core"),
                .product(name: "XcbeautifyLib", package: "xcbeautify"),
                .product(name: "XcodeGenKit", package: "XcodeGen"),
                "XcodeProj",
                "Yams",
                "Zip",
            ]
        ),
        .testTarget(
            name: "ScipioTests",
            dependencies: ["ScipioKit"]
        ),
    ]
)
