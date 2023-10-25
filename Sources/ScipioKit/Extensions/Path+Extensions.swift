import PathKit

extension Path {
    func withoutLastExtension() -> Path {
        return parent() + lastComponentWithoutExtension
    }

    func chdir<T>(_ block: () throws -> T) rethrows -> T {
        let dir = Path.current
        Path.current = self
        let result = try block()
        Path.current = dir
        return result
    }
}
