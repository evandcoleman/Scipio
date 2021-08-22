// swift-tools-version:5.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Scipio",
    platforms: [
        .macOS(.v11)
    ],
    products: [
        .executable(name: "Scipio", targets: ["Scipio"])
    ],
    dependencies: [
        .package(name: "Gzip", url: "https://github.com/1024jp/GzipSwift", from: "5.1.1"),
        .package(url: "https://github.com/kylef/PathKit", from: "1.0.0"),
        .package(url: "https://github.com/sharplet/Regex", from: "2.1.1"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "0.4.4"),
        .package(url: "https://github.com/thii/xcbeautify", from: "0.9.1"),
        .package(name: "XcodeGen", url: "https://github.com/yonaskolb/XcodeGen", from: "2.24.0"),
        .package(url: "https://github.com/tuist/XcodeProj", from: "8.0.0"),
        .package(url: "https://github.com/jpsim/Yams", from: "4.0.6"),
        .package(url: "https://github.com/marmelroy/Zip", from: "2.1.1"),
    ],
    targets: [
        .target(
            name: "Scipio",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "ScipioKit"
            ]
        ),
        .target(
            name: "ScipioKit",
            dependencies: [
                .product(name: "Gzip", package: "Gzip"),
                "PathKit",
                "Regex",
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
