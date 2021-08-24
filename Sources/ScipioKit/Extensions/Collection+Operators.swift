import Foundation

infix operator <<< : AssignmentPrecedence

public func <<< <T: RangeReplaceableCollection>(lhs: inout T, rhs: T.Iterator.Element) {
    lhs.append(rhs)
}

public func <<< <T: RangeReplaceableCollection>(lhs: inout T, rhs: T?) {
    lhs.append(contentsOf: rhs ?? T())
}

public func + <T: RangeReplaceableCollection>(lhs: T?, rhs: T?) -> T {
    return (lhs ?? T()) + (rhs ?? T())
}
