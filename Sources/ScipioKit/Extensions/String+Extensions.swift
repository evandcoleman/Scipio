import Foundation

extension String {
    var nilIfEmpty: String? {
        return isEmpty ? nil : self
    }

    var quoted: String {
        return #""\#(self)""#
    }
}
