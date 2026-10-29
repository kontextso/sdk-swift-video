import Foundation
@testable import KontextVideoSDK
import Testing
import UIKit

/// The smaller public pieces: error descriptions, delegate defaults, formats. Serialized: it resets the
/// shared instance and the stub server, which other suites are using.
extension SerialSuites {
@Suite
@MainActor
struct SupportTests {
    // MARK: VideoAdError

    @Test func anAppWithoutScenesFindsItsWindowOnTheAppDelegate() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(Environment.keyWindow(scenes: [], delegateWindow: window) === window)
        #expect(Environment.keyWindow(scenes: [], delegateWindow: nil) == nil)
    }

    @Test func theKeyWindowComesFromTheActiveSceneThenAnInactiveOneNeverABackgroundOne() {
        let make = { UIWindow(frame: CGRect(x: 0, y: 0, width: 10, height: 10)) }
        let (active, inactive, background, delegate, plain) = (make(), make(), make(), make(), make())
        let keys: Set<ObjectIdentifier> = [ObjectIdentifier(active), ObjectIdentifier(inactive), ObjectIdentifier(background)]
        let isKey = { (window: UIWindow) in keys.contains(ObjectIdentifier(window)) }
        // Listed in an order that puts the wrong answers first.
        let all: [(state: UIScene.ActivationState, windows: [UIWindow])] = [(.background, [background]), (.foregroundInactive, [plain, inactive]), (.foregroundActive, [active])]
        #expect(Environment.keyWindow(scenes: all, delegateWindow: delegate, isKey: isKey) === active, "the scene receiving events first")
        #expect(Environment.keyWindow(scenes: Array(all.dropLast()), delegateWindow: delegate, isKey: isKey) === inactive, "then a foreground inactive one, its key window")
        #expect(Environment.keyWindow(scenes: [(.background, [background])], delegateWindow: delegate, isKey: isKey) == nil, "never a background scene, and not the delegate's while scenes exist")
        #expect(Environment.keyWindow(scenes: [(.foregroundActive, [plain])], delegateWindow: delegate, isKey: isKey) == nil, "an active scene without a key window gives none")
    }

    @Test func aWindowIsActiveOnlyWhenTheAppAndItsOwnSceneAre() {
        let cases: [(app: Bool, scene: UIScene.ActivationState?, active: Bool, why: String)] = [
            (true, .foregroundActive, true, "both active"),
            (true, .foregroundInactive, false, "the ad's scene inactive while the app is active (iPad)"),
            (true, .background, false, "the ad's scene in the background"),
            (false, .foregroundActive, false, "an inactive app shows nothing"),
            (true, nil, true, "a window without a scene follows the app"),
            (false, nil, false, "and so when the app is not active"),
        ]
        for item in cases {
            let active = Environment.isWindowActive(appActive: item.app, sceneState: item.scene)
            #expect(active == item.active, "\(item.why)")
        }
        // The hook uses the same rule with the live values.
        let window = TestWindow().window
        defer { Environment.reset() }
        Environment.isApplicationActive = { false }
        #expect(!Environment.isWindowActive(window))
    }

    // MARK: awaitShared

    /// Lets a test hold shared work open until it says so.
    final class Gate {
        var open = false
    }

    private struct Boom: Error {}

    @Test func awaitSharedGivesEveryWaiterTheSameResultEvenWhenTheWorkIsAlreadyDone() async throws {
        let done = Task<Int, Error> { 7 }
        _ = try await done.value
        #expect(try await awaitShared(done) == 7)
        #expect(try await awaitShared(done) == 7, "a finished task answers every later waiter")
        let failed = Task<Int, Error> { throw Boom() }
        await #expect(throws: Boom.self) { try await awaitShared(failed) }
        await #expect(throws: Boom.self) { try await awaitShared(failed) }
    }

