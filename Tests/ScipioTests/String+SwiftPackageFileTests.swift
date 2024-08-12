//
//  String+SwiftPackageFileTests.swift
//
//
//  Created by Evan Coleman on 10/25/23.
//

@testable import ScipioKit
import XCTest

final class String_SwiftPackageFileTests: XCTestCase {

    func testReplaceProductName() throws {
        var file = SwiftPackageFileString(contents: """
// swift-tools-version:4.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Reachability",
    products: [
        .library(
            name: "OtherProduct",
            targets: ["Reachability"]),
        .library(
            name: "Reachability",
            targets: ["Reachability"]),
    ],
    targets: [
        .target(
            name: "Reachability",
            dependencies: [],
            path: "Sources"),
        .testTarget(
            name: "ReachabilityTests",
            dependencies: ["Reachability"],
            path: "Tests"),
    ]
)
""")

        let expected = """
// swift-tools-version:4.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Reachability",
    products: [
        .library(
            name: "OtherProduct",
            targets: ["Reachability"]),
        .library(
            name: "ReachabilitySwift",
            targets: ["Reachability"]),
    ],
    targets: [
        .target(
            name: "Reachability",
            dependencies: [],
            path: "Sources"),
        .testTarget(
            name: "ReachabilityTests",
            dependencies: ["Reachability"],
            path: "Tests"),
    ]
)
"""

        file.replaceProductName("Reachability", newName: "ReachabilitySwift")
        XCTAssertEqual(file.contents, expected)
    }

    func testReplaceTargetName() throws {
        var file = SwiftPackageFileString(contents: """
// swift-tools-version:4.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Reachability",
    products: [
        .library(
            name: "Reachability",
            targets: ["Reachability"]),
    ],
    targets: [
        .target(
            name: "Reachability",
            dependencies: [],
            path: "Sources"),
        .testTarget(
            name: "ReachabilityTests",
            dependencies: ["Reachability"],
            path: "Tests"),
    ]
)
""")

        let expected = """
// swift-tools-version:4.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Reachability",
    products: [
        .library(
            name: "Reachability",
            targets: ["ReachabilitySwift"]),
    ],
    targets: [
        .target(
            name: "ReachabilitySwift",
            dependencies: [],
            path: "Sources"),
        .testTarget(
            name: "ReachabilityTests",
            dependencies: ["ReachabilitySwift"],
            path: "Tests"),
    ]
)
"""

        file.replaceTargetName("Reachability", newName: "ReachabilitySwift")
        XCTAssertEqual(file.contents, expected)
    }
}
