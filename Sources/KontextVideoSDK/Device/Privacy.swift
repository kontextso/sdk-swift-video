import AdSupport
import AppTrackingTransparency
import Foundation
import KontextKit

/// The advertising identifier, as the request carries it. Sent only when the IDFA is real: with ATT
/// `authorized` the OS gives the id, in every other state it gives all zeros. Zeros are not sent as an
/// empty id with a flag, the object is omitted, which is what the IAB's iOS 14 guidance and every
/// exchange expect (buyers key on the absence of `ifa`); `attStatus` carries the reason, and the server
/// derives OpenRTB `device.ext.atts` and `lmt` (1 unless authorized) from it, never from this object.
struct IFA: Encodable, Sendable {
    let id: String
    // Read by the synthesized encoder only. swiftlint:disable:next unused_declaration
    let type = "idfa"
    /// Never `true` on iOS: since iOS 10 an opted-out device returns no id at all, so an id is always one
    /// that may be used. Kept because the shared `IFA` type serves platforms that hand out an id together
    /// with a limit flag (Android before 12, Roku, Fire TV, Samsung and LG TVs), where the id still works
    /// for frequency capping and fraud but not for targeting.
    // swiftlint:disable:next unused_declaration
    let limitAdTracking = false
}

/// What the request says about tracking: the ATT status and, when authorized, the IDFA.
struct TrackingInfo: Sendable {
    let ifa: IFA?
    /// `authorized`, `denied`, `notDetermined`, `restricted`; `device.ext.atts` on the demand side.
    let attStatus: String

    init(ifa: IFA?, status: ATTrackingManager.AuthorizationStatus) {
        self.ifa = ifa
        attStatus = Self.name(of: status)
    }

    /// The dialog in progress, shared: two requests at once (this episode's and the prefetched next one's)
    /// ask Apple once and both get the viewer's answer. Apple does not keep a second request made while
    /// the dialog is up. Cleared when the dialog closes; the OS stays the authority on the status.
    @MainActor
    private static var authorization: Task<ATTrackingManager.AuthorizationStatus, Never>?

    /// Reads the current state. With `requestAuthorization`, shows the App Tracking Transparency dialog
    /// first when the user has not answered yet (the app's Info.plist needs `NSUserTrackingUsageDescription`).
    @MainActor
    static func current(requestAuthorization: Bool) async -> TrackingInfo {
        var status = Environment.trackingAuthorizationStatus()
        if requestAuthorization, status == .notDetermined {
            let task = authorization ?? Task {
                defer { authorization = nil }
                return await Environment.requestTrackingAuthorization()
            }
            authorization = task
            status = await task.value
            Logger.info("ATT: \(name(of: status))")
        }
        var ifa: IFA?
        if status == .authorized {
            let id = ASIdentifierManager.shared().advertisingIdentifier.uuidString
            if id != "00000000-0000-0000-0000-000000000000" {
                ifa = IFA(id: id)
            }
        }
        return TrackingInfo(ifa: ifa, status: status)
    }

    private static func name(of status: ATTrackingManager.AuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "notDetermined"
        }
    }
}

/// The consent signals a consent management platform writes to `UserDefaults` under the IAB's shared
/// keys (TCF v2, GPP, US Privacy), read by KontextKit's `ConsentDataProvider`. The CMP's values win:
/// they are the live, authoritative consent, as AdMob and MAX read them with no override at all. What
/// the publisher set on `KontextVideo.shared.regulatory` fills in what the CMP did not write (a
/// publisher without an IAB-writing CMP passes consent by hand); `coppa` can only come from the publisher.
enum ConsentStorage {
    @MainActor
    static func read(merging explicit: KontextVideo.Regulatory?, defaults: UserDefaults? = nil) -> KontextVideo.Regulatory? {
        let stored = ConsentDataProvider.collect(from: defaults ?? Environment.consentDefaults)
        let merged = KontextVideo.Regulatory(
            gdpr: stored.gdpr.map { $0 == 1 } ?? explicit?.gdpr,
            gdprConsent: stored.gdprConsent ?? explicit?.gdprConsent,
            coppa: explicit?.coppa,
            gpp: stored.gpp ?? explicit?.gpp,
            gppSid: stored.gppSid ?? explicit?.gppSid,
            usPrivacy: stored.usPrivacy ?? explicit?.usPrivacy
        )
        let isEmpty = merged.gdpr == nil && merged.gdprConsent == nil && merged.coppa == nil && merged.gpp == nil && merged.gppSid == nil && merged.usPrivacy == nil
        return isEmpty ? nil : merged
    }
}