    @Test func awaitSharedSharesAFailureAmongItsWaiters() async {
        let gate = Gate()
        let work = Task<Int, Error> { @MainActor in
            while !gate.open { try await Task.sleep(nanoseconds: 5_000_000) }
            throw Boom()
        }
        let first = Task { try await awaitShared(work) }
        let second = Task { try await awaitShared(work) }
        gate.open = true
        for waiter in [first, second] {
            await #expect(throws: Boom.self) { try await waiter.value }
        }
    }

    @Test func aCallerCancelledBeforeItWaitsStopsAtOnce() async throws {
        let gate = Gate()
        defer { gate.open = true }
        let work = Task<Int, Error> { @MainActor in
            while !gate.open { try await Task.sleep(nanoseconds: 5_000_000) }
            return 1
        }
        let waiter = Task { () throws -> Int in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await awaitShared(work)
        }
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(!gate.open && !work.isCancelled, "the work was neither finished nor cancelled")
    }

    @Test func oneCancelledWaiterLeavesTheOthersWaiting() async throws {
        let gate = Gate()
        let work = Task<Int, Error> { @MainActor in
            while !gate.open { try await Task.sleep(nanoseconds: 5_000_000) }
            return 42
        }
        let cancelled = Task { try await awaitShared(work) }
        let kept = Task { try await awaitShared(work) }
        await sleepMs(20)
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(!gate.open, "it stopped before the work finished")
        gate.open = true
        #expect(try await kept.value == 42)
        #expect(!work.isCancelled)
    }

    @Test func cancellationRacingCompletionResumesOnce() async {
        // Many rounds of cancel and finish at the same moment: each waiter ends exactly once, with either
        // the value or a cancellation, never twice (a double resume would trap).
        for _ in 0..<50 {
            let gate = Gate()
            let work = Task<Int, Error> { @MainActor in
                while !gate.open { await Task.yield() }
                return 1
            }
            let waiter = Task { try await awaitShared(work) }
            await Task.yield()
            gate.open = true
            waiter.cancel()
            let result = await waiter.result
            switch result {
            case .success(let value): #expect(value == 1)
            case .failure(let error): #expect(error is CancellationError)
            }
        }
    }

    @Test func aDisabledLevelNeverBuildsItsMessage() {
        let previous = Logger.level
        defer { Logger.level = previous }
        var built = 0
        func message() -> String { built += 1; return "m" }
        Logger.level = .warning
        Logger.debug(message())
        Logger.info(message())
        #expect(built == 0, "debug and info are off at .warning")
        Logger.warning(message())
        #expect(built == 1)
        Logger.level = .none
        Logger.error(message())
        #expect(built == 1, ".none builds nothing")
    }

    @Test func aURLIsLoggedAsItsSchemeAndHostOnly() {
        #expect(Logger.describe(URL(string: "https://brand.test/offer?uid=42&sig=abc")!) == "https://brand.test")
        #expect(Logger.describe(URL(string: "brandapp://offer/7?token=x")!) == "brandapp://offer")
        #expect(Logger.describe(URL(string: "mailto:viewer@example.com")!) == "mailto:")
        #expect(Logger.describe(URL(string: "javascript:alert(document.cookie)")!) == "javascript:")
        #expect(Logger.describe(URL(string: "relative/path")!) == "(no scheme)")
    }

