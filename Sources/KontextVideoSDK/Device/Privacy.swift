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
    /// that may be used. Sent because the API's `ifa` object has the field: other platforms' SDKs hand out
    /// an id together with a limit flag (Android before 12, Roku, Fire TV, Samsung and LG TVs).
    let limitAdTracking = false // swiftlint:disable:this unused_declaration
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
    private static var authorization: Task<ATTrackingManager.AuthorizationStatus, Error>?
    /// The app was told once that it never asked for tracking authorization; once per launch is enough.
    @MainActor static var warnedAboutUnaskedTracking = false

    /// Reads the current state. With `requestAuthorization`, first requests App Tracking Transparency
    /// authorization when the viewer has not answered yet (the app's Info.plist needs
    /// `NSUserTrackingUsageDescription`). Apple decides whether the dialog appears: not while the app is
    /// inactive or another permission dialog is up. The status then stays undetermined and a later request
    /// asks again. Throws `CancellationError` when the calling task is cancelled while the dialog is up
    /// (`destroy()` of its `VideoAds`); the dialog itself, and every other caller waiting on it, go on.
    @MainActor
    static func current(requestAuthorization: Bool) async throws -> TrackingInfo {
        var status = Environment.trackingAuthorizationStatus()
        if requestAuthorization, status == .notDetermined {
            let task = authorization ?? Task {
                defer { authorization = nil }
                return await Environment.requestTrackingAuthorization()
            }
            authorization = task
            status = try await awaitShared(task)
            Logger.info("ATT: \(name(of: status))")
        } else if status == .notDetermined, !warnedAboutUnaskedTracking {
            // A publisher who forgot both their own dialog and the SDK's option sends every request without
            // the IDFA; said once, at the first request, where a developer looks.
            warnedAboutUnaskedTracking = true
            Logger.warning("App Tracking Transparency not answered yet: the IDFA is not sent until the app asks, or set requestTrackingAuthorization: true.")
        }
        var ifa: IFA?
        if status == .authorized {
            let id = Environment.advertisingIdentifier().uuidString
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
/// keys (TCF v2, GPP, US Privacy), read by KontextKit's `ConsentDataProvider`. A usable CMP value
/// wins: it is the live, authoritative consent, as major ad SDKs read it, with no override at all. What
/// the publisher set on `KontextVideo.shared.regulatory` fills in where the CMP has none usable (a key it
/// did not write, an empty or malformed one); `coppa` can only come from the publisher.
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
