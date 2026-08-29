import Foundation

/// Lightweight diagnostic log hook. Set `logHandler` from the app to receive pipeline logs.
public enum HKDiagnostics: Sendable {
    public nonisolated(unsafe) static var logHandler: (@Sendable (_ tag: String, _ message: String) -> Void)?

    public static func log(_ tag: String, _ message: String) {
        logHandler?(tag, message)
    }
}
