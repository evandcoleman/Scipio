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

    private let rubyPath: Path
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

    func commandExists(_ command: String) -> Bool {
        return (try? which(command)) != nil
    }
}
