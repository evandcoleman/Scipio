@testable import ScipioKit
import XCTest

final class ArchitectureTests: XCTestCase {
    func testSdkArchitectures() throws {
        let architectures = Architecture.allCases

        XCTAssertEqual(architectures.sdkArchitectures, [
            .iphonesimulator: [.x86_64, .arm64],
            .iphoneos: [.armv7, .arm64],
        ])
    }
}
