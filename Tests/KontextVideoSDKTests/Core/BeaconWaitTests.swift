import Foundation
@testable import KontextVideoSDK
import Testing

/// The next ads request of a `VideoAds` waits for its outcome beacons (`notUsed`, `error`) still in flight, for
/// `PendingBeacons.maxWait` at most, so the server hears a bid's outcome before it answers again.
extension SerialSuites {
@Suite
@MainActor
struct BeaconWaitTests {
    private let harness = SDKHarness()
    private let pages = FramePageServer()

    init() {
        pages.install()
    }

    private func makeAds(content: String = "ep-1") async -> VideoAds {
        _ = await harness.initialize()
        return harness.player.ads(for: .init(id: content, language: "en"))
    }

    private func error<T>(_ work: () async throws -> T) async -> VideoAdError? {
        do {
            _ = try await work()
            Issue.record("expected a throw")
            return nil
        } catch let error as VideoAdError {
            return error
        } catch {
            Issue.record("unexpected \(error)")
            return nil
        }
    }

    @Test func theNextRequestWaitsForTheNotUsedBeaconOfAReject() async throws {
        let ads = await makeAds()
        harness.serve(Fixtures.ad(id: "img-pb1"))
        let ad = try await ads.format(.pause)
        let gate = StubServer.Gate()
        defer { gate.open() }
        var held = StubServer.Response.empty()
        held.gate = gate
        harness.server.on("/events/img-pb1/notUsed", held)
        ad.reject()
        harness.serve(Fixtures.ad(id: "img-pb2"))
        let next = Task { try await ads.format(.pause) }
        #expect(await waitUntil { self.harness.server.beacons.contains { $0.event == "notUsed" } })
        await sleepMs(150)
        #expect(harness.adsRequests.count == 1, "the server has not answered the beacon: the request waits")
        gate.open()
        #expect(try await next.value.id == "img-pb2")
        #expect(harness.adsRequests.count == 2)
    }

    @Test func aBeaconThatNeverAnswersHoldsTheRequestForTheCapOnly() async throws {
        PendingBeacons.maxWait = 0.3
        let ads = await makeAds()
        harness.serve(Fixtures.ad(id: "img-pb3"))
        let ad = try await ads.format(.pause)
        let gate = StubServer.Gate()
        defer { gate.open() }
        var dead = StubServer.Response.empty()
        dead.gate = gate
        harness.server.on("/events/img-pb3/notUsed", dead)
        ad.reject()
        harness.serve(Fixtures.ad(id: "img-pb4"))
        #expect(try await ads.format(.pause).id == "img-pb4", "requested anyway once the cap passed")
        #expect(ads.pendingBeacons.inFlight == 0, "the beacon still out is no longer awaited")
        PendingBeacons.maxWait = 60
        harness.serve(Fixtures.ad(id: "img-pb4b"))
        let started = Date()
        _ = try? await ads.format(.overlay)
        #expect(Date().timeIntervalSince(started) < 30, "the next request does not wait for it again")
        #expect(harness.adsRequests.count == 3)
    }

    @Test func destroyDuringTheWaitEndsItAtOnce() async throws {
        let ads = await makeAds()
        harness.serve(Fixtures.ad(id: "img-pb5"))
        let ad = try await ads.format(.pause)
        let gate = StubServer.Gate()
        defer { gate.open() }
        var held = StubServer.Response.empty()
        held.gate = gate
        harness.server.on("/events/img-pb5/notUsed", held)
        ad.reject()
        let next = Task { try await ads.format(.pause) }
        #expect(await waitUntil { self.harness.server.beacons.contains { $0.event == "notUsed" } })
        ads.destroy()
        #expect(await error { try await next.value } == .destroyed)
        #expect(harness.adsRequests.count == 1, "nothing sent")
    }
}
}
