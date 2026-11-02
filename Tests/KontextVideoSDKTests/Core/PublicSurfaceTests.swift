import KontextVideoSDK
import Testing

/// What an app can do with the SDK's public API alone: no `@testable` here, so this file sees only what an
/// app sees.
@MainActor
struct PublicSurfaceTests {
    @Test func anAppCanMakeThePricesAndClicksItsOwnTestsNeed() {
        let price = VideoAd.Price(value: 2.5, currency: "USD", precision: .estimated)
        #expect(price.value >= 2 && price.currency == "USD" && price.precision == .estimated)
        #expect(VideoAd.Click(area: .endCard).area == .endCard)
    }
}
