import Testing
import Foundation
import SwiftUI
@testable import Momentum

/// The wall as a PICTURE — what the athlete's eye actually lands on when they open Community.
/// `CommunityContentAuditTests` already pins the content (run-dominant, routed, honest titles);
/// these pin the arrangement, because the tells the owner reports are visual: a row of identical
/// stick figures, two muscle figures lit the same way side by side, a dark-mode wall of glaring
/// white maps.
@MainActor
struct CommunityWallTests {

    /// Today's assembled Global page, exactly as `CommunityView` builds it.
    private func wall() -> [FeedItem] {
        CommunityView.spaced(Array(CommunityFeed.seed().sorted { $0.date > $1.date }.prefix(400)))
    }

    // MARK: The arrangement

    /// The finding (2026-08-28, screenshotted at wall depth 42): a full row read yoga · yoga · swim,
    /// and two strength posts drew byte-identical muscle figures next to each other. Every glyph
    /// tile of a sport looks the same as every other, so date order alone WILL clump them.
    ///
    /// Like the vertical-neighbour check below, this asserts the spacer's actual bounded promise:
    /// a repeated subject may ship only when no legal alternative remains inside the four-slot
    /// chronology budget. An absolute-zero assertion was clock-dependent because the live seeded
    /// wall sometimes produces a genuinely unavoidable run; `spaced` explicitly lets date order
    /// win in that case.
    @Test func aSideBySideRepeatOnlyShipsWhenNothingElseWasReachable() {
        let source = Array(CommunityFeed.seed().sorted { $0.date > $1.date }.prefix(400))
        let items = CommunityView.spaced(source)
        let lookahead = 4
        var sourceIndex: [UUID: Int] = [:]
        for (i, post) in source.enumerated() { sourceIndex[post.id] = i }

        var unforgiven: [String] = []
        for i in items.indices where i > 0 && i % 3 != 0 {
            let sig = CommunityView.mediaSignature(items[i])
            guard sig == CommunityView.mediaSignature(items[i - 1]) else { continue }
            if i - (sourceIndex[items[i].id] ?? i) >= 4 { continue }
            let left = sig
            let above = i >= 3 ? CommunityView.mediaSignature(items[i - 3]) : nil
            let candidates = items[i...].filter { (sourceIndex[$0.id] ?? .max) <= i + lookahead }
            let usable = candidates.filter {
                let candidate = CommunityView.mediaSignature($0)
                return candidate != left && candidate != above
            }
            if let alternative = usable.first {
                unforgiven.append("slot \(i) drew '\(sig)' beside an identical tile while "
                                  + "'\(CommunityView.mediaSignature(alternative))' was reachable")
            }
        }
        #expect(unforgiven.isEmpty, "\(unforgiven.count) avoidable side-by-side repeats: \(unforgiven.prefix(3))")
    }

