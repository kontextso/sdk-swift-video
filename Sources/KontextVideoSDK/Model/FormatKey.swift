import Foundation

/// The key `VideoAds.format(_:options:)` takes: a format, carrying its options type so `options` is
/// typed. `.overlay`, `.pause`, `.linear`; a named ad unit of a format can be added here later.
public struct FormatKey<Options: AdOptions>: Sendable {
    let format: AdFormat
}

public extension FormatKey where Options == OverlayOptions {
    static var overlay: FormatKey { FormatKey(format: .overlay) }
}

public extension FormatKey where Options == PauseOptions {
    static var pause: FormatKey { FormatKey(format: .pause) }
}

public extension FormatKey where Options == LinearOptions {
    static var linear: FormatKey { FormatKey(format: .linear) }
}

/// The options of one format, as `VideoAds.format(_:options:)` and the `formats` declaration take them.
public protocol AdOptions: Encodable, Sendable {
    /// The format these options belong to; the loader sends it with them.
    static var format: AdFormat { get }
    /// Every option left to its default.
    static var `default`: Self { get }
    /// These options as a request for their format.
    var request: FormatRequest { get }
}
