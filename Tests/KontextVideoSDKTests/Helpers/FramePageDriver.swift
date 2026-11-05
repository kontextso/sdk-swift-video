import Foundation
@testable import KontextVideoSDK

/// What a page's messages do, without a WebView: a `FrameProtocol` behind the same calls as `FrameBridge`
/// (`receive`, `show`, `hide`, `noteTouch`, `externalNavigation`), each step carried out as the bridge carries it
/// out (`loaded` and `deliver` reach `onEvent`, `endThenDeliver` ends the page first, a drop reaches nothing).
///
/// Why: every `FrameBridge` owns a WKWebView, and WebKit launches a web content process for it. Tests of the
/// protocol's rules built a hundred bridges in a few seconds; on a CI runner that burst of process launches
/// stalled the suites after it that load real pages, past their load limit. The rules are tested here, and
/// `FrameBridgeTests` keeps the bridge's own carrying out of the steps under test.
@MainActor
final class FramePageDriver {
    private(set) var frameProtocol: FrameProtocol
    var state: PageState { frameProtocol.state }
    var onEvent: ((FrameEvent) -> Void)?
    /// The clock a touch is measured on, as `Environment.now` is the bridge's; a test moves it.
    var now: TimeInterval = 1000

    init(adId: String = "ad-1", url: URL = URL(string: "https://server.kontext.so/frame/ad-1")!, isVideo: Bool = false,
         videoDuration: TimeInterval? = nil) {
        frameProtocol = FrameProtocol(adId: adId, pageURL: url, isVideo: isVideo, videoDuration: videoDuration)
    }

    func receive(_ rawBody: Any, from sender: FrameProtocol.Sender) {
        switch frameProtocol.accept(rawBody, from: sender, now: now) {
        case .ignore, .drop:
            return
        case .loaded:
            onEvent?(.loaded)
        case .deliver(let event):
            onEvent?(event)
        case .endThenDeliver(let event):
            _ = frameProtocol.end()
            onEvent?(event)
        }
    }

    func show(size _: VideoAd.Size? = nil) {
        _ = frameProtocol.show()
    }

    func hide() {
        _ = frameProtocol.end()
    }

    func noteTouch() {
        frameProtocol.noteTouch(now: now)
    }

    func externalNavigation(to target: URL) {
        guard let click = frameProtocol.externalNavigation(to: target, now: now) else { return }
        onEvent?(click)
    }
}

/// The calls a page's messages go through, the bridge's and the driver's alike, so one test can run on either.
@MainActor
protocol FramePage: AnyObject {
    var state: PageState { get }
    var onEvent: ((FrameEvent) -> Void)? { get set }
    func receive(_ rawBody: Any, from sender: FrameProtocol.Sender)
    func show(size: VideoAd.Size?)
    func hide()
    func noteTouch()
}

extension FrameBridge: FramePage {}
extension FramePageDriver: FramePage {}
