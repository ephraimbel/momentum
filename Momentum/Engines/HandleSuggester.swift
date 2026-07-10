import Foundation

/// Deterministic @handle candidates for the onboarding identity step — the field should never be
/// empty, and when the obvious handle is taken the next options should be ready. Pure and seeded
/// so tests pin exact outputs; the UI passes a random seed so different athletes named "Maya"
/// don't all see the same digits.
enum HandleSuggester {

    /// Ordered candidates: the clean base first, then digit-suffixed variants. Base preference:
    /// normalized display name → email local-part → "athlete". Base is capped at 18 characters so
    /// two digits always fit inside the 20-char handle limit. Every candidate is normalized,
    /// non-reserved, non-empty, and unique.
    static func candidates(name: String, email: String?, seed: UInt64, count: Int = 4) -> [String] {
        let base = baseHandle(name: name, email: email)
        var rng = SplitMix64(seed: seed)
        var out: [String] = []
        var seen = Set<String>()

        func add(_ candidate: String) {
            let normalized = SocialPrivacy.normalizedHandle(candidate)
            guard !normalized.isEmpty,
                  !SocialPrivacy.isReservedHandle(normalized),
                  seen.insert(normalized).inserted else { return }
            out.append(normalized)
        }

        add(base)
        while out.count < count {
            add("\(base)\(rng.next() % 90 + 10)")   // two digits, 10–99
        }
        return out
    }

    /// The suffix-free base: name → email local-part → "athlete", trimmed to leave digit room.
    static func baseHandle(name: String, email: String?) -> String {
        let fromName = SocialPrivacy.normalizedHandle(name)
        if !fromName.isEmpty, !SocialPrivacy.isReservedHandle(fromName) {
            return String(fromName.prefix(18))
        }
        if let localPart = email?.split(separator: "@").first {
            let fromEmail = SocialPrivacy.normalizedHandle(String(localPart))
            if !fromEmail.isEmpty, !SocialPrivacy.isReservedHandle(fromEmail) {
                return String(fromEmail.prefix(18))
            }
        }
        return "athlete"
    }
}

/// SplitMix64 — tiny deterministic PRNG, independent of `SeededRNG` (which is tuned for the
/// community seeds and shouldn't grow extra call sites that change its stream).
private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