    /// The wall is a 3-across mosaic, so the tile directly ABOVE is as much a neighbour as the one
    /// to the left — two identical muscle figures stacked in one column read exactly as duplicated
    /// as two sitting side by side.
    ///
    /// **This used to assert zero stacked repeats, and zero is not something `spaced` can promise
    /// (2026-08-29).** It holds at most `lookahead` tiles, so when every candidate within reach
    /// clashes with the tile to the left or the tile above, the overflow branch does what its own
    /// comment says: the date wins and the repeat ships. `tinyWallsPassThroughUntouched` already
    /// documents that contract from the other side ("two of the same picture with no third option:
    /// the date wins"). Widening the window to buy zero is the trade the 2026-08-28 session made
    /// and reverted — it blew `everyPostSurvivesAndBarelyMoves` to a worst drift of 7 against a
    /// bound of 4, and then shipped TOUCHING repeats to get back inside it.
    ///
    /// So this asserts the guarantee that actually exists, and it is STRICTLY STRONGER than the old
    /// absolute: a stacked repeat is legal only when nothing else was reachable. The old form could
    /// not tell a real spacing regression from one unlucky deal; this one goes red the moment
    /// `spaced` leaves a usable tile on the table, and stays green when the content genuinely gave
    /// it nothing to work with.
    @Test func aStackedRepeatOnlyShipsWhenNothingElseWasReachable() {
        let source = Array(CommunityFeed.seed().sorted { $0.date > $1.date }.prefix(400))
        let items = CommunityView.spaced(source)
        let lookahead = 4
        var sourceIndex: [UUID: Int] = [:]
        for (i, post) in source.enumerated() { sourceIndex[post.id] = i }

        var unforgiven: [String] = []
        for i in items.indices where i >= 3 {
            let sig = CommunityView.mediaSignature(items[i])
            guard sig == CommunityView.mediaSignature(items[i - 3]) else { continue }
            // Forgiven outright when the post had already waited its whole displacement budget:
            // reverse-chronological order is the ethos and outranks the spacing, so at that point
            // the tile ships wherever it lands. That is the `maxDrift` rule in `spaced`.
            if i - (sourceIndex[items[i].id] ?? i) >= 4 { continue }
            let above = sig
            let left = i % 3 == 0 ? nil : CommunityView.mediaSignature(items[i - 1])
            // What `spaced` still had in hand for this slot: posts not yet emitted (they land at
            // output index i or later) whose own date position is within the displacement budget.
            let candidates = items[i...].filter { (sourceIndex[$0.id] ?? .max) <= i + lookahead }
            let usable = candidates.filter {
                let s = CommunityView.mediaSignature($0)
                return s != above && s != left
            }
            if let alternative = usable.first {
                unforgiven.append("slot \(i) drew '\(sig)' under an identical tile while "
                                  + "'\(CommunityView.mediaSignature(alternative))' was reachable")
            }
        }
        #expect(unforgiven.isEmpty, "\(unforgiven.count) avoidable stacked repeats: \(unforgiven.prefix(3))")
    }

    /// The seed's side of the same contract, and the thing to look at first when a repeat DOES
    /// ship. `spaced` can separate at most `lookahead` consecutive same-picture posts; a longer run
    /// than that in date order is a content problem it cannot solve by rearranging, and the fix
    /// belongs in the generator, never in the spacer. Every mapless post of one sport draws the
    /// identical glyph, so this is where a sport clumping at the top of a 2,863-athlete feed shows
    /// up as a number instead of as a guess.
    @Test func noSportClumpsBeyondWhatSpacingCanAbsorb() {
        let source = Array(CommunityFeed.seed().sorted { $0.date > $1.date }.prefix(400))
        var longest = 0
        var worst = ""
        var run = 0
        var previous = ""
        for post in source {
            let sig = CommunityView.mediaSignature(post)
            run = sig == previous ? run + 1 : 1
            previous = sig
            if run > longest { longest = run; worst = sig }
        }
        #expect(longest <= 4, "\(longest) consecutive '\(worst)' posts in date order — spacing holds only 4")
    }

