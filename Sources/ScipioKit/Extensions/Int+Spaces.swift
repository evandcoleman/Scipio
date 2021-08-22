import Foundation

extension Int {
    var spaces: String {
        return (0..<self)
            .map { _ in " " }
            .joined()
    }
}
