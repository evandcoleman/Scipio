import Combine

extension Future where Failure == Error {
    public static func `try`(_ handler: @escaping () throws -> Future.Output) -> Future {
        return Future { promise in
            do {
                promise(.success(try handler()))
            } catch {
                promise(.failure(error))
            }
        }
    }
}
