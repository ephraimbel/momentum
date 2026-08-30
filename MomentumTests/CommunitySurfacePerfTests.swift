import Testing
import Foundation
import SwiftUI
import UIKit
@testable import Momentum

/// The community surfaces' **responsiveness contract** (2026-08-29 pass). Every test here pins a
/// property that, when it broke, showed up as the athlete waiting or watching something pop in:
///
///  • the wall's assembly is a pure function of a value snapshot, so it can run off the main actor
///    (it froze the app for 881 ms on the main thread before this);
///  • the moderation snapshot it carries answers exactly what `ModerationStore` would;
///  • a rendered route map is looked up, not re-rendered, and the lookup key the tile reads is the
///    key the render writes;
///  • the snapshot cache cannot grow without bound, however deep the browse goes.
@MainActor
struct CommunitySurfacePerfTests {

    // MARK: Helpers

    private func item(_ handle: String?, at date: Date, id: UUID = UUID(),
                      community: Bool = true) -> FeedItem {
        FeedItem(id: id, authorName: handle ?? "You", authorHandle: handle, location: "Austin, TX",
                 isCommunity: community, type: .run, date: date, title: "Session", caption: nil,
                 statLine: "5.0 mi · 42:00", prBadge: nil)
    }

    private func scratchDefaults(_ name: String) -> UserDefaults {
        let d = UserDefaults(suiteName: "perf.\(name).\(UUID().uuidString)")!
        return d
    }

    private func tileImage() -> UIImage {
        // The wall's real render geometry: 300×400 pt at pixelRatio 2 = 600×800 px, 1.92 MB drawn.
        UIGraphicsImageRenderer(size: CGSize(width: 600, height: 800),
                                format: {
                                    let f = UIGraphicsImageRendererFormat.default()
                                    f.scale = 1
                                    return f
                                }()).image { ctx in
            UIColor.gray.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
        }
    }

    // MARK: The moderation snapshot

