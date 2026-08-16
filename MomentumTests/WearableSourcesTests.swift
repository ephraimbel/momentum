import Testing
@testable import Momentum

/// The provenance mapping: a HealthKit source becomes a named device, or nothing — never a wrong
/// brand. The footnote's credibility rides on this being exact.
struct WearableSourcesTests {

    // MARK: Bundle-id identification (the stable path)

    @Test func knownCompanionAppsMapToTheirBrand() {
        let cases: [(bundle: String, name: String, expected: WearableKind)] = [
            ("com.ouraring.oura", "Oura", .oura),
            ("com.whoop.iphone", "WHOOP", .whoop),
            ("com.garmin.connect.mobile", "Connect", .garmin),
            ("com.yf.smart.coros.dist", "COROS", .coros),      // brand word only in the NAME
            ("fi.polar.polarflow", "Polar Flow", .polar),
            ("com.suunto.suuntoapp", "Suunto", .suunto),
            ("com.fitbit.FitbitMobile", "Fitbit", .fitbit),
            ("com.eightsleep.Eight", "Eight Sleep", .eightSleep),
            ("com.withings.wiScaleNG", "Withings", .withings),
        ]
        for c in cases {
            #expect(WearableKind.identify(bundleID: c.bundle, name: c.name) == c.expected,
                    "\(c.bundle) should map to \(c.expected)")
        }
    }

    // MARK: The Apple private source — Watch yes, iPhone no

    @Test func appleWatchIsIdentifiedByItsName() {
        // The Watch writes through the private health source; only the name carries "Apple Watch".
        #expect(WearableKind.identify(bundleID: "com.apple.health.7A44...F2", name: "Maya's Apple Watch") == .appleWatch)
        #expect(WearableKind.identify(bundleID: "com.apple.health", name: "Apple Watch") == .appleWatch)
    }

    @Test func theIPhoneItselfIsNotAWearable() {
        #expect(WearableKind.identify(bundleID: "com.apple.health.7A44...F2", name: "iPhone") == nil)
        #expect(WearableKind.identify(bundleID: "com.apple.health.7A44...F2", name: "Maya's iPhone") == nil)
        #expect(WearableKind.identify(bundleID: "com.apple.Health", name: "Health") == nil)
    }

    @Test func unknownSourcesDegradeToNothingNeverToAWrongBrand() {
        // A sleep app, our own app, an empty source — all nil, so the footnote stays generic.
        #expect(WearableKind.identify(bundleID: "com.autosleep.app", name: "AutoSleep") == nil)
        #expect(WearableKind.identify(bundleID: "com.ephraimbel.momentum.app", name: "Momentum") == nil)
        #expect(WearableKind.identify(bundleID: nil, name: nil) == nil)
    }

    @Test func identificationIsCaseInsensitive() {
        #expect(WearableKind.identify(bundleID: "COM.GARMIN.CONNECT.MOBILE", name: nil) == .garmin)
        #expect(WearableKind.identify(bundleID: nil, name: "OURA") == .oura)
    }

    // MARK: The sentence fragment

    @Test func phraseReadsNaturallyAtEveryCount() {
        #expect(WearableKind.phrase(for: []) == nil)
        #expect(WearableKind.phrase(for: [.oura]) == "your Oura ring")
        #expect(WearableKind.phrase(for: [.appleWatch, .garmin]) == "your Apple Watch and Garmin")
        #expect(WearableKind.phrase(for: [.oura, .whoop, .appleWatch])
                == "your Oura ring, Whoop, and Apple Watch")
    }
}
