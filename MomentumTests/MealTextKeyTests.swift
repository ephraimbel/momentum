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
        #expect(key("a couple gels") != key("2 gels"))   // ambiguous: never merged
        #expect(key("a few dates") != key("3 dates"))    // ambiguous: never merged
    }

    /// v3: dictation says "half of a bagel", never "1/2 bagel" — spoken portions must land on the
    /// SAME key as their typed spelling, and a spoken half must never alias onto the whole food.
    @Test("Spoken portions canonicalize to their typed fraction")
    func spokenPortions() {
        #expect(key("half of a rice crispy treat") == key("1/2 rice crispy treat"))
        #expect(key("half a bagel") == key("1/2 bagel"))
        #expect(key("half an apple") == key("1/2 apple"))
        #expect(key("a half banana") == key("1/2 banana"))
        #expect(key("half bagel") == key("1/2 bagel"))
        #expect(key("a quarter of a bagel") == key("1/4 bagel"))
        #expect(key("quarter of the pizza") == key("1/4 pizza"))
        #expect(key("three quarters of a cup of oats") == key("3/4 cup oats"))
        #expect(key("three quarter cup rice") == key("3/4 cup rice"))
        #expect(key("one and a half bananas") == key("1.5 bananas"))
        #expect(key("two and a half cups of rice") == key("2.5 cups rice"))
        #expect(key("2 and a half gels") == key("2.5 gels"))
        // The half can never disappear into the whole food.
        #expect(key("half a banana") != key("banana"))
        #expect(key("half of a rice crispy treat") != key("rice crispy treat"))
        // Sizes ride with the food, so a half LARGE treat is not a half treat.
        #expect(key("half of a large rice crispy treat") == key("1/2 large rice crispy treat"))
        #expect(key("half of a large rice crispy treat") != key("1/2 rice crispy treat"))
    }

    /// "half and half" is a coffee creamer, not two fractions — and a trailing "half" is a
    /// position, not a portion.
    @Test("Spoken-portion guardrails: the creamer and trailing halves stay unmapped")
    func spokenPortionGuardrails() {
        #expect(key("coffee with half and half") != key("coffee, 1/2, 1/2"))
        #expect(key("coffee with half and half") == key("coffee and half-and-half"))
        #expect(key("banana half") != key("1/2 banana"))     // trailing: honest miss
        #expect(key("half and half") != key("1/2 1/2"))
    }

    @Test("Decimals survive intact")
    func decimals() {
        #expect(key("1.5 cups oats") == key("1.5 cups oats"))
        #expect(key("1.5 cups oats") != key("15 cups oats"))
        #expect(key("1.5 cups oats") != key("1 cups oats"))
        // A sentence-ending period is still a segment break, not a decimal.
        #expect(key("2 eggs. toast") == key("2 eggs, toast"))
    }

    /// v1 dropped a leading decimal point outright (the guard demanded a digit to its LEFT, and a
    /// token that hasn't started has none), so ".5 cup oats" keyed as FIVE cups — a tenfold
    /// quantity inversion, and a live collision with anyone who had logged "5 cup ...".
    @Test("A leading decimal point is a half, not a five")
    func leadingDecimal() {
        #expect(key(".5 cup oats") != key("5 cup oats"))
        #expect(key(".25 cup nuts") != key("25 cup nuts"))
        // ".5" and "0.5" are the same portion, so they are one key — a recall win the precision
        // bias allows precisely because both texts mean the same amount.
        #expect(key(".5 cup oats") == key("0.5 cup oats"))
        // It stays welded to its food rather than severing the segment: "oats .5 cup" is one food.
        #expect(key("oats .5 cup") == key("oats 0.5 cup"))
    }

    /// THE fraction test. v1 broke on "/" unconditionally, so "1/2 cup oats" became the segments
    /// ["1", "2 cup oats"] — the key asserting TWO cups, with the orphan numerator free to sort
    /// anywhere. Two meals sharing a unit word then collapsed onto one key and the resolver copied
    /// the wrong plate's nutrition, silently and with no searching beat to hint at it.
    @Test("A typed fraction stays whole and stays on its own food")
    func typedFractions() {
        #expect(key("1/2 cup oats") != key("2 cup oats"))
        #expect(key("1/2 cup oats") != key("1 cup oats"))
        #expect(key("1/2 tbsp butter, 2 tbsp jam") != key("1/2 tbsp jam, 2 tbsp butter"))
        #expect(key("2 oz cheese, 1/2 oz almonds") != key("2 oz almonds, 1/2 oz cheese"))
        #expect(key("3/4 cup rice, 4 cup broth") != key("3/4 cup broth, 4 cup rice"))
        // Same fraction, same food, either phrasing — still one key.
        #expect(key("1/2 cup oats and coffee") == key("coffee, 1/2 cup oats"))
        // A ratio is a number too: "2:1 carb drink" must not invert into "1 carb drink | 2".
        #expect(key("2:1 carb drink") != key("1:2 carb drink"))
    }

    /// The digit-flanked rule must not steal the separators' day job. A slash between WORDS is
    /// still the "w/" shorthand and a period between words is still a full stop.
    @Test("Separators not flanked by digits still break as before")
    func separatorsStillBreak() {
        #expect(key("2 eggs; toast / coffee") == key("2 eggs, toast, coffee"))
        #expect(key("toast w/ butter") == key("toast with butter"))
        #expect(key("eggs/toast") == key("eggs, toast"))
        #expect(key("2 eggs. 5 slices toast") == key("2 eggs, 5 slices toast"))
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
        #expect(MealTextKey.version == 3)   // v3: spoken portions canonicalize to typed fractions
    }
}
