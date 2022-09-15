import Foundation

public let log: Log = .shared

public final class Log: NSObject {

    public static let shared = Log()

    internal let operationQueue = OperationQueue()

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

    public var level: Level = .info
    public var debugLevel: Level = .debug
    public var useColors: Bool = true

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    public func debug(file: StaticString = #file, line: UInt = #line, column: Int = #column, _ message: Any...) {
        self.log(level: .debug, file: file, line: line, column: column, message)
    }

    public func verbose(file: StaticString = #file, line: UInt = #line, column: Int = #column, _ message: Any...) {
        self.log(level: .verbose, file: file, line: line, column: column, message)
    }

    public func info(file: StaticString = #file, line: UInt = #line, column: Int = #column, _ message: Any...) {
        self.log(level: .info, file: file, line: line, column: column, message)
    }

    public func success(file: StaticString = #file, line: UInt = #line, column: Int = #column, _ message: Any...) {
        self.log(level: .success, file: file, line: line, column: column, message)
    }

    public func warning(file: StaticString = #file, line: UInt = #line, column: Int = #column, _ message: Any...) {
        self.log(level: .warning, file: file, line: line, column: column, message)
    }

    public func error(file: StaticString = #file, line: UInt = #line, column: Int = #column, _ message: Any...) {
        self.log(level: .error, file: file, line: line, column: column, message)
    }

    public func passthrough(file: StaticString = #file, line: UInt = #line, column: Int = #column, _ message: Any...) {
        self.log(level: .passthrough, file: file, line: line, column: column, message)
    }

    public func progress(file: StaticString = #file, line: UInt = #line, column: Int = #column, percent: Double) {
        let width: Int = 40
        let message = "[" + stride(from: 0, to: width, by: 1)
            .map { Double($0) / Double(width) > min(percent, 1) ? "-" : "=" }
            .joined() + "] \(Int((percent * 100).rounded()))%"

        if percent >= 1 {
            self.log(level: .success, file: file, line: line, column: column, [message])
        } else {
            self.log(level: .info, terminator: "\r", file: file, line: line, column: column, [message])
        }
    }

    public func fatal(file: StaticString = #file, line: UInt = #line, column: Int = #column, _ message: Any...) -> Never {
        self.log(level: .error, file: file, line: line, column: column, message)
        exit(EXIT_FAILURE)
    }

    private var isDebug: Bool {
        #if DEBUG
            return true
        #else
            return false
        #endif
    }

    private func log(level: Level, terminator: String = "\n", file: StaticString = #file, line: UInt = #line, column: Int = #column, _ message: [Any]) {
        if isDebug {
            guard level.levelValue >= debugLevel.levelValue else { return }
        } else {
            guard level.levelValue >= self.level.levelValue else { return }
        }

        let filename = URL(fileURLWithPath: "\(file)").lastPathComponent
        let formattedMessage = message.map { String(describing: $0) } .joined(separator: " ")
        let dateText = Log.dateFormatter.string(from: Date())
        let debugMessage = "[\(dateText)]: [\(filename):\(line):\(column)] | \(formattedMessage)"
        let defaultMessage = "[\(dateText)]: \(formattedMessage)"

        switch level {
        case .debug where isDebug:
            if useColors {
                print("\(debugMessage, color: level.color)", terminator: terminator)
            } else {
                print(debugMessage, terminator: terminator)
            }
        case .passthrough:
            print(isDebug ? debugMessage : defaultMessage, terminator: terminator)
        case .debug:
            break
        default:
            if useColors {
                print("\(isDebug ? debugMessage : defaultMessage, color: level.color)", terminator: terminator)
            } else {
                print(isDebug ? debugMessage : defaultMessage, terminator: terminator)
            }
        }

        fflush(__stdoutp)
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
