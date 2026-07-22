import Foundation

/// The canonical key for a meal's typed text — the whole basis of local-first meal resolution
/// (FUEL-FLOW §1.5). A pure `String -> String` function: no SwiftData, no I/O, no locale drift,
/// trivially unit-testable, exactly like `FuelTips` and every other engine.
///
/// **The governing bias is PRECISION, not recall.** A missed match costs one cheap API call; a
/// WRONG match silently writes someone else's nutrition into the athlete's day and is never
/// noticed. Every rule below is chosen so the algorithm can only ever *fail to merge* two texts —
/// never merge two texts that mean different food or different amounts.
///
/// The key is computed on demand and NEVER persisted, so the algorithm can change freely without
/// a migration or a backfill.
enum MealTextKey {

    /// Bumped whenever the algorithm changes. Nothing depends on it at runtime (keys aren't
    /// stored); it exists so tests can pin the contract they were written against.
    ///
    /// v2 (2026-07-21): separators flanked by digits are read as part of the NUMBER, not as food
    /// boundaries — see `numberInternalSeparators`. v1 split "1/2 tbsp butter" into "1" plus
    /// "2 tbsp butter", inverting the fraction and letting the denominator sort onto another food.
    static let version = 2

    // MARK: Tables

    /// Characters that end one FOOD and begin the next.
    ///
    /// Splitting here — rather than sorting bare tokens — is THE precision guard. Sorting tokens
    /// would make "2 eggs, 1 slice toast" and "1 egg, 2 slices toast" the same multiset. Sorting
    /// *segments* keeps every quantity welded to the food it counts.
    private static let segmentBreakers: Set<Character> = [
        ",", ";", ":", ".", "!", "?", "\n", "\r",
        "+", "&", "/", "|", "\u{00B7}", "\u{2022}", "\u{2013}", "\u{2014}",
    ]

    /// Characters that end a WORD but not a food ("peanut-butter" is one food, two words).
    private static let tokenBreakers: Set<Character> = [
        "-", "_", "(", ")", "[", "]", "{", "}", "\"", "\u{201C}", "\u{201D}",
        "*", "=", "<", ">", "\\", "~",
    ]

    /// Deleted outright rather than split on, so "reese's" and "reeses" are the same food.
    private static let apostrophes: Set<Character> = ["'", "\u{2019}", "\u{2018}", "`", "\u{00B4}"]

    /// Separators that live INSIDE a number when digits flank them: the decimal point of
    /// "1.5 cups", the solidus of "1/2 tbsp butter", the ratio colon of "2:1 carb drink".
    ///
    /// Every one of these is also a `segmentBreaker`, and that collision is what made v1 unsafe:
    /// breaking on the slash turned "1/2 cup oats" into the segments ["1", "2 cup oats"] — the
    /// numerator orphaned, the DENOMINATOR promoted to the leading token of the next segment, and
    /// the whole key asserting *two* cups. Worse, `segments.sorted()` then let that orphan drift,
    /// so "1/2 tbsp butter, 2 tbsp jam" and "1/2 tbsp jam, 2 tbsp butter" collapsed to one key —
    /// the exact quantity-drift false positive `quantityStaysBound` exists to make impossible.
    /// Reading them as number content is what makes "numerals survive verbatim" literally true.
    private static let numberInternalSeparators: Set<Character> = [".", "/", ":"]

    /// Words that JOIN foods rather than name one — treated exactly like a comma. ("w" catches
    /// the "toast w/ butter" shorthand, whose slash would otherwise strand a lone "w" token.)
    private static let joinerWords: Set<String> = ["and", "with", "w", "plus"]

    /// Words carrying no food identity. Dropped INSIDE a segment.
    private static let fillerWords: Set<String> = ["a", "an", "the", "of", "some", "my"]

