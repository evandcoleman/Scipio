import Combine

extension Future where Failure == Error {
    public static func deferred(_ handler: @escaping (@escaping Future.Promise) -> Void) -> Deferred<Future> {
        return Deferred {
            Future { handler($0) }
        }
    }
}
