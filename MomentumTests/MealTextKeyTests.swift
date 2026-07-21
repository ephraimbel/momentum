import Testing
import Foundation
@testable import Momentum

/// The precision contract for local-first meal resolution (FUEL-FLOW §1.5).
///
/// Read the NEGATIVE cases first: a missed match costs one cheap API call, but a WRONG match
/// silently writes someone else's nutrition into the athlete's day and is never noticed. Every
/// `!=` below is a false positive we have chosen to make impossible.
@Suite("MealTextKey")
struct MealTextKeyTests {

    private func key(_ s: String) -> String { MealTextKey.normalized(s) }

    // MARK: Positive — the same meal, phrased differently

    @Test("Punctuation and joiner words are the same meal")
    func fillerEquivalence() {
        #expect(key("2 eggs and toast with coffee") == key("2 eggs, toast, coffee"))
        #expect(key("2 eggs + toast & coffee") == key("2 eggs, toast, coffee"))
        #expect(key("2 eggs; toast / coffee") == key("2 eggs, toast, coffee"))
        #expect(key("2 eggs, toast, coffee.") == key("2 eggs, toast, coffee"))
    }

    @Test("Case, whitespace and stray padding never matter")
    func caseAndWhitespace() {
        #expect(key("Coffee, 2 Eggs, Toast") == key("2 eggs, toast, coffee"))
        #expect(key("   2 eggs,   toast  ") == key("2 eggs, toast"))
        #expect(key("2 eggs\ntoast") == key("2 eggs, toast"))
    }

    @Test("Filler words carry no food identity")
    func fillerWordsDropped() {
        #expect(key("a banana") == key("banana"))
        #expect(key("some of my oatmeal") == key("oatmeal"))
    }

    @Test("Hyphens join words inside one food; the shorthand 'w/' is a joiner")
    func tokenBreakersAndShorthand() {
        #expect(key("peanut-butter toast") == key("peanut butter toast"))
        #expect(key("toast w/ butter") == key("toast with butter"))
        #expect(key("(2) eggs") == key("2 eggs"))
    }

    // MARK: Negative — the failures that must stay impossible

    @Test("Digits are never merged")
    func digitsPreserved() {
        #expect(key("4 eggs, toast") != key("2 eggs, toast"))
        #expect(key("2 gels") != key("gels"))
        #expect(key("3 eggs") != key("30 eggs"))
    }

    /// THE test. A bare token sort makes these two the identical multiset
    /// {1, 2, egg(s), slice(s), toast} — a silent wrong-nutrition match. Sorting SEGMENTS keeps
    /// each quantity welded to the food it counts. Never delete this test.
    @Test("A quantity can never drift onto the wrong food")
    func quantityStaysBound() {
        #expect(key("2 eggs, 1 slice toast") != key("1 egg, 2 slices toast"))
        #expect(key("2 scoops whey, 1 banana") != key("1 scoop whey, 2 bananas"))
    }

    @Test("Different foods never collide")
    func distinctFoods() {
        #expect(key("chicken rice bowl") != key("chicken rice"))
        #expect(key("oat milk latte") != key("almond milk latte"))
    }

    @Test("Segment order does not matter; segment grouping does")
    func segmentSorting() {
        #expect(key("coffee, 2 eggs") == key("2 eggs, coffee"))
        #expect(key("toast with butter") == key("butter, toast"))
        // The " | " joiner cannot occur inside a segment, so no two groupings can alias.
        #expect(key("peanut butter, jam") != key("peanut, butter jam"))
        // An accepted MISS (not a wrong hit): one segment never matches two.
        #expect(key("peanut butter toast") != key("peanut butter, toast"))
    }

    @Test("Duplicates are content, not noise")
    func duplicatesKept() {
        #expect(key("coffee, coffee") != key("coffee"))
        #expect(key("gel, gel, gel") != key("gel, gel"))
    }

    // MARK: Quantities

    @Test("Number words are the same count; ambiguous quantities are not normalized")
    func numberWords() {
        #expect(key("two eggs") == key("2 eggs"))
        #expect(key("dozen eggs") == key("12 eggs"))
        #expect(key("two eggs") != key("3 eggs"))
        #expect(key("half a banana") != key("banana"))   // "half" stays a word, deliberately
        #expect(key("a couple gels") != key("2 gels"))   // ambiguous: never merged
    }

