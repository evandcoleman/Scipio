import Combine
import Foundation

private let cancelBag = CancelBag()

extension Publisher {
    @discardableResult
    public func wait() throws -> Output? {
        var result: Result<Output, Failure>?

        let semaphore = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            self.sink { completion in
                switch completion {
                case .failure(let error):
                    result = .failure(error)
                case .finished:
                    break
                }
                semaphore.signal()
            } receiveValue: { value in
                result = .success(value)
            }
            .store(in: cancelBag)
        }

        semaphore.wait()

        if let result = result {
            switch result {
            case .failure(let error):
                throw error
            case .success(let value):
                return value
            }
        } else {
            return nil
        }
    }
}
