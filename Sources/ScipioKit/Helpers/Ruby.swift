import Foundation
import PathKit

public enum RubyError: LocalizedError {
    case missingRuby

    public var errorDescription: String? {
        switch self {
        case .missingRuby:
            return "A Ruby installation that is not provided by the system is required to use CocoaPods dependencies. Please install Ruby via rbenv, rvm, or Homebrew."
        }
    }
}

struct Ruby {

    let rubyPath: Path
    private let gemPath: Path

    init() throws {
        do {
            rubyPath = try which("ruby")
            gemPath = try which("gem")
        } catch ShellError.commandNotFound {
            throw RubyError.missingRuby
        }
    }

    func installGem(_ gem: String) throws {
        try sh(gemPath, "install", gem)
            .logOutput()
            .waitUntilExit()
    }

    func bundle(install gems: String..., at path: Path) throws {
        try bundle(install: gems, at: path)
    }

    func bundle(install gems: [String], at path: Path) throws {
        let gemfilePath = path + "Gemfile"

        try gemfilePath.write("""
source "https://rubygems.org"

\(gems.map { #"gem "\#($0)""# }.joined(separator: "\n"))
""")

        let gemfileContents: String = try gemfilePath.read()
        log.verbose("Installing gems from Gemfile at ", path.string, "\n", gemfileContents)

        do {
            let bundlePath = try which("bundle")
            try sh(bundlePath, "--version")
                .waitUntilExit()
        } catch {
            try installGem("bundler")
        }

        let bundlePath = try which("bundle")

        try sh(bundlePath, "config", "set", "--local", "path", "vendor/bundle", in: path)
            .logOutput()
            .waitUntilExit()

        try sh(bundlePath, "install", in: path)
            .logOutput()
            .waitUntilExit()
    }

    func bundle(exec command: String, _ arguments: String..., at path: Path) throws {
        let bundlePath = try which("bundle")

        try sh(bundlePath, ["exec", command] + arguments, in: path)
            .logOutput()
            .waitUntilExit()
    }

    func commandExists(_ command: String) -> Bool {
        return (try? which(command)) != nil
    }
}