    /// The assembly runs off the main actor, so it cannot call `ModerationStore` (which is
    /// `@MainActor`) and carries a value snapshot of it instead. That snapshot re-expresses
    /// `isVisible`, and a re-expression is exactly the kind of thing that silently drifts from the
    /// original. This is the tripwire: every combination has to agree.
    @Test func moderationSnapshotAnswersExactlyWhatTheStoreWould() {
        let store = ModerationStore(defaults: scratchDefaults("moderation"))
        let blockedPost = item("blockedathlete", at: Date())
        let reportedPost = item("fine", at: Date())
        let visiblePost = item("fine", at: Date())
        let ownPost = item(nil, at: Date(), community: false)

        store.block("blockedathlete")
        store.report(reportedPost.id)

        let snapshot = CommunityView.FeedInputs(blocked: store.blockedHandles,
                                                reported: store.reportedPosts)
        for post in [blockedPost, reportedPost, visiblePost, ownPost] {
            #expect(snapshot.isVisible(post) == store.isVisible(post),
                    "snapshot and store disagree about \(post.authorHandle ?? "own post")")
        }
        #expect(snapshot.isVisible(visiblePost))
        #expect(!snapshot.isVisible(blockedPost))
        #expect(!snapshot.isVisible(reportedPost))
    }

    // MARK: The ring row's one pass

    /// The Following row needs each followed athlete's newest post. It used to scan the whole
    /// assembled well once PER athlete, inside `body` — 24,000 comparisons at 20 follows against a
    /// 1,200-post feed, re-run on every reveal of the next twelve tiles. One pass, built with the
    /// feed.
    @Test func latestByAuthorKeepsTheNewestPostPerAuthor() {
        let now = Date()
        let feed = [
            item("maya", at: now.addingTimeInterval(-60)),
            item("theo", at: now.addingTimeInterval(-3600)),
            item("maya", at: now.addingTimeInterval(-7200)),   // older — must not win
            item(nil, at: now),                                 // no handle — must not crash or count
            item("theo", at: now.addingTimeInterval(-30)),      // newer — must win
        ]
        let latest = CommunityView.latestByAuthor(feed)
        #expect(latest.count == 2)
        #expect(latest["maya"] == now.addingTimeInterval(-60))
        #expect(latest["theo"] == now.addingTimeInterval(-30))
    }

    @Test func latestByAuthorIsEmptyForAnEmptyFeed() {
        #expect(CommunityView.latestByAuthor([]).isEmpty)
    }

    // MARK: The assembly is pure

    /// Same inputs, same wall — the property that lets it move off the main actor at all. (If it
    /// read a clock, a store or SwiftData, running it on a background thread would be a race.)
    @Test func assemblyIsAPureFunctionOfItsInputs() {
        let input = CommunityView.FeedInputs(wellCap: 60)
        let a = CommunityView.assembleFeed(input)
        let b = CommunityView.assembleFeed(input)
        #expect(a.map(\.id) == b.map(\.id))
        #expect(!a.isEmpty, "the seeded community should always produce a wall")
    }

    /// The Global well is capped, and deepening it is what the bottom-of-wall loader does. A cap
    /// that stopped being honoured would hand SwiftUI the whole multi-thousand-post seed.
    @Test func theGlobalWellHonoursItsCap() {
        let small = CommunityView.assembleFeed(CommunityView.FeedInputs(wellCap: 40))
        let deep = CommunityView.assembleFeed(CommunityView.FeedInputs(wellCap: 400))
        #expect(small.count <= 40)
        #expect(deep.count > small.count, "deepening the well must reach further into the seed")
    }

    /// Friends scope is scoped from the FULL stream, never from the capped well — a followed
    /// athlete's post must not fall off the end of a cap they never chose.
    @Test func friendsScopeShowsOnlyFollowedAthletesAndYourOwn() {
        let mine = item(nil, at: Date(), community: false)
        let input = CommunityView.FeedInputs(own: [mine], following: ["sub3maya"],
                                             scopeIsFollowing: true)
        let feed = CommunityView.assembleFeed(input)
        #expect(feed.contains { $0.id == mine.id }, "your own post always belongs on your Friends wall")
        for post in feed where post.isCommunity {
            #expect(post.authorHandle == "sub3maya",
                    "Friends carried a post from \(post.authorHandle ?? "?"), who isn't followed")
        }
    }

    // MARK: One build per set of inputs

    /// **The flip storm (2026-08-29).** Every Profile ↔ Community slider flip tears `CommunityView`
    /// down and builds a new one, and each new one starts its own assembly. During the ~650 ms
    /// first build a flip storm therefore had N detached tasks sorting and `spaced`ing ~2,900 posts
    /// against each other for cores, all to produce the same answer N times — the athlete waiting
    /// through every copy. No UI test flips fast enough to catch it, so it is pinned here where the
    /// concurrency can be stated exactly.
    @Test func aStormOfSimultaneousCallersCostsOneAssembly() async {
        CommunityFeedAssembly.resetCounters()
        let input = CommunityView.FeedInputs(wellCap: 400)
        let callers = 8

        let walls = await withTaskGroup(of: Int.self) { group in
            for _ in 0..<callers {
                group.addTask { @MainActor in
                    await CommunityFeedAssembly.build(key: "storm", input: input).items.count
                }
            }
            return await group.reduce(into: [Int]()) { $0.append($1) }
        }

        #expect(CommunityFeedAssembly.requests == callers)
        #expect(CommunityFeedAssembly.builds == 1,
                "\(callers) simultaneous callers ran \(CommunityFeedAssembly.builds) assemblies")
        // Everyone got a real wall, and the SAME one — coalescing must not hand anybody a stub.
        #expect(walls.count == callers)
        #expect(Set(walls).count == 1 && walls[0] > 0, "callers were served different walls: \(Set(walls))")
    }

    /// The other half of the contract: sharing is keyed on the inputs, so two callers who would
    /// have computed DIFFERENT walls still each get their own. (Friends and Global are the live
    /// case — flipping the scope tab mid-build must not serve the previous scope's wall.)
    @Test func callersWantingDifferentWallsEachGetTheirOwn() async {
        CommunityFeedAssembly.resetCounters()
        let global = CommunityView.FeedInputs(wellCap: 40)
        let friends = CommunityView.FeedInputs(following: ["sub3maya"], scopeIsFollowing: true)

        async let a = CommunityFeedAssembly.build(key: "global", input: global)
        async let b = CommunityFeedAssembly.build(key: "friends", input: friends)
        let (globalWall, friendsWall) = await (a, b)

        #expect(CommunityFeedAssembly.builds == 2)
        #expect(globalWall.items.count <= 40)
        for post in friendsWall.items where post.isCommunity {
            #expect(post.authorHandle == "sub3maya", "the friends caller was served the global wall")
        }
    }

    // MARK: The route-snapshot cache

    /// A tile that scrolls away and comes back must REUSE its map. `LazyVGrid` discards the cell's
    /// `@State`, so without a synchronous read of the shared cache the tile drew a silhouette and
    /// crossfaded a map it already had — a visible pop-in on every scroll-back.
    @Test func aRenderedMapIsReusedNotReRendered() {
        FeedRouteSnapshots.resetForTesting()
        let post = UUID()
        let size = FeedTileMedia.tileSize
        #expect(FeedRouteSnapshots.cachedImage(post: post, style: .standard, scheme: .light,
                                               size: size, routeWidth: FeedTileMedia.tileRouteWidth) == nil)
        FeedRouteSnapshots.storeForTesting(tileImage(), post: post, style: .standard,
                                           scheme: .light, size: size,
                                           routeWidth: FeedTileMedia.tileRouteWidth)
        #expect(FeedRouteSnapshots.cachedImage(post: post, style: .standard, scheme: .light,
                                               size: size, routeWidth: FeedTileMedia.tileRouteWidth) != nil,
                "the wall tile's synchronous lookup missed the image its own render just stored")
    }

    /// The key carries appearance, size and stroke width because those genuinely change the
    /// picture: a dark-mode wall pairs to a dark basemap, the profile cover renders the same run
    /// wide and short, and a small tile wants a thicker trace. Collapsing any of them would serve
    /// the wrong image; leaving one out of the LOOKUP would re-render on every appearance.
    @Test func theCacheKeySeparatesAppearanceSizeAndStroke() {
        FeedRouteSnapshots.resetForTesting()
        let post = UUID()
        let size = FeedTileMedia.tileSize
        FeedRouteSnapshots.storeForTesting(tileImage(), post: post, style: .standard,
                                           scheme: .light, size: size,
                                           routeWidth: FeedTileMedia.tileRouteWidth)
        #expect(FeedRouteSnapshots.cachedImage(post: post, style: .standard, scheme: .dark,
                                               size: size, routeWidth: FeedTileMedia.tileRouteWidth) == nil,
                "a dark-mode wall must not be served the light basemap")
        #expect(FeedRouteSnapshots.cachedImage(post: post, style: .standard, scheme: .light,
                                               size: CGSize(width: 430, height: 930),
                                               routeWidth: FeedTileMedia.tileRouteWidth) == nil,
                "the full-bleed page must not be served a 3:4 tile to crop")
        #expect(FeedRouteSnapshots.cachedImage(post: post, style: .standard, scheme: .light,
                                               size: size, routeWidth: 3) == nil,
                "a different stroke width is a different picture")
    }

    /// The bug this closes: the cache was a dictionary that only ever grew. Each wall tile is
    /// 1.9 MB of decoded pixels and each full-bleed page 6.4 MB, so a long browse held hundreds of
    /// megabytes nothing could release. Both budgets hold however far the athlete scrolls.
    @Test func theSnapshotCacheCannotGrowWithoutBound() {
        FeedRouteSnapshots.resetForTesting()
        let image = tileImage()
        for _ in 0..<(FeedRouteSnapshots.entryBudget * 3) {
            FeedRouteSnapshots.storeForTesting(image, post: UUID(), style: .standard,
                                               scheme: .light, size: FeedTileMedia.tileSize,
                                               routeWidth: FeedTileMedia.tileRouteWidth)
        }
        #expect(FeedRouteSnapshots.residentCount <= FeedRouteSnapshots.entryBudget,
                "\(FeedRouteSnapshots.residentCount) images resident against a budget of \(FeedRouteSnapshots.entryBudget)")
        #expect(FeedRouteSnapshots.residentBytes <= FeedRouteSnapshots.byteBudget,
                "\(FeedRouteSnapshots.residentBytes / 1_048_576) MB resident against an \(FeedRouteSnapshots.byteBudget / 1_048_576) MB budget")
        FeedRouteSnapshots.resetForTesting()
    }

    /// Eviction is least-recently-used, not arbitrary: the tiles the athlete just scrolled past
    /// are the ones a scroll-back will ask for, and re-rendering those is exactly the pop-in the
    /// cache exists to prevent.
    @Test func theOldestUntouchedMapIsTheOneEvicted() {
        FeedRouteSnapshots.resetForTesting()
        let image = tileImage()
        let size = FeedTileMedia.tileSize
        let width = FeedTileMedia.tileRouteWidth
        func store(_ post: UUID) {
            FeedRouteSnapshots.storeForTesting(image, post: post, style: .standard,
                                               scheme: .light, size: size, routeWidth: width)
        }
        func cached(_ post: UUID) -> UIImage? {
            FeedRouteSnapshots.cachedImage(post: post, style: .standard, scheme: .light,
                                           size: size, routeWidth: width)
        }
        let first = UUID(), second = UUID()
        store(first)
        store(second)
        // Reading `first` makes it the most recent, so `second` becomes the stale one.
        _ = cached(first)

        // Fill to exactly the byte budget — still nothing evicted. Checked through `residentCount`
        // rather than by reading `second`: a read IS a touch, and touching it here would make it
        // the most recent entry and invert the very thing under test.
        let perImage = 600 * 800 * 4
        let fits = FeedRouteSnapshots.byteBudget / perImage
        for _ in 0..<(fits - 2) { store(UUID()) }
        #expect(FeedRouteSnapshots.residentCount == fits, "evicted while still inside the budget")

        store(UUID())   // one image over the line
        #expect(cached(second) == nil, "the least recently used entry was not the one dropped")
        #expect(cached(first) != nil, "a recently read entry was dropped ahead of a staler one")
        FeedRouteSnapshots.resetForTesting()
    }

    /// A memory warning drops the pixels, and the surfaces re-render. Pinned because the alternative
    /// — riding a warning out with 80 MB of route maps in hand — is how a social surface gets the
    /// app jetsammed.
    @Test func aMemoryWarningReleasesEveryHeldBitmap() {
        FeedRouteSnapshots.resetForTesting()
        FeedRouteSnapshots.storeForTesting(tileImage(), post: UUID(), style: .standard,
                                           scheme: .light, size: FeedTileMedia.tileSize,
                                           routeWidth: FeedTileMedia.tileRouteWidth)
        #expect(FeedRouteSnapshots.residentCount == 1)
        FeedRouteSnapshots.purge()
        #expect(FeedRouteSnapshots.residentCount == 0)
        #expect(FeedRouteSnapshots.residentBytes == 0)
    }

    // MARK: The cheap directory (2026-08-29 load pass)

    /// The wall card resolved by the CHEAP prefix walk is the same card the whole-career fold
    /// picks. This is the contract the 611 ms saving rests on: `CommunityGenerator` stopped folding
    /// ~770,000 sessions at launch and now walks each athlete only as far as their post.
    @Test func theCheapLeadWalkAgreesWithTheWholeCareerFold() {
        let clock = CommunityLedger.Clock(Date())
        var checked = 0
        for athlete in CommunityDirectory.all().filter(\.isSample).prefix(140) {
            let city = athlete.routeCity
            let full = CommunityLedger.lifetime(handle: athlete.handle, primary: athlete.primaryType,
                                                city: city, count: athlete.totalWorkouts,
                                                clock: clock, lead: athlete.ledgerLead, detail: false)
            let cheap = CommunityLedger.lead(handle: athlete.handle, primary: athlete.primaryType,
                                             city: city, count: athlete.totalWorkouts,
                                             clock: clock, lead: athlete.ledgerLead)
            #expect(cheap?.session == full.leadSession,
                    "@\(athlete.handle): prefix walk picked a different wall card")
            #expect(cheap?.index == full.leadIndex,
                    "@\(athlete.handle): prefix walk put the card at a different ledger index")
            checked += 1
        }
        #expect(checked > 100)
    }

    /// Stopping a walk early returns the same prefix the full walk would. The profile grid pages on
    /// this (it used to walk a 900-session career to show thirty tiles), so a divergence here would
    /// silently re-deal every visited athlete's grid.
    @Test func aPrefixWalkIsTheSamePrefixAsTheWholeWalk() {
        let clock = CommunityLedger.Clock(Date())
        for athlete in CommunityDirectory.all().filter({ $0.isSample && $0.totalWorkouts > 60 }).prefix(12) {
            let city = athlete.routeCity
            let whole = CommunityLedger.sessions(handle: athlete.handle, primary: athlete.primaryType,
                                                 city: city, count: athlete.totalWorkouts,
                                                 clock: clock, lead: athlete.ledgerLead)
            let page = CommunityLedger.sessions(handle: athlete.handle, primary: athlete.primaryType,
                                                city: city, count: athlete.totalWorkouts,
                                                clock: clock, lead: athlete.ledgerLead, limit: 30)
            #expect(page.count == 30, "@\(athlete.handle): a page of 30 came back with \(page.count)")
            #expect(page == Array(whole.prefix(30)),
                    "@\(athlete.handle): the paged walk and the full walk disagree")
        }
    }

    /// The lazy aggregates still equal the fold they replaced — `dayStreak` and `totalDistanceM`
    /// are computed on read now, and a computed property that answered differently from the stored
    /// one would put a profile's numbers back out of step with its grid.
    @Test func theLazyAggregatesEqualTheirFold() {
        for athlete in CommunityDirectory.all().filter(\.isSample).prefix(40) {
            let life = CommunityLedger.lifetime(
                handle: athlete.handle, primary: athlete.primaryType,
                city: athlete.routeCity,
                count: athlete.totalWorkouts, clock: CommunityDirectory.seedClock,
                lead: athlete.ledgerLead, detail: false)
            #expect(athlete.dayStreak == life.streakDays, "@\(athlete.handle): streak drifted")
            #expect(abs(athlete.totalDistanceM - life.distanceM) < 1,
                    "@\(athlete.handle): lifetime distance drifted")
        }
    }

    // MARK: The top of the wall

    /// **The first screenful has to read like a page people are using, not one minted seconds ago**
    /// (owner report 2026-08-29: "3 to 5 minutes ago" on every tile of the first screen).
    ///
    /// Two mechanisms had to change and both are pinned here, at three times of day — the failure
    /// was worst at dawn, when 60% of the community's training window opened at once and roughly
    /// three hundred posts landed inside one hour. Community athletes now start across the whole
    /// waking day (`CommunityLedger.peakHour`) and, like real people, post only some of what they
    /// train (`CommunityLedger.isLead`).
    @Test func theWallsFirstScreenfulReachesBackHours() {
        for hour in [7.25, 12.5, 19.0] {
            let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(hour * 3600)
            let clock = CommunityLedger.Clock(now)
            let dates = CommunityGenerator.generate(now: now, clock: clock)
                .flatMap(\.posts).map(\.date).sorted(by: >)
            func ageMin(_ i: Int) -> Double { now.timeIntervalSince(dates[i]) / 60 }
            print(String(format: "WALL-AGE %.2fh  #1=%.0fm #6=%.0fm #12=%.0fm #30=%.0fm #60=%.0fm #120=%.0fm #300=%.1fh",
                         hour, ageMin(0), ageMin(5), ageMin(11), ageMin(29), ageMin(59),
                         ageMin(119), ageMin(299) / 60))
            // The floors state the DEFECT, not today's numbers: the wall used to open with thirty
            // tiles inside five minutes, so every one of them printed the same relative time. A
            // screenful has to cross from "minutes" into "tens of minutes", the four screenfuls
            // after it into hours. These must hold at the community's densest hour (dawn), so the
            // quiet hours clear them several times over.
            #expect(ageMin(0) < 25, "at \(hour)h the newest post is \(Int(ageMin(0))) min old — a dead wall")
            #expect(ageMin(11) > 10,
                    "at \(hour)h the first 12 tiles span only \(Int(ageMin(11))) min")
            #expect(ageMin(29) > 30,
                    "at \(hour)h the first 30 tiles span only \(Int(ageMin(29))) min")
            #expect(ageMin(119) > 120,
                    "at \(hour)h tile 120 is \(Int(ageMin(119))) min old")
            // And it has to be a curve, not a block: the thirtieth tile is several times the age of
            // the sixth. A wall that fails this is a smear even if it clears the floors above.
            #expect(ageMin(29) > ageMin(5) * 2.5,
                    "at \(hour)h tiles 6 and 30 are \(Int(ageMin(5))) and \(Int(ageMin(29))) min — a block, not a page")
            // Still a busy community, not a ghost town: a day's worth of posts is a real page.
            let inADay = dates.filter { now.timeIntervalSince($0) < 86_400 }.count
            #expect(inADay > 200, "only \(inADay) posts in the last 24h")
        }
    }

    // MARK: The bundled routes

    /// The route bundle ships each polyline as one base64 string and decodes it on demand. An
    /// encoder/decoder mismatch would be invisible until a tile drew a scribble, so every bundled
    /// loop has to measure the length it prints.
    @Test func everyBundledLoopDecodesToTheLengthItPrints() {
        var loops = 0
        for city in CommunityRoutes.auditCities {
            for loop in CommunityRoutes.auditLoops(city: city) {
                #expect(loop.pts.count > 10, "\(city): a loop decoded to \(loop.pts.count) points")
                let drawn = Self.polylineKm(loop.pts)
                #expect(abs(drawn - loop.km) < 0.05,
                        "\(city): a loop prints \(loop.km) km but draws \(String(format: "%.2f", drawn))")
                loops += 1
            }
        }
        #expect(loops > 900, "only \(loops) bundled loops")
    }

    /// Lengths come from the launch parse; polylines do not. `loopKms` is what the session ledger
    /// asks for every athlete's city, and it must answer without materializing geometry.
    @Test func loopLengthsMatchTheirGeometryPoolOrder() {
        for city in CommunityRoutes.auditCities.sorted().prefix(20) {
            let kms = CommunityRoutes.loopKms(city: city, discipline: .run)
            #expect(!kms.isEmpty, "\(city) has no run loops")
            for (i, km) in kms.enumerated() {
                let loop = CommunityRoutes.loop(city: city, discipline: .run, slot: i, offset: 0)
                #expect(loop?.km == km, "\(city) run slot \(i): index says \(km), pool says \(loop?.km ?? -1)")
            }
        }
    }

    /// Flat-earth polyline length — the same sum `fetch_community_routes.py` writes.
    private static func polylineKm(_ pts: [[Double]]) -> Double {
        var m = 0.0
        for i in 1..<max(pts.count, 1) {
            let dLat = (pts[i][0] - pts[i - 1][0]) * 111_132
            let dLon = (pts[i][1] - pts[i - 1][1]) * 111_320 * cos(pts[i - 1][0] * .pi / 180)
            m += (dLat * dLat + dLon * dLon).squareRoot()
        }
        return m / 1000
    }
}
