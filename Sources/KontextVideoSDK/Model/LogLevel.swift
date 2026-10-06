/// How much the SDK prints to the device console.
public enum LogLevel: Sendable {
    /// Silent.
    case none
    /// Only errors.
    case error
    /// Errors and warnings.
    case warning
    /// Errors, warnings and other useful information.
    case info
    /// Detailed information about each step.
    case debug
}
