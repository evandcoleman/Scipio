@testable import ScipioKit
import XCTest

final class ArchitectureTests: XCTestCase {
    func sdkArchitectures() throws {
        let architectures = Architecture.allCases

        XCTAssertEqual(architectures.sdkArchitectures, [
            .iphoneos: [.arm64, .armv7],
            .iphonesimulator: [.i386, .x86_64],
        ])
    }
}
