/// One source of truth: the one place every fact of the SDK's own life lives (where it is, the configuration it
/// was initialized with, what `/config` said of the reports), and the only way those facts change. Everyone else
/// asks it: `KontextVideo.state`, `isInitialized` and `disabledReason`, the error and debug reporters. The data
/// only: which moves are legal is `SdkLifecycle`'s rule, which `moveTo(_:)` asks. No UIKit, no effects;
/// `KontextVideo` acts on it (the shell: `/config`, its retry, the reporters).
struct SdkState {
    /// Where the SDK is now, as `KontextVideo.state` shows it. It moves only through `moveTo(_:)`.
    private(set) var phase = KontextVideo.State.notInitialized

    /// What `initialize(with:)` was given, recorded once by `recordConfiguration(_:)`.
    private(set) var configuration: KontextVideo.Configuration?

    /// What `/config` said of error reports (`reportErrors`): `nil` until it answers (the reports wait in
    /// memory), then on or off. Off is final for the launch. Set by `recordErrorReporting(_:)`.
    ///
    /// Not derived from the phase: a failed `/config` is not `initializing`, yet the reports still wait.
    private(set) var isErrorReportingOn: Bool?

    /// What `/config` said of debug events (`reportDebug`); off until it answers. Set by `recordDebugReporting(_:)`.
    private(set) var isDebugReportingOn = false

    /// `initialize(with:)` was called: the phase left `notInitialized`, never to return.
    var isInitialized: Bool { phase != .notInitialized }

    /// The server's reason while the SDK is switched off, else `nil`.
    var disabledReason: String? {
        if case .disabled(let reason) = phase { return reason }
        return nil
    }

    /// Moves to `next` when `SdkLifecycle.canMove(from:to:)` allows it, and says whether it did; a refused move
    /// changes nothing.
    @discardableResult
    mutating func moveTo(_ next: KontextVideo.State) -> Bool {
        guard SdkLifecycle.canMove(from: phase, to: next) else { return false }
        phase = next
        return true
    }

    /// The configuration `initialize(with:)` was given. Once; never replaced.
    mutating func recordConfiguration(_ configuration: KontextVideo.Configuration) {
        if self.configuration == nil { self.configuration = configuration }
    }

    /// `/config`'s `reportErrors`. An off stays off: nothing turns the reports back on in this launch.
    mutating func recordErrorReporting(_ isOn: Bool) {
        guard isErrorReportingOn != false else { return }
        isErrorReportingOn = isOn
    }

    /// `/config`'s `reportDebug`.
    mutating func recordDebugReporting(_ isOn: Bool) {
        isDebugReportingOn = isOn
    }
}
