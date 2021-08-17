import Combine

extension Future where Failure == Error {
    public static func `try`(_ handler: @escaping (Future.Promise) throws -> Void) -> Future {
        return Future { promise in
            do {
                try handler(promise)
            } catch {
                promise(.failure(error))
            }
        }
    }
}
