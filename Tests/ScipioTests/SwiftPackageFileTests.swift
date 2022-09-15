import PathKit
@testable import ScipioKit
import XCTest

final class SwiftPackageFileTests: XCTestCase {

    private lazy var path = Path.temporary(for: self) + "Package.swift"

    override func setUpWithError() throws {
        setupConfig()

        if !path.parent().exists {
            try path.parent().mkpath()
        } else if path.exists {
            try path.delete()
        }
    }

    func testWritingNewFile() throws {
        let file = try SwiftPackageFile(
            name: "TestPackage",
            path: path,
            platforms: [.iOS: "12.0"],
            artifacts: [
                .mock(name: "Product1", parentName: "Package1"),
                .mock(name: "Product2", parentName: "Package1"),
                .mock(name: "Product3", parentName: "Package2"),
            ],
            removeMissing: true
        )
        let result = file.asString(relativeTo: path.parent())
        let expectedResult = """
// swift-tools-version: 5.6
import PackageDescription

let package = Package(
    name: "TestPackage",
    platforms: [
        .iOS(.v12)
    ],
    products: [
        .library(name: "Product1", targets: ["Product1"]),
        .library(name: "Product2", targets: ["Product2"]),
        .library(name: "Product3", targets: ["Product3"])
    ],
    targets: [
        .binaryTarget(
            name: "Product1",
            url: "https://scipio.test/packages/Product1/Product1.xcframework.zip",
            checksum: "28b66030599490a87113433e84f39d788cdcb40be104fd00156d90cd8ec0656d"
        ),
        .binaryTarget(
            name: "Product2",
            url: "https://scipio.test/packages/Product2/Product2.xcframework.zip",
            checksum: "909a4b17649cd39ca05e33be0f7a5e60d34e272b918058bd57ed19a4afc21549"
        ),
        .binaryTarget(
            name: "Product3",
            url: "https://scipio.test/packages/Product3/Product3.xcframework.zip",
            checksum: "5be156b10ff7c684ff48c59a085560e347253a01d0093e47f122be9ed80f7646"
        )
    ]
)
"""

        XCTAssertEqual(result, expectedResult)
    }

    func testUpdateExistingFile() throws {
        var artifact: CachedArtifact = try .mock(name: "Product1", parentName: "Package1")

        let existingFile = """
// swift-tools-version: 5.6
import PackageDescription

let package = Package(
    name: "TestPackage",
    platforms: [
        .iOS(.v12)
    ],
    products: [
        .library(name: "Product1", targets: ["Product1"]),
        .library(name: "Product2", targets: ["Product2"]),
        .library(name: "Product3", targets: ["Product3"])
    ],
    targets: [
        .binaryTarget(
            name: "Product1",
            url: "https://scipio.test/packages/Product1/Product1.xcframework.zip",
            checksum: "28b66030599490a87113433e84f39d788cdcb40be104fd00156d90cd8ec0656d"
        ),
        .binaryTarget(
            name: "Product2",
            url: "https://scipio.test/packages/Product2/Product2.xcframework.zip",
            checksum: "909a4b17649cd39ca05e33be0f7a5e60d34e272b918058bd57ed19a4afc21549"
        ),
        .binaryTarget(
            name: "Product3",
            url: "https://scipio.test/packages/Product3/Product3.xcframework.zip",
            checksum: "5be156b10ff7c684ff48c59a085560e347253a01d0093e47f122be9ed80f7646"
        )
    ]
)
"""
        var file = try SwiftPackageFile(
            name: "TestPackage",
            path: path,
            platforms: [.iOS: "12.0"],
            artifacts: [
                artifact,
                .mock(name: "Product2", parentName: "Package1"),
                .mock(name: "Product3", parentName: "Package2"),
            ],
            removeMissing: true
        )

        XCTAssertEqual(existingFile, file.asString(relativeTo: path.parent()))

        try artifact.localPath!.write("new file contents")
        artifact = try CachedArtifact(name: artifact.name, parentName: artifact.parentName, url: artifact.url, localPath: artifact.localPath!)
        file.artifacts[0] = artifact
        try file.read()

        let result = file.asString(relativeTo: path.parent())
        let expectedResult = """
// swift-tools-version: 5.6
import PackageDescription

let package = Package(
    name: "TestPackage",
    platforms: [
        .iOS(.v12)
    ],
    products: [
        .library(name: "Product1", targets: ["Product1"]),
        .library(name: "Product2", targets: ["Product2"]),
        .library(name: "Product3", targets: ["Product3"])
    ],
    targets: [
        .binaryTarget(
            name: "Product1",
            url: "https://scipio.test/packages/Product1/Product1.xcframework.zip",
            checksum: "428189279ce0f27c1e26d0555538043bae351115e3795b1d3ffcb2948de131dd"
        ),
        .binaryTarget(
            name: "Product2",
            url: "https://scipio.test/packages/Product2/Product2.xcframework.zip",
            checksum: "909a4b17649cd39ca05e33be0f7a5e60d34e272b918058bd57ed19a4afc21549"
        ),
        .binaryTarget(
            name: "Product3",
            url: "https://scipio.test/packages/Product3/Product3.xcframework.zip",
            checksum: "5be156b10ff7c684ff48c59a085560e347253a01d0093e47f122be9ed80f7646"
        )
    ]
)
"""

        XCTAssertEqual(result, expectedResult)
    }

