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
        // swift-tools-version:5.3
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
        XCTAssertEqual(package.getBuildables(), [.scheme("JWT"), .target("JWA")])
    }

    func testComputeProductNamesWithBinaryTargetDependency() throws {
        let packageText = """
        // swift-tools-version:5.3
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
}
