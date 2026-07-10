import Testing
import Foundation
@testable import Momentum

/// Handle suggestions (onboarding identity step): deterministic, valid, never reserved.
struct HandleSuggesterTests {

    @Test func sameSeedIsDeterministic() {
        let a = HandleSuggester.candidates(name: "Maya Rivera", email: nil, seed: 42)
        let b = HandleSuggester.candidates(name: "Maya Rivera", email: nil, seed: 42)
        #expect(a == b)
        #expect(a.first == "mayarivera")             // clean base leads
        #expect(a.count == 4)
    }

    @Test func differentSeedsVaryTheDigits() {
        let a = HandleSuggester.candidates(name: "Maya", email: nil, seed: 1)
        let b = HandleSuggester.candidates(name: "Maya", email: nil, seed: 2)
        #expect(a.first == b.first)                  // base is seed-independent
        #expect(a != b)                              // suffixed variants differ
    }

    @Test func emailLocalPartIsTheFallback() {
        let c = HandleSuggester.candidates(name: "", email: "ephraim.invests@gmail.com", seed: 7)
        #expect(c.first == "ephraiminvests")         // dots stripped by normalization
    }

    @Test func athleteIsTheLastResort() {
        // Emoji-only name + no email → nothing normalizable → "athlete" base. The bare word is
        // itself reserved, so every candidate is a digit variant (athlete42, never @athlete).
        let c = HandleSuggester.candidates(name: "🏃🔥", email: nil, seed: 7)
        #expect(!c.isEmpty)
        #expect(c.allSatisfy { $0.hasPrefix("athlete") && $0 != "athlete" })
    }

    @Test func candidatesFitTheHandleRules() {
        let long = HandleSuggester.candidates(name: "Bartholomew Montgomery-Fitzgerald III", email: nil, seed: 3)
        for candidate in long {
            #expect(candidate.count <= 20)
            #expect(candidate == SocialPrivacy.normalizedHandle(candidate))   // already normalized
            #expect(!SocialPrivacy.isReservedHandle(candidate))
        }
        #expect(Set(long).count == long.count)       // no duplicates
    }

    @Test func reservedNamesNeverLeadTheList() {
        // Someone literally named "Admin" gets digit variants, never the bare reserved word.
        let c = HandleSuggester.candidates(name: "Admin", email: nil, seed: 9)
        #expect(!c.contains("admin"))
        #expect(c.allSatisfy { !SocialPrivacy.isReservedHandle($0) })
    }
}