    func testUpdateExistingFileWithOnlyOneArtifact() throws {
        let existingFile = """
// swift-tools-version: 5.6
import PackageDescription

let package = Package(
    name: "TestPackage",
    platforms: [
        .iOS(.v12)
    ],
    products: [
        .library(name: "Product1", targets: ["Product1"]),
        .library(name: "Product2", targets: ["Product2"]),
        .library(name: "Product3", targets: ["Product3"])
    ],
    targets: [
        .binaryTarget(
            name: "Product1",
            url: "https://scipio.test/packages/Product1/Product1.xcframework.zip",
            checksum: "28b66030599490a87113433e84f39d788cdcb40be104fd00156d90cd8ec0656d"
        ),
        .binaryTarget(
            name: "Product2",
            url: "https://scipio.test/packages/Product1/Product2.xcframework.zip",
            checksum: "7324b29c1b0d61131adfa0035669a1717761f2b211fadb2be2dd2ea9a4396a7b"
        ),
        .binaryTarget(
            name: "Product3",
            url: "https://scipio.test/packages/Product2/Product3.xcframework.zip",
            checksum: "909a4b17649cd39ca05e33be0f7a5e60d34e272b918058bd57ed19a4afc21549"
        )
    ]
)
"""
        try path.write(existingFile)
        let file = try SwiftPackageFile(
            name: "TestPackage",
            path: path,
            platforms: [.iOS: "12.0"],
            artifacts: [
                .mock(name: "Product1", parentName: "Package1"),
            ],
            removeMissing: false
        )
        let result = file.asString(relativeTo: path.parent())
        let expectedResult = """
// swift-tools-version: 5.6
import PackageDescription

let package = Package(
    name: "TestPackage",
    platforms: [
        .iOS(.v12)
    ],
    products: [
        .library(name: "Product1", targets: ["Product1"]),
        .library(name: "Product2", targets: ["Product2"]),
        .library(name: "Product3", targets: ["Product3"])
    ],
    targets: [
        .binaryTarget(
            name: "Product1",
            url: "https://scipio.test/packages/Product1/Product1.xcframework.zip",
            checksum: "28b66030599490a87113433e84f39d788cdcb40be104fd00156d90cd8ec0656d"
        ),
        .binaryTarget(
            name: "Product2",
            url: "https://scipio.test/packages/Product1/Product2.xcframework.zip",
            checksum: "7324b29c1b0d61131adfa0035669a1717761f2b211fadb2be2dd2ea9a4396a7b"
        ),
        .binaryTarget(
            name: "Product3",
            url: "https://scipio.test/packages/Product2/Product3.xcframework.zip",
            checksum: "909a4b17649cd39ca05e33be0f7a5e60d34e272b918058bd57ed19a4afc21549"
        )
    ]
)
"""

        XCTAssertEqual(result, expectedResult)
    }

