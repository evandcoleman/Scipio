import PathKit

extension Path {
    func withoutLastExtension() -> Path {
        return parent() + lastComponentWithoutExtension
    }
}
