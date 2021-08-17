import Foundation

public let log = Log.self

public struct Log {
    public enum Level {
        case passthrough
        case debug
        case verbose
        case info
        case success
        case warning
        case error

        internal var color: Color {
            switch self {
            case .passthrough: return .default
            case .debug: return .blue
            case .verbose: return .default
            case .info: return .white
            case .success: return .green
            case .warning: return .yellow
            case .error: return .red
            }
        }

        internal var levelValue: Int {
            switch self {
            case .debug: return 0
            case .verbose: return 1
            case .info: return 2
            case .success: return 2
            case .warning: return 2
            case .error: return 3
            case .passthrough: return 2
            }
        }
    }

    public static var level: Level = .warning
    public static var debugLevel: Level = .debug
    public static var useColors: Bool = true

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    public static func debug(file: String = #file, line: Int = #line, column: Int = #column, _ message: Any...) {
        self.log(level: .debug, file: file, line: line, column: column, message)
    }

    public static func verbose(file: String = #file, line: Int = #line, column: Int = #column, _ message: Any...) {
        self.log(level: .verbose, file: file, line: line, column: column, message)
    }

    public static func info(file: String = #file, line: Int = #line, column: Int = #column, _ message: Any...) {
        self.log(level: .info, file: file, line: line, column: column, message)
    }

    public static func success(file: String = #file, line: Int = #line, column: Int = #column, _ message: Any...) {
        self.log(level: .success, file: file, line: line, column: column, message)
    }

    public static func warning(file: String = #file, line: Int = #line, column: Int = #column, _ message: Any...) {
        self.log(level: .warning, file: file, line: line, column: column, message)
    }

    public static func error(file: String = #file, line: Int = #line, column: Int = #column, _ message: Any...) {
        self.log(level: .error, file: file, line: line, column: column, message)
    }

    public static func passthrough(file: String = #file, line: Int = #line, column: Int = #column, _ message: Any...) {
        self.log(level: .passthrough, file: file, line: line, column: column, message)
    }

    public static func fatal(file: String = #file, line: Int = #line, column: Int = #column, _ message: Any...) -> Never {
        self.log(level: .error, file: file, line: line, column: column, message)
        exit(EXIT_FAILURE)
    }

    private static var isDebug: Bool {
        #if DEBUG
            return true
        #else
            return false
        #endif
    }

    private static func log(level: Level, file: String = #file, line: Int = #line, column: Int = #column, _ message: [Any]) {
        if Log.isDebug {
            guard level.levelValue >= Log.debugLevel.levelValue else { return }
        } else {
            guard level.levelValue >= Log.level.levelValue else { return }
        }

        let filename = URL(string: file)?.lastPathComponent ?? ""
        let formattedMessage = message.map { String(describing: $0) } .joined(separator: " ")
        let dateText = Log.dateFormatter.string(from: Date())
        let debugMessage = "[\(dateText)]: [\(filename):\(line):\(column)] | \(formattedMessage)"
        let defaultMessage = "[\(dateText)]: \(formattedMessage)"

        switch level {
        case .debug where Log.isDebug:
            if useColors {
                print("\(debugMessage, color: level.color)")
            } else {
                print(debugMessage)
            }
        case .passthrough:
            print(Log.isDebug ? debugMessage : defaultMessage)
        case .debug:
            break
        default:
            if useColors {
                print("\(Log.isDebug ? debugMessage : defaultMessage, color: level.color)")
            } else {
                print(Log.isDebug ? debugMessage : defaultMessage)
            }
        }
    }
}

public extension Log {
    enum Color: String {
        case black = "\u{001B}[0;30m"
        case red = "\u{001B}[0;31m"
        case green = "\u{001B}[0;32m"
        case yellow = "\u{001B}[0;33m"
        case blue = "\u{001B}[0;34m"
        case magenta = "\u{001B}[0;35m"
        case cyan = "\u{001B}[0;36m"
        case white = "\u{001B}[0;37m"
        case `default` = "\u{001B}[0;0m"
    }
}

public extension DefaultStringInterpolation {
    mutating func appendInterpolation<T: CustomStringConvertible>(_ value: T, color: Log.Color) {
        appendInterpolation("\(color.rawValue)\(value)\(Log.Color.default.rawValue)")
    }
}