    func testOnlyAddNewArtifact() throws {
        let existingFile = """
// swift-tools-version: 5.6
import PackageDescription

let package = Package(
    name: "TestPackage",
    platforms: [
        .iOS(.v12)
    ],
    products: [
        .library(name: "Product1", targets: ["Product1"]),
        .library(name: "Product2", targets: ["Product2"])
    ],
    targets: [
        .binaryTarget(
            name: "Product1",
            url: "https://scipio.test/packages/Product1/Product1.xcframework.zip",
            checksum: "28b66030599490a87113433e84f39d788cdcb40be104fd00156d90cd8ec0656d"
        ),
        .binaryTarget(
            name: "Product2",
            url: "https://scipio.test/packages/Product2/Product2.xcframework.zip",
            checksum: "7324b29c1b0d61131adfa0035669a1717761f2b211fadb2be2dd2ea9a4396a7b"
        )
    ]
)
"""
        try path.write(existingFile)
        let file = try SwiftPackageFile(
            name: "TestPackage",
            path: path,
            platforms: [.iOS: "12.0"],
            artifacts: [
                .mock(name: "Product3", parentName: "Package1"),
            ],
            removeMissing: false
        )
        let result = file.asString(relativeTo: path.parent())
        let expectedResult = """
// swift-tools-version: 5.6
import PackageDescription

let package = Package(
    name: "TestPackage",
    platforms: [
        .iOS(.v12)
    ],
    products: [
        .library(name: "Product1", targets: ["Product1"]),
        .library(name: "Product2", targets: ["Product2"]),
        .library(name: "Product3", targets: ["Product3"])
    ],
    targets: [
        .binaryTarget(
            name: "Product1",
            url: "https://scipio.test/packages/Product1/Product1.xcframework.zip",
            checksum: "28b66030599490a87113433e84f39d788cdcb40be104fd00156d90cd8ec0656d"
        ),
        .binaryTarget(
            name: "Product2",
            url: "https://scipio.test/packages/Product2/Product2.xcframework.zip",
            checksum: "7324b29c1b0d61131adfa0035669a1717761f2b211fadb2be2dd2ea9a4396a7b"
        ),
        .binaryTarget(
            name: "Product3",
            url: "https://scipio.test/packages/Product3/Product3.xcframework.zip",
            checksum: "8e5dc7eca162a90a3fe83caf53add89c3d977385c2de29045521ccfb45319481"
        )
    ]
)
"""

        XCTAssertEqual(result, expectedResult)
    }

    func testAddNewArtifact() throws {
        let existingFile = """
// swift-tools-version: 5.6
import PackageDescription

let package = Package(
    name: "TestPackage",
    platforms: [
        .iOS(.v12)
    ],
    products: [
        .library(name: "Product1", targets: ["Product1"]),
        .library(name: "Product2", targets: ["Product2"])
    ],
    targets: [
        .binaryTarget(
            name: "Product1",
            url: "https://scipio.test/packages/Product1/Product1.xcframework.zip",
            checksum: "28b66030599490a87113433e84f39d788cdcb40be104fd00156d90cd8ec0656d"
        ),
        .binaryTarget(
            name: "Product2",
            url: "https://scipio.test/packages/Product2/Product2.xcframework.zip",
            checksum: "7324b29c1b0d61131adfa0035669a1717761f2b211fadb2be2dd2ea9a4396a7b"
        )
    ]
)
"""
        try path.write(existingFile)
        let file = try SwiftPackageFile(
            name: "TestPackage",
            path: path,
            platforms: [.iOS: "12.0"],
            artifacts: [
                .mock(name: "Product1", parentName: "Package1"),
                .mock(name: "Product3", parentName: "Package1"),
                .mock(name: "Product2", parentName: "Package2"),
            ],
            removeMissing: true
        )
        let result = file.asString(relativeTo: path.parent())
        let expectedResult = """
// swift-tools-version: 5.6
import PackageDescription

let package = Package(
    name: "TestPackage",
    platforms: [
        .iOS(.v12)
    ],
    products: [
        .library(name: "Product1", targets: ["Product1"]),
        .library(name: "Product2", targets: ["Product2"]),
        .library(name: "Product3", targets: ["Product3"])
    ],
    targets: [
        .binaryTarget(
            name: "Product1",
            url: "https://scipio.test/packages/Product1/Product1.xcframework.zip",
            checksum: "28b66030599490a87113433e84f39d788cdcb40be104fd00156d90cd8ec0656d"
        ),
        .binaryTarget(
            name: "Product2",
            url: "https://scipio.test/packages/Product2/Product2.xcframework.zip",
            checksum: "473c481f625984d3c917fdb7edfb213251653837c0fb10c927f0bbbaf7420ea7"
        ),
        .binaryTarget(
            name: "Product3",
            url: "https://scipio.test/packages/Product3/Product3.xcframework.zip",
            checksum: "8e5dc7eca162a90a3fe83caf53add89c3d977385c2de29045521ccfb45319481"
        )
    ]
)
"""

        XCTAssertEqual(result, expectedResult)
    }
}