    @Test func everyErrorReadsAsASentence() {
        let cases: [(VideoAdError, String)] = [
            (.notInitialized, "KontextVideo.shared.initialize(with:) was not called"),
            (.initializationFailed, "/config failed, and retrying it failed too; no ads until it succeeds"),
            (.destroyed, "the VideoAds was destroyed"),
            (.disabled(reason: "publisherDisabled"), "the SDK is disabled by the server (publisherDisabled)"),
            (.noFill(reason: .noAdMatch), "no fill (noAdMatch)"),
            (.noFill(reason: .other("brandNew")), "no fill (brandNew)"),
            (.anotherAdShowing, "another ad is on screen; show this one after it ended"),
            (.creativeFailed(code: 400), "the creative failed to load (VAST error 400)"),
            (.alreadyShown, "the ad was already shown"),
            (.invalidated(.expired), "the ad ended before it was shown (expired)"),
            (.notLoaded, "the ad is not loaded yet; call load() first"),
            (.containerTooSmall(minimum: CGSize(width: 150, height: 150)), "the view is too small for the ad; at least 150×150 points are needed"),
            (.presenterUnavailable, "no view controller can present the ad now"),
            (.wrongPresentation, "this call does not fit the ad's format (show(in:) for overlay and pause, show() for linear; dismiss() only for overlay and pause)"),
        ]
        for (error, expected) in cases {
            #expect(error.description == expected)
            #expect(error.errorDescription == expected)
            #expect("\(error)" == expected, "string interpolation uses the description")
        }
        let request = VideoAdError.request(URLError(.timedOut))
        #expect(request.description.hasPrefix("request failed: "))
    }

    // MARK: VideoAdDelegate

    @Test func delegateMethodsAllHaveDefaults() async throws {
        final class Minimal: VideoAdDelegate {}
        let delegate = Minimal()
        Environment.assertionFailure = { _ in }
        defer { Environment.reset() }
        let ads = VideoAds(content: .init(id: "v", language: "en"))
        let ad = VideoAd(descriptor: try Fixtures.descriptor(Fixtures.ad(id: "d1")), owner: ads)
        delegate.videoAdDidRecordImpression(ad)
        delegate.videoAd(ad, didClick: VideoAd.Click(url: URL(string: "https://x.test")!, area: .creative))
        delegate.videoAd(ad, didFail: .presenterUnavailable)
        delegate.videoAd(ad, didEnd: .completed)
    }

    @Test func delegateIsHeldWeakly() async throws {
        Environment.assertionFailure = { _ in }
        defer { Environment.reset() }
        let ads = VideoAds(content: .init(id: "v", language: "en"))
        let ad = VideoAd(descriptor: try Fixtures.descriptor(Fixtures.ad(id: "d2")), owner: ads)
        var delegate: RecordingDelegate? = RecordingDelegate()
        ad.delegate = delegate
        #expect(ad.delegate != nil)
        delegate = nil
        #expect(ad.delegate == nil)
    }

    @Test func endReasonsAndClicksAreEquatable() {
        #expect(VideoAd.EndReason.completed == .completed)
        #expect(VideoAd.EndReason.completed != .dismissed)
        let url = URL(string: "https://x.test")!
        #expect(VideoAd.Click(url: url, area: .creative) == VideoAd.Click(url: url, area: .creative))
        #expect(VideoAd.Click(url: url, area: .creative) != VideoAd.Click(url: url, area: .other("creative")), "the page's label 'creative' is the creative, but the enum is honest about what it was given")
        #expect(VideoAd.Click.Area(nil) == .creative && VideoAd.Click.Area("endCard") == .endCard && VideoAd.Click.Area("cta") == .other("cta"))
        #expect(VideoAd.InvalidationReason.creativeFailed(code: 1) != .creativeFailed(code: 2))
        #expect(VideoAd.RejectReason.outbid(winningPrice: 2) != .outbid())
        #expect(VideoAd.RejectReason.notUsed == .notUsed)
    }

    // MARK: Formats

    @Test func everyFormatThrowsNotInitializedBeforeInitialize() async {
        SDKHarness.reset()
        Environment.assertionFailure = { _ in }
        let ads = TestPlayer().ads(for: .init(id: "v", language: "en"))
        for format in AdFormat.allCases {
            let work = { _ = try await ads.format(format) }
            do {
                try await work()
                Issue.record("expected notInitialized")
            } catch VideoAdError.notInitialized {
            } catch {
                Issue.record("unexpected \(error)")
            }
        }
        SDKHarness.reset()
    }

    // MARK: Logger

    @Test func loggerLevelIsSettable() {
        Logger.level = .debug
        #expect(Logger.level == .debug)
        Logger.level = .none
        #expect(Logger.level == .none)
        Logger.level = .warning
    }
}
}
