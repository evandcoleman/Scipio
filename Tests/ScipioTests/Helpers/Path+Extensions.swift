import PathKit
import XCTest

extension Path {
    static func temporaryForTests() throws -> Path {
        let path = Path.temporary + "ScipioKitTests"

        if !path.exists {
            try path.mkpath()
        }

        return path
    }

    static func temporary(for testCase: XCTestCase) -> Path {
        return Path.temporary + testCase.name.trimmingCharacters(in: .alphanumerics.inverted).replacingOccurrences(of: " ", with: "-")
    }
}
