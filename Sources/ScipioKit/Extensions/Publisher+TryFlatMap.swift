import Combine

extension Publisher {
    public func tryFlatMap<Pub: Publisher>(maxPublishers: Subscribers.Demand = .unlimited, _ transform: @escaping (Output) throws -> Pub) -> Publishers.FlatMap<AnyPublisher<Pub.Output, Error>, Self> {
        return flatMap(maxPublishers: maxPublishers, { input -> AnyPublisher<Pub.Output, Error> in
            do {
                return try transform(input)
                    .mapError { $0 as Error }
                    .eraseToAnyPublisher()
            } catch {
                return Fail(outputType: Pub.Output.self, failure: error)
                    .eraseToAnyPublisher()
            }
        })
    }
}