    @Test("Decimals survive intact")
    func decimals() {
        #expect(key("1.5 cups oats") == key("1.5 cups oats"))
        #expect(key("1.5 cups oats") != key("15 cups oats"))
        #expect(key("1.5 cups oats") != key("1 cups oats"))
        // A sentence-ending period is still a segment break, not a decimal.
        #expect(key("2 eggs. toast") == key("2 eggs, toast"))
    }

    /// Deliberately NOT stemmed. Pinned so nobody "fixes" this into a recall win later without
    /// re-arguing the false-positive risk.
    @Test("Plurals are not stemmed — an intentional miss")
    func noPluralStemming() {
        #expect(key("2 egg") != key("2 eggs"))
        #expect(key("1 slice toast") != key("1 slices toast"))
    }

    // MARK: Unicode

    @Test("Apostrophes join, diacritics fold, emoji stay distinct")
    func unicode() {
        #expect(key("reese's") == key("reeses"))
        #expect(key("reese\u{2019}s cup") == key("reeses cup"))
        #expect(key("a\u{00E7}a\u{00ED} bowl") == key("acai bowl"))
        #expect(key("caf\u{00E9} au lait") == key("cafe au lait"))
        // Deleting emoji would collapse these two to the same key "1" — the exact bug class
        // this engine exists to prevent.
        #expect(key("1 \u{1F355}") != key("1 \u{1F354}"))
        #expect(key("\u{1F355}") == key("\u{1F355}"))
        #expect(key("2% milk") != key("2 milk"))
    }

    // MARK: Unmatchable

    @Test("Unmatchable text yields no key")
    func unmatchable() {
        #expect(key("") == "")
        #expect(key("   ") == "")
        #expect(key("the") == "")
        #expect(key("a, an, the") == "")
        #expect(key(",,, ... ") == "")
        #expect(key("and with plus") == "")   // joiners alone name no food
        #expect(MealTextKey.isMatchable(key("the")) == false)
        #expect(MealTextKey.isMatchable(key("2 eggs")) == true)
    }

    // MARK: Ranking

    @Test("Manual outranks a newer estimate; otherwise the newest wins")
    func ranking() {
        let now = Date()
        let candidates = [
            MealTextKey.Candidate(key: "k", isManual: false, eatenAt: now),                        // 0
            MealTextKey.Candidate(key: "k", isManual: true,  eatenAt: now.addingTimeInterval(-9_999)), // 1
            MealTextKey.Candidate(key: "j", isManual: true,  eatenAt: now),                        // 2
        ]
        #expect(MealTextKey.bestMatchIndex(key: "k", among: candidates) == 1)
        #expect(MealTextKey.bestMatchIndex(key: "j", among: candidates) == 2)
        #expect(MealTextKey.bestMatchIndex(key: "z", among: candidates) == nil)
        #expect(MealTextKey.bestMatchIndex(key: "", among: candidates) == nil)
        #expect(MealTextKey.bestMatchIndex(key: "k", among: []) == nil)
    }

    @Test("Among equal provenance the most recent reading wins")
    func recencyTiebreak() {
        let now = Date()
        let candidates = [
            MealTextKey.Candidate(key: "k", isManual: false, eatenAt: now.addingTimeInterval(-600)), // 0
            MealTextKey.Candidate(key: "k", isManual: false, eatenAt: now),                          // 1
            MealTextKey.Candidate(key: "k", isManual: false, eatenAt: now.addingTimeInterval(-60)),  // 2
        ]
        #expect(MealTextKey.bestMatchIndex(key: "k", among: candidates) == 1)
    }

    @Test("Confidence is never a tiebreak — the ranking rule takes only hand and clock")
    func rankingRule() {
        let now = Date()
        let older = now.addingTimeInterval(-3_600)
        #expect(MealTextKey.outranks(aIsManual: true, aEatenAt: older,
                                     bIsManual: false, bEatenAt: now))
        #expect(!MealTextKey.outranks(aIsManual: false, aEatenAt: now,
                                      bIsManual: true, bEatenAt: older))
        #expect(MealTextKey.outranks(aIsManual: false, aEatenAt: now,
                                     bIsManual: false, bEatenAt: older))
        // Strict: an exact tie does not outrank, so `bestMatchIndex` stays stable (first wins).
        #expect(!MealTextKey.outranks(aIsManual: true, aEatenAt: now,
                                      bIsManual: true, bEatenAt: now))
    }

    @Test("Version is pinned — bump it deliberately when the algorithm changes")
    func versionPinned() {
        #expect(MealTextKey.version == 1)
    }
}
