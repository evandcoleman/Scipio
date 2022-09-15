import PathKit
@testable import ScipioKit
import XCTest

final class SwiftPackageDescriptorTests: XCTestCase {

    private lazy var path = Path.temporary(for: self) + "Package.swift"

    override func setUpWithError() throws {
        setupConfig()

        if !path.parent().exists {
            try path.parent().mkpath()
        }
    }

    func testComputeBuildablesWithTargetDependency() throws {
        let packageText = """
        // swift-tools-version: 5.6
        import PackageDescription
        let package = Package(
          name: "JWT",
          products: [
            .library(name: "JWT", targets: ["JWT"]),
          ],
          dependencies: [
            .package(url: "https://github.com/krzyzanowskim/CryptoSwift.git", from: "0.10.0")
          ],
          targets: [
            .target(name: "JWA", dependencies: ["CryptoSwift"]),
            .target(name: "JWT", dependencies: ["JWA"]),
            .testTarget(name: "JWATests", dependencies: ["JWA"]),
            .testTarget(name: "JWTTests", dependencies: ["JWT"]),
          ]
        )
        """
        try path.write(packageText)
        let package = try PackageManifest.load(from: path.parent())

        XCTAssertEqual(package.name, "JWT")
        XCTAssertEqual(package.getBuildables(), [.target("JWT"), .target("JWA")])
    }

    func testComputeProductNamesWithSingleBinaryTargetDependency() throws {
        let packageText = """
        // swift-tools-version: 5.6
        import PackageDescription
        let package = Package(
          name: "JWT",
          products: [
            .library(name: "JWT", targets: ["JWT"]),
          ],
          targets: [
            .binaryTarget(name: "JWT", path: "JWT.xcframework"),
          ]
        )
        """
        try path.write(packageText)
        let package = try PackageManifest.load(from: path.parent())

        XCTAssertEqual(package.name, "JWT")
        XCTAssertEqual(package.getBuildables(), [.binaryTarget(.init(dependencies: [], name: "JWT", path: "JWT.xcframework", publicHeadersPath: nil, type: .binary, checksum: nil, url: nil, settings: []))])
    }

    func testComputeProductNamesWithBinaryTargetDependency() throws {
        let packageText = """
        // swift-tools-version: 5.6
        import PackageDescription
        let package = Package(
          name: "JWT",
          products: [
            .library(name: "JWT", targets: ["JWTTarget"]),
          ],
          targets: [
            .binaryTarget(name: "JWT", path: "JWT.xcframework"),
            .target(name: "JWTTarget", dependencies: ["JWT"]),
          ]
        )
        """
        try path.write(packageText)
        let package = try PackageManifest.load(from: path.parent())

        XCTAssertEqual(package.name, "JWT")
        XCTAssertEqual(package.getBuildables(), [.binaryTarget(.init(dependencies: [], name: "JWT", path: "JWT.xcframework", publicHeadersPath: nil, type: .binary, checksum: nil, url: nil, settings: []))])
    }

    func testComputeProductNamesForSDWebImage() throws {
        let packageText = """
        // swift-tools-version:5.0
        // The swift-tools-version declares the minimum version of Swift required to build this package.
        import PackageDescription

        let package = Package(
            name: "SDWebImage",
            platforms: [
                .macOS(.v10_11),
                .iOS(.v9),
                .tvOS(.v9),
                .watchOS(.v2)
            ],
            products: [
                // Products define the executables and libraries produced by a package, and make them visible to other packages.
                .library(
                    name: "SDWebImage",
                    targets: ["SDWebImage"]),
                .library(
                    name: "SDWebImageMapKit",
                    targets: ["SDWebImageMapKit"])
            ],
            dependencies: [
                // Dependencies declare other packages that this package depends on.
                // .package(url: /* package url */, from: "1.0.0"),
            ],
            targets: [
                // Targets are the basic building blocks of a package. A target can define a module or a test suite.
                // Targets can depend on other targets in this package, and on products in packages which this package depends on.
                .target(
                    name: "SDWebImage",
                    dependencies: [],
                    path: "SDWebImage",
                    sources: ["Core", "Private"],
                    cSettings: [
                        .headerSearchPath("Core"),
                        .headerSearchPath("Private")
                    ]
                ),
                .target(
                    name: "SDWebImageMapKit",
                    dependencies: ["SDWebImage"],
                    path: "SDWebImageMapKit",
                    sources: ["MapKit"]
                )
            ]
        )
        """
        try path.write(packageText)
        let package = try PackageManifest.load(from: path.parent())

        XCTAssertEqual(package.name, "SDWebImage")
        XCTAssertEqual(package.getBuildables(), [.target("SDWebImage"), .target("SDWebImageMapKit")])
    }
}
