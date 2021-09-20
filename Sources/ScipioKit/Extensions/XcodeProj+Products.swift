import PathKit
import XcodeProj

enum ProjectProduct: Hashable {
    case product(String)
    case path(Path)

    var name: String {
        switch self {
        case .product(let name):
            return name
        case .path(let path):
            return path.lastComponentWithoutExtension
        }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(name)
    }
}

extension XcodeProj {
    var productNames: [String] {
        return pbxproj
            .groups
            .first { $0.name == "Products" }?
            .children
            .compactMap { $0.name?.components(separatedBy: ".").first } ?? []
    }

    func productNames(for targetName: String, podsRoot: Path) -> [ProjectProduct] {
        return pbxproj
            .targets(named: targetName)
            .flatMap { $0.productNames(podsRoot: podsRoot) }
            .filter { !$0.name.isEmpty }
            .uniqued()
    }

    func resourceBundles(for targetName: String, podsRoot: Path, notIn notInProjectProducts: [ProjectProduct]) -> [Path] {
        return pbxproj
            .targets(named: targetName)
            .flatMap { $0.resourceBundles(podsRoot: podsRoot, notIn: notInProjectProducts) }
            .uniqued()
    }
}

extension PBXTarget {
    func productNames(podsRoot: Path) -> [ProjectProduct] {
        var names: [ProjectProduct] = []

        if let productPath = product?.path {
            names <<< .product(Path(productPath).lastComponentWithoutExtension)
        }

        if let aggregateTarget = self as? PBXAggregateTarget {
            let vendoredFrameworkNames = aggregateTarget
                .buildPhases
                .flatMap { $0.inputFileListPaths ?? [] }
                .flatMap { path -> [ProjectProduct] in
                    let fixedPath = path
                        .replacingOccurrences(of: "${PODS_ROOT}/", with: "")
                        .replacingOccurrences(of: "$PODS_ROOT/", with: "")
                    let contents = (try? (podsRoot + Path(fixedPath)).read()) ?? ""

                    return contents
                        .components(separatedBy: "\n")
                        .compactMap { pathString in
                            let path = podsRoot + Path(
                                pathString
                                    .replacingOccurrences(of: "${PODS_ROOT}/", with: "")
                                    .replacingOccurrences(of: "$PODS_ROOT/", with: "")
                            )

                            return path.extension == "xcframework" ? .path(path) : nil
                        }
                }

            names <<< vendoredFrameworkNames
        }

        for dependency in dependencies {
            if let target = dependency.target {
                names <<< target.productNames(podsRoot: podsRoot)
            }
        }

        return names
    }

    func resourceBundles(podsRoot: Path, notIn notInProjectProducts: [ProjectProduct]) -> [Path] {
        var paths: [Path] = []

        let resourceBundlePaths = buildPhases
            .flatMap { $0.inputFileListPaths ?? [] }
            .flatMap { path -> [Path] in
                let fixedPath = path
                    .replacingOccurrences(of: "${PODS_ROOT}/", with: "")
                    .replacingOccurrences(of: "$PODS_ROOT/", with: "")
                    .replacingOccurrences(of: "${CONFIGURATION}", with: "Release")
                    .replacingOccurrences(of: "$CONFIGURATION", with: "Release")
                let contents = (try? (podsRoot + Path(fixedPath)).read()) ?? ""

                return contents
                    .components(separatedBy: "\n")
                    .compactMap { pathString -> Path? in
                        let path = podsRoot + Path(
                            pathString
                                .replacingOccurrences(of: "${PODS_ROOT}/", with: "")
                                .replacingOccurrences(of: "$PODS_ROOT/", with: "")
                                .replacingOccurrences(of: "${CONFIGURATION}", with: "Release")
                                .replacingOccurrences(of: "$CONFIGURATION", with: "Release")
                        )

                        return path.extension == "bundle" ? path : nil
                    }
                    .filter { path in
                        return !notInProjectProducts
                            .contains { path.components.contains("\($0.name).xcframework") }
                    }
            }

        paths <<< resourceBundlePaths

        for dependency in dependencies {
            if let target = dependency.target {
                paths <<< target.resourceBundles(podsRoot: podsRoot, notIn: notInProjectProducts)
            }
        }

        return paths
    }
}
