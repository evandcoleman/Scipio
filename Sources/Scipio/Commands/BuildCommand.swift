import ArgumentParser
import PathKit
import ScipioKit

extension Command {
    struct Build: ParsableCommand {
        static var configuration: CommandConfiguration {
            .init(
                commandName: "build",
                abstract: "Builds some or all packages"
            )
        }

        @Argument(help: "Path to the Xcode project containing package dependencies")
        var project: String?
        @Argument(help: "An array of packages or products to build", transform: { $0.components(separatedBy: ",") })
        var packages: [String]?
        @Argument(help: "An array of SDKs to build for", transform: { $0.components(separatedBy: ",") })
        var sdks: [String]?

        @Argument(help: "If true will skip building dependencies that are already built")
        var skipClean: Bool = false
        @Argument(help: "If true will skip resolving dependencies")
        var skipResolveDependencies: Bool = false
        @Argument(help: "If true will build packages that are already uploaded")
        var force: Bool = false

        func run() throws {
            guard let projectPath = project ?? Path.current.glob("*.xcodeproj").first?.string else {
                fatalError("No project specified and couldn't find one in the current directory.")
            }

            let project = try Project(path: Path(projectPath))

            if !skipClean {
                try project.cleanBuildDirectory()
            }

            if !skipResolveDependencies {
                project.resolvePackageDependencies()
            }

            let packages = try project.getPackages()
            let buildOnlyPackageNames = self.packages ?? packages.map(\.name)

            for package in packages where buildOnlyPackageNames.contains(package.name) {
                
            }
        }
    }
}
