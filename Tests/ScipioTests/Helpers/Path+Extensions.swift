import PathKit
import XCTest

extension Path {
    static func temporary(for testCase: XCTestCase) -> Path {
        return Path.temporary + testCase.name.trimmingCharacters(in: .alphanumerics.inverted).replacingOccurrences(of: " ", with: "-")
    }
}