    /// The signature has to be able to TELL two pictures apart, or the test above passes on a
    /// tautology. Two posts of the same sport with no media share it; a route and a lift don't.
    ///
    /// **This is the arbiter of what "the same picture" means, so read the first clause carefully
    /// (2026-08-29).** Two yoga posts share a signature even though `WashVariation` now deals them
    /// different tints and symbol sizes — because the signature's job is the SUBJECT a tile draws,
    /// and its one consumer (`spaced`) exists to keep a repeated subject out of the viewport. The
    /// alternative — putting the deal in the key so two tinted yoga tiles count as two pictures —
    /// is implemented as `dealtSignature` and measured by `spacingKeysOnTheSubjectNotTheDeal`; it
    /// seats 27 same-subject neighbours across a 400-tile wall against this one's 0, and put three
    /// running figures side by side in the third row of a real screenshot. The wall ships this one.
    @Test func signatureSeesWhatTheTileDraws() {
        let yoga = Self.post(type: .yoga)
        let otherYoga = Self.post(type: .yoga)
        let swim = Self.post(type: .swimming)
        #expect(CommunityView.mediaSignature(yoga) == CommunityView.mediaSignature(otherYoga))
        #expect(CommunityView.mediaSignature(yoga) != CommunityView.mediaSignature(swim))

        // Sports that SHARE a glyph draw the same picture and must share a signature. A mapless
        // run and a mapless trail run are both `figure.run`; all four cycling cases are `bicycle`.
        // Keying on the sport instead of on the glyph told `spaced` they differed, and it shipped
        // two identical running figures side by side (screenshotted at wall depth 24, 2026-08-29).
        #expect(CommunityView.mediaSignature(Self.post(type: .run))
                == CommunityView.mediaSignature(Self.post(type: .trailRun)))
        #expect(CommunityView.mediaSignature(Self.post(type: .ride))
                == CommunityView.mediaSignature(Self.post(type: .gravelRide)))

        let legs: [MuscleGroup: Double] = [.quads: 1, .glutes: 0.8]
        let push: [MuscleGroup: Double] = [.chest: 1, .triceps: 0.6]
        #expect(CommunityView.mediaSignature(Self.post(type: .strength, muscles: legs))
                == CommunityView.mediaSignature(Self.post(type: .strength, muscles: legs)))
        #expect(CommunityView.mediaSignature(Self.post(type: .strength, muscles: legs))
                != CommunityView.mediaSignature(Self.post(type: .strength, muscles: push)))

        // Only three loops ship per city, so two neighbours genuinely draw the same trace — the
        // shape is the signature, not the post id.
        let loop = [[30.0, -97.0], [30.1, -97.1], [30.0, -97.0]]
        #expect(CommunityView.mediaSignature(Self.post(type: .run, route: loop))
                == CommunityView.mediaSignature(Self.post(type: .run, route: loop)))
        #expect(CommunityView.mediaSignature(Self.post(type: .run, route: loop))
                != CommunityView.mediaSignature(Self.post(type: .run, route: [[1.0, 1.0], [2.0, 2.0]])))

        // The BRANCH ORDER is the tile's (2026-08-29). `FeedTileMedia` covers with the photo only
        // when the author chose it; otherwise the activity's own visual leads. Leading here with
        // "has photos at all" claimed a unique picture for a post whose tile draws its route, so
        // two athletes running the same city loop could ship side by side unnoticed.
        var photoOverRoute = Self.post(type: .run, route: loop)
        photoOverRoute.photosData = [Data([0xFF, 0xD8])]
        #expect(CommunityView.mediaSignature(photoOverRoute)
                == CommunityView.mediaSignature(Self.post(type: .run, route: loop)),
                "an unchosen photo hid the route the tile actually draws")
        var photoCover = photoOverRoute
        photoCover.coverIsPhoto = true
        #expect(CommunityView.mediaSignature(photoCover).hasPrefix("photo:"),
                "the author's chosen cover photo IS the picture")
    }

    /// The 2026-08-25 rule survives the rewrite: a media-less glyph can't take a lead slot **while
    /// a media post is available for it** — where "available" means within the displacement budget
    /// `spaced` is allowed to spend (`lookahead`, 4 slots).
    ///
    /// **This used to assert the first six tiles carry media unconditionally, and that is not a
    /// property `spaced` can have (2026-08-29).** The two invariants are provably incompatible:
    /// with a source that opens `G G G G G M M M M M M`, the only way to fill six lead slots with
    /// media is to move the first media post six places forward, and
    /// `everyPostSurvivesAndBarelyMoves` bounds every move at four. Reverse-chronological is the
    /// documented ethos (docs/SOCIAL-LAYER.md) and the media lead is cosmetic, so the drift bound
    /// wins and the lead is best-effort. Widening `lookahead` to fund it just relocates the
    /// failure into the drift test — that exact trade was tried and reverted on 2026-08-28; see
    /// [[community-numbers-ledger-2026-08-28]].
    ///
    /// What is asserted instead is the rule the algorithm really implements and the doc comment
    /// really promises, which is not vacuous: a glyph in a lead slot is only forgiven when the
    /// source genuinely had no media post within reach of that slot. Five consecutive mapless
    /// posts at the top of the feed is a CONTENT problem (structured runs, yoga, swims) and is
    /// fixed at the seed, never by shuffling tiles further.
    @Test func theWallNeverOpensOnAGlyphItCouldHaveLedWithMedia() {
        let source = Array(CommunityFeed.seed().sorted { $0.date > $1.date }.prefix(400))
        let items = CommunityView.spaced(source)
        let lookahead = 4
        guard let first = items.first, !CommunityView.hasMedia(first) else { return }
        // Slot zero is the exact case the algorithm CAN guarantee: it holds illegal tiles until
        // `lookahead` of them have piled up, so any media post inside the first `lookahead + 1`
        // source posts is emitted first. A glyph here is only forgiven when there was none.
        let reachable = source.prefix(lookahead + 1)
        // ONE string literal, never a `+` concatenation. `@testable import Momentum` pulls the
        // app's own `Comment` type into scope, and `#expect`'s message parameter is
        // `Testing.Comment?`. A literal (or an interpolated literal) converts implicitly via
        // ExpressibleByStringInterpolation; a concatenation is a plain `String` and does not,
        // which fails as "cannot convert value of type 'String' to expected argument type
        // 'Comment?'" and breaks the whole test build for everyone on this checkout.
        #expect(!reachable.contains(where: CommunityView.hasMedia),
                "'\(first.title)' opens the wall with no media while a media post sat within reach to lead instead")
    }

    /// The opening still has to LOOK like a wall of work rather than a column of stick figures.
    /// Deliberately a floor, not a guarantee: on a day when the community really did post five
    /// mapless sessions in a row the date order wins, and that is the documented trade. One media
    /// tile in the first row is the bar that catches a genuine regression — the lead rule silently
    /// stopping applying at all.
    @Test func theWallOpensOnAtLeastOnePieceOfMedia() {
        let items = wall()
        #expect(items.prefix(3).contains(where: CommunityView.hasMedia),
                "the wall's whole first row is media-less")
    }

    /// Reverse-chronological is the ethos (docs/SOCIAL-LAYER.md) — spacing is cosmetic and must
    /// stay local. Nothing is dropped, nothing is invented, and nothing moves more than a couple
    /// of tiles from its own date slot.
    @Test func everyPostSurvivesAndBarelyMoves() {
        let source = Array(CommunityFeed.seed().sorted { $0.date > $1.date }.prefix(400))
        let spread = CommunityView.spaced(source)
        #expect(spread.count == source.count)
        #expect(Set(spread.map(\.id)) == Set(source.map(\.id)))

        var landed: [UUID: Int] = [:]
        for (i, item) in spread.enumerated() { landed[item.id] = i }
        var worst = 0
        for (i, item) in source.enumerated() {
            worst = max(worst, abs((landed[item.id] ?? i) - i))
        }
        #expect(worst <= 4, "a post moved \(worst) slots from its date position")
    }

    @Test func tinyWallsPassThroughUntouched() {
        #expect(CommunityView.spaced([]).isEmpty)
        let one = [Self.post(type: .yoga)]
        #expect(CommunityView.spaced(one).map(\.id) == one.map(\.id))
        // Two of the same picture with no third option: the date wins, the repeat ships.
        let two = [Self.post(type: .yoga), Self.post(type: .yoga)]
        #expect(CommunityView.spaced(two).count == 2)
    }

    // MARK: Dark mode

    /// The community wall renders through `FeedRouteSnapshots`, which resolves the post's map style
    /// with `uriStyle(for:)`. Before 2026-08-28 it called `styleURI(for:)` — whose scheme argument
    /// is ignored — so a dark-mode wall was a mosaic of bright white basemaps even though the
    /// scheme was already in the render cache key. This pins the pairing for the styles the
    /// community actually posts with.
    @Test func communityMapsPairWithTheAppearance() {
        for style in CommunityGenerator.feedStyles {
            #expect(style.uriStyle(for: .light) == style, "\(style) should render as chosen in light")
        }
        // The two DEFAULT styles fall back to Dark at night; a deliberate pick renders as chosen.
        #expect(MapStyleOption.standard.uriStyle(for: .dark) == .dark)
        #expect(MapStyleOption.realistic.uriStyle(for: .dark) == .dark)
        #expect(MapStyleOption.streets.uriStyle(for: .dark) == .streets)
        #expect(MapStyleOption.outdoors.uriStyle(for: .dark) == .outdoors)
        // Tile ink follows the canvas the snapshot actually baked, not the stored style.
        #expect(MapStyleOption.standard.uriStyle(for: .dark).bakesDarkCanvas)
        #expect(!MapStyleOption.standard.uriStyle(for: .light).bakesDarkCanvas)
    }

    // MARK: Stat parsing

    /// Bookmarking a post stores its distance in km, read back off the stat line. Every metric
    /// athlete's saved routes were 1.6× too long because the unit was assumed to be miles.
    @Test func savedDistanceReadsTheUnitNotJustTheNumber() {
        let miles = Self.post(type: .run, route: [[0, 0], [1, 1]], stat: "5.5 mi · 44:31")
        #expect(abs(miles.distanceKm - 8.85) < 0.02)
        let km = Self.post(type: .run, route: [[0, 0], [1, 1]], stat: "8.9 km · 44:31")
        #expect(abs(km.distanceKm - 8.9) < 0.001)
        // Grouped thousands survive the parse (an ultra's stat line).
        let long = Self.post(type: .run, route: [[0, 0], [1, 1]], stat: "1,050 km · 9:12:00")
        #expect(abs(long.distanceKm - 1050) < 0.001)
        // A lift has no distance to claim.
        #expect(Self.post(type: .strength, stat: "12,400 lb · 18 sets · 1:02:40").distanceKm == 0)
    }

    /// A trail post's climb figure used to fall through unlabeled, so the pager drew a number under
    /// a blank caption beside DISTANCE and TIME — the one cell that looked unfinished.
    @Test func climbIsALabeledStatNotABlankOne() {
        let trail = Self.post(type: .trailRun, stat: "8.1 mi · 1:14:45 · 1,350 ft")
        let labels = trail.metrics.map(\.label)
        #expect(labels == ["Distance", "Time", "Climb"], "got \(labels)")
        #expect(trail.metrics.allSatisfy { !$0.label.isEmpty }, "a stat cell shipped without a label")
    }

    /// Every seeded post's stat row is fully labeled — a value with no caption reads as a bug on
    /// the one screen the community is judged by.
    @Test func everyWallPostHasFullyLabeledStats() {
        for item in wall().prefix(120) {
            for metric in item.metrics {
                #expect(!metric.label.isEmpty,
                        "'\(item.title)' shows '\(metric.value)' with no label (stat line: \(item.statLine))")
            }
        }
    }

    // MARK: The deal — what makes two glyph tiles different pictures

    /// The variation is what the signature above is now allowed to key on, so it has to be real,
    /// stable, and bounded.
    ///
    /// STABLE is the load-bearing half: everything is folded out of the post's own id bytes, never
    /// `UUID.hashValue` (Swift seeds `Hasher` per process, so a hash-derived wall would re-deal
    /// itself on every cold launch — the same tile a different colour each time you opened the app,
    /// and a signature that disagreed with yesterday's).
    ///
    /// BOUNDED is the taste half: this is variation inside one design language, not a theme picker.
    /// Nothing may leave the ranges the canonical wash already sits in.
    @Test func everyPostDrawsItsOwnGlyphTileAndTheSameOneEveryTime() {
        let id = UUID()
        #expect(WashVariation(seed: id) == WashVariation(seed: id), "a tile re-dealt itself")
        #expect(WashVariation.tone(for: id) == WashVariation(seed: id).tone,
                "the signature's cheap tone read disagrees with the full deal")

        var deals: Set<WashVariation> = []
        var tones: Set<Int> = []
        for _ in 0..<400 {
            let deal = WashVariation(seed: UUID())
            deals.insert(deal)
            tones.insert(deal.tone)
            // The taste bounds. A symbol that can double in size, or slide off its own tile, or
            // fade to a ghost, stops reading as the same component.
            #expect((0.84...1.14).contains(deal.glyphScale))
            #expect(abs(deal.glyphOffsetX) <= 0.16 && (-0.19...0.11).contains(deal.glyphOffsetY))
            #expect((0.76...0.92).contains(deal.glyphInk))
            #expect(abs(deal.driftBoost) <= 0.03 && abs(deal.liftBoost) <= 0.045)
            #expect(abs(deal.axis - .pi / 4) <= 0.72)
            #expect((-0.05...0.90).contains(deal.lightX) && (-0.05...0.50).contains(deal.lightY))
            #expect((300.0...540.0).contains(deal.lightReach))
        }
        #expect(deals.count == 400, "two posts were dealt the identical tile — the wallpaper is back")
        #expect(tones.count == WashVariation.tones, "the palette isn't dealing every hue")
    }

    /// The point of the whole change, as a number: a screenful of mapless posts of ONE sport used
    /// to be a screenful of one *rendering*. `spaced` could only rearrange them, never make them
    /// differ — [[community-numbers-ledger-2026-08-28]] named this the structural cap on wall
    /// variety. Every tile is now its own deal, so the repeats the spacer cannot avoid are at
    /// least not the same picture twice.
    @Test func aScreenfulOfOneSportIsNoLongerOneRendering() {
        let screenful = (0..<12).map { _ in Self.post(type: .swimming) }
        #expect(Set(screenful.map { WashVariation(seed: $0.id) }).count == 12,
                "twelve swims still render identically")
    }

    /// The seed gives every post exactly ONE visual, and `mediaSignature`'s branch order is
    /// therefore unobservable on it. Worth pinning both ways round: it is what makes the reorder to
    /// the tile's own order (photo-cover → muscle → route → photo → glyph) a provable no-op for
    /// community content, and it is the property that would have to break first if a future seed
    /// started attaching photos — at which point the order stops being cosmetic and starts deciding
    /// what the wall thinks it is looking at.
    @Test func everySeededPostCarriesExactlyOneVisual() {
        for post in CommunityFeed.seed().prefix(1_500) {
            #expect(post.photosData.isEmpty,
                    "a seeded post carries a photo — the seed is faking a camera roll again")
            let hasMuscles = post.muscles?.values.contains { $0 > 0 } ?? false
            let hasRoute = (post.routeLatLon?.count ?? 0) > 1
            #expect(!(hasMuscles && hasRoute),
                    "'\(post.title)' carries both a muscle map and a route — the tile can only draw one")
        }
    }

    /// **The judgement call, held to its numbers.** Once every glyph tile is dealt its own tint and
    /// symbol size, the tempting follow-through is to say two of them are no longer "the same
    /// picture" — which frees `spaced` from separating them and hands its whole displacement budget
    /// to the repeats that still ARE identical (a city's three route loops, two leg days on one
    /// figure). It was tried, on 2026-08-29, and the wall got worse: three running figures landed
    /// side by side in the third row of a real screenshot.
    ///
    /// This is why. The deal changes a tile's TINT; it does not change its SUBJECT, and on a
    /// 3-across mosaic of 130pt tiles the subject is what the eye sorts by. So the shipped
    /// signature keys on the subject, and the two mechanisms do different jobs: the spacer keeps
    /// two of one sport apart, and the deal means the pairs it cannot keep apart are still two
    /// pictures rather than one drawn twice.
    ///
    /// The test runs both definitions over the real seed and counts what each puts next to each
    /// other, so this stays a measurement rather than a taste argument.
    @Test func spacingKeysOnTheSubjectNotTheDeal() {
        let source = Array(CommunityFeed.seed().sorted { $0.date > $1.date }.prefix(400))

        /// Neighbours drawing the same SUBJECT — left, and directly above.
        func sameSubjectNeighbours(_ wall: [FeedItem]) -> Int {
            var count = 0
            for i in wall.indices {
                let sig = CommunityView.mediaSignature(wall[i])
                if i % 3 != 0, CommunityView.mediaSignature(wall[i - 1]) == sig { count += 1 }
                if i >= 3, CommunityView.mediaSignature(wall[i - 3]) == sig { count += 1 }
            }
            return count
        }

        let shipped = sameSubjectNeighbours(CommunityView.spaced(source))
        let dealt = sameSubjectNeighbours(CommunityView.spaced(source, picture: CommunityView.dealtSignature))
        print("SIGNATURE-TRADE same-subject neighbours: subject=\(shipped) deal=\(dealt)")
        // ONE string literal, never a `+` concatenation — see the note in
        // `theWallNeverOpensOnAGlyphItCouldHaveLedWithMedia`: `#expect`'s message is a
        // `Testing.Comment?`, and a concatenation is a plain `String` that will not convert.
        #expect(shipped <= dealt,
                "keying on the deal seated FEWER same-subject tiles together (\(dealt)) than keying on the subject (\(shipped)) — the trade has flipped, re-run it before trusting this")
    }

    // MARK: Helpers

    private static func post(type: WorkoutType, muscles: [MuscleGroup: Double]? = nil,
                             route: [[Double]]? = nil, stat: String = "30:00",
                             id: UUID = UUID()) -> FeedItem {
        FeedItem(id: id, authorName: "Test Athlete", authorHandle: "test", location: "Austin, TX",
                 isCommunity: true, type: type, date: Date(), title: "Session", caption: nil,
                 statLine: stat, prBadge: nil, muscles: muscles, routeLatLon: route)
    }
}
