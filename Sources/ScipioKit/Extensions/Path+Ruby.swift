import PathKit
import RubyGateway

public extension Path {
    var rbPath: RbObject {
        return RbObject(ofClass: "Pathname", args: [string])!
    }
}
