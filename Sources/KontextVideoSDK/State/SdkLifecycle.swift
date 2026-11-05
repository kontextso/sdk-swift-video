/// The rules of the SDK's own life, and nothing else: the legal moves between its phases (the public
/// `KontextVideo.State`). Stateless: it holds no fact (`SdkState` does) and only answers whether a move is legal.
/// No UIKit, no effects.
///
/// ```
///                   initialize               /config: enabled
///   notInitialized ───────────▶ initializing ───────────────────▶ enabled
///                                 │      ▲  │                        │
///                 /config failed  ▼      │  │ /config: disabled      │ an ads answer's kill switch
///                               failed ──┘  ▼                        ▼
///                           the next ads    disabled ◀───────────────┘
///                           request           ▲  └─┐ another answer's kill switch, another reason
///                                             └────┘
/// ```
///
/// `disabled` is final but for its reason: no `/config` follows it, and a second `initialize` is ignored in every
/// phase but `notInitialized`. `failed` moves only back to `initializing`: the kill switch arrives in an ads
/// answer, and no ads request leaves while `/config` has not enabled the SDK.
enum SdkLifecycle {
    /// Whether `from` may move to `to`: not initialized → initializing; initializing → enabled, disabled or
    /// failed (`/config`'s answer); failed → initializing (the retry); enabled → disabled (the kill switch);
    /// disabled → disabled with another reason. Anything else is refused.
    static func canMove(from: KontextVideo.State, to: KontextVideo.State) -> Bool {
        switch (from, to) {
        case (.notInitialized, .initializing),
             (.initializing, .enabled), (.initializing, .disabled), (.initializing, .failed),
             (.failed, .initializing),
             (.enabled, .disabled):
            true
        case (.disabled, .disabled):
            to != from
        default:
            false
        }
    }
}