    /// "two eggs" and "2 eggs" are the same breakfast. A closed, unambiguous cardinal table: no
    /// food is named "three", so this can only ever merge texts that mean the SAME count — it
    /// cannot manufacture a false positive.
    ///
    /// Deliberately excludes "half", "couple", "few", "lots": ambiguous quantities stay unmatched.
    private static let numberWords: [String: String] = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5",
        "six": "6", "seven": "7", "eight": "8", "nine": "9", "ten": "10",
        "eleven": "11", "twelve": "12", "dozen": "12",
    ]

    // MARK: The key

    /// The canonical key, or `""` when the text carries no matchable content. **An empty key must
    /// never be looked up** — it is the "I have nothing to say about this" answer, and matching on
    /// it would join every unmatchable meal into one bucket.
    ///
    /// Invariants worth stating out loud:
    /// - Every numeral in the source text survives verbatim as its own token. "4 eggs" can never
    ///   match "2 eggs", and a written fraction stays whole and stays welded to its food:
    ///   "1/2 cup oats" is neither "2 cup oats" nor a stray "1" free to sort onto another item.
    /// - Plurals are NOT stemmed. "2 egg" and "2 eggs" are different keys — a deliberate, tested
    ///   miss (see the type doc: precision over recall).
    /// - Duplicate segments are preserved, never Set-deduped. "coffee, coffee" != "coffee".
    /// - Segments join with `" | "`, which cannot occur inside a segment, so ["a b", "c"] and
    ///   ["a", "b c"] can never alias into the same key.
    /// - Unknown scalars (emoji, CJK, "%") are kept as content, so 🍕 != 🍔 and "2% milk" != "2 milk".
    ///   Deleting emoji would collapse "1 🍕" and "1 🍔" to the same key — the exact bug class we
    ///   are here to prevent.
    static func normalized(_ raw: String) -> String {
        segments(raw).sorted().joined(separator: " | ")
    }

    /// The meal's FOOD PHRASES, in the order the athlete wrote them — the same segmentation the
    /// key is built from, exposed so `FoodStaples` can try to resolve each food deterministically.
    /// "2 eggs and toast with coffee" → ["2 eggs", "toast", "coffee"]. Every rule documented on
    /// `normalized` (quantity welding, joiner words, fillers, apostrophes, number words) applies
    /// here identically — `normalized` IS `segments(...).sorted().joined(" | ")`, so the two can
    /// never drift.
    static func segments(_ raw: String) -> [String] {
        let folded = raw
            .precomposedStringWithCanonicalMapping
            .folding(options: [.diacriticInsensitive, .caseInsensitive],
                     locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        let chars = Array(folded)

        var segments: [String] = []
        var tokens: [String] = []
        var token = ""

        /// Close the running token. Returns true when it was a joiner word, which the caller then
        /// treats exactly like a comma. (Returning a flag instead of calling `closeSegment`
        /// directly keeps these two nested functions from being mutually recursive.)
        func closeToken() -> Bool {
            guard !token.isEmpty else { return false }
            let word = numberWords[token] ?? token
            token = ""
            if joinerWords.contains(word) { return true }
            if !fillerWords.contains(word) { tokens.append(word) }
            return false
        }

        func closeSegment() {
            guard !tokens.isEmpty else { return }
            segments.append(tokens.joined(separator: " "))
            tokens = []
        }

        var i = 0
        while i < chars.count {
            let c = chars[i]

            // "reese's" -> "reeses" (join, don't split).
            if apostrophes.contains(c) { i += 1; continue }

            // A separator flanked by digits belongs to the NUMBER, not between two foods:
            // "1.5 cups", "1/2 tbsp butter", "2:1 carb drink" each stay one token in one segment.
            if numberInternalSeparators.contains(c), i + 1 < chars.count, chars[i + 1].isNumber {
                if let last = token.last, last.isNumber {
                    token.append(c); i += 1; continue
                }
                // A LEADING decimal point has no digit on its left, so the guard above can't see
                // it — and falling through to the breaker DELETES the point, keying ".5 cup oats"
                // as five cups. Seed the zero the athlete left off, so ".5" and "0.5" are one key
                // and neither can ever alias onto "5".
                if c == ".", token.isEmpty {
                    token = "0."; i += 1; continue
                }
            }

            if segmentBreakers.contains(c) {
                _ = closeToken()
                closeSegment()
                i += 1; continue
            }

            if c.isWhitespace || tokenBreakers.contains(c) {
                if closeToken() { closeSegment() }
                i += 1; continue
            }

            token.append(c)
            i += 1
        }
        _ = closeToken()   // a trailing joiner has nothing left to join
        closeSegment()

        return segments
    }

    /// Convenience: a key worth looking up.
    static func isMatchable(_ key: String) -> Bool { !key.isEmpty }

    // MARK: Which remembered meal wins

    /// A remembered meal, reduced to only what the ranking rule needs — so the rule is testable
    /// without a ModelContainer.
    struct Candidate: Equatable, Sendable {
        var key: String
        var isManual: Bool
        var eatenAt: Date

        init(key: String, isManual: Bool, eatenAt: Date) {
            self.key = key
            self.isManual = isManual
            self.eatenAt = eatenAt
        }
    }

    /// The ONE ranking rule, shared by the typed lookup and the usuals chips so those two paths
    /// can never disagree about which meal represents a key. Two levels, both doctrinal:
    ///
    /// 1. **The athlete's hand outranks the estimate.** `manual` always wins, even against a newer
    ///    AI reading — this is the same "manual wins forever" promise `FuelEstimator.apply` keeps.
    ///    It also makes the loop self-correcting: fix a bad estimate once and every future match
    ///    of that text copies the corrected numbers.
    /// 2. **Then the most recent** — the freshest reading of that plate.
    ///
    /// `confidence` is deliberately NOT a tiebreak: it is the estimator grading its own homework,
    /// and any meal the athlete actually corrected has already become `manual`.
    static func outranks(aIsManual: Bool, aEatenAt: Date,
                         bIsManual: Bool, bEatenAt: Date) -> Bool {
        if aIsManual != bIsManual { return aIsManual }
        return aEatenAt > bEatenAt
    }

    /// Index of the winning candidate for `key`, or nil when nothing matches.
    /// O(n) over a bounded candidate set; stable (first wins ties).
    static func bestMatchIndex(key: String, among candidates: [Candidate]) -> Int? {
        guard isMatchable(key) else { return nil }
        var winner: Int?
        for (i, c) in candidates.enumerated() where c.key == key {
            guard let w = winner else { winner = i; continue }
            if outranks(aIsManual: c.isManual, aEatenAt: c.eatenAt,
                        bIsManual: candidates[w].isManual, bEatenAt: candidates[w].eatenAt) {
                winner = i
            }
        }
        return winner
    }
}
