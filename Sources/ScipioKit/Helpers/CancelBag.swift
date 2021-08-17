import Combine

public final class CancelBag {
    fileprivate var cancellables: Set<AnyCancellable> = []

    deinit {
        cancel()
    }

    public init() {}

    public func cancel() {
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
    }
}

extension AnyCancellable {
    public func store(in bag: CancelBag) {
        bag.cancellables.insert(self)
    }
}
