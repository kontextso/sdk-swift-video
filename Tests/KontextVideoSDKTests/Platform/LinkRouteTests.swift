import Foundation
@testable import KontextVideoSDK
import Testing

/// Where a link goes, as a table: an app's own scheme, the App Store by scheme or by web host, and every other web
/// link.
@Suite
struct LinkRouteTests {
    @Test(arguments: [
        ("brandapp://offer", LinkRoute.app),
        ("hostapp://premium", .app),
        ("BrandApp://offer", .app),
        ("itms-apps://apps.apple.com/app/id1", .store),
        ("ITMS-APPSS://itunes.apple.com/app/id1", .store),
        ("https://apps.apple.com/us/app/id1", .store),
        ("http://itunes.apple.com/app/id1", .store),
        ("https://geo.itunes.apple.com/app/id1", .store),
        ("https://APPS.APPLE.COM/app/id1", .store),
        ("https://brand.test/offer", .web),
        ("http://brand.test", .web),
        ("HTTPS://brand.test", .web),
        ("https://ads.test/r?to=https://apps.apple.com/app/id1", .web),
        ("https://notapps.apple.com.brand.test/app", .web),
        ("https://apple.com/app", .web),
    ])
    func route(_ raw: String, _ expected: LinkRoute) throws {
        #expect(LinkRoute(try #require(URL(string: raw))) == expected, "\(raw)")
    }
}
