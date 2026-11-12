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
        #expect(ads.pendingBeacons.inFlight == 1, "the beacon still out stays awaited")
        _ = try? await ads.format(.overlay)
        #expect(harness.adsRequests.count == 3, "the next request waits for it again, the cap at most, and goes")
        gate.open()
        #expect(await waitUntil { ads.pendingBeacons.inFlight == 0 }, "answered at last")
    }

    @Test func whatTheAppChangesDuringTheWaitIsWhatTheRequestSends() async throws {
        let ads = await makeAds()
        harness.serve(Fixtures.ad(id: "img-pb6"))
        let ad = try await ads.format(.pause)
        let gate = StubServer.Gate()
        defer { gate.open() }
        var held = StubServer.Response.empty()
        held.gate = gate
        harness.server.on("/events/img-pb6/notUsed", held)
        KontextVideo.shared.user = KontextVideo.User(id: "before", email: "a@b.test")
        ad.reject()
        let next = Task { try await ads.format(.pause) }
        #expect(await waitUntil { self.harness.server.beacons.contains { $0.event == "notUsed" } })
        KontextVideo.shared.user = KontextVideo.User(id: "after", email: "a@b.test")
        KontextVideo.shared.regulatory = KontextVideo.Regulatory(coppa: true)
        gate.open()
        _ = try? await next.value
        let user = try #require(harness.adsRequests.last?.body?["user"] as? [String: Any])
        #expect(user["id"] as? String == "after" && user["email"] == nil, "read after the wait: the new user, as a child")
        KontextVideo.shared.regulatory = nil
    }

    @Test func aUserClearedDuringTheWaitStopsTheRequest() async throws {
        let ads = await makeAds()
        harness.serve(Fixtures.ad(id: "img-pb7"))
        let ad = try await ads.format(.pause)
        let gate = StubServer.Gate()
        defer { gate.open() }
        var held = StubServer.Response.empty()
        held.gate = gate
        harness.server.on("/events/img-pb7/notUsed", held)
        ad.reject()
        let assertions = AssertionLog()
        let next = Task { try await ads.format(.pause) }
        #expect(await waitUntil { self.harness.server.beacons.contains { $0.event == "notUsed" } })
        KontextVideo.shared.user = nil
        gate.open()
        #expect(await error { try await next.value } == .request(.missingUser))
        #expect(harness.adsRequests.count == 1, "nothing sent")
        #expect(assertions.all.count == 1)
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
