import Testing
import Foundation
@testable import Momentum

/// The seeded community lives in real TOWNS, not on 65 downtown pins.
///
/// Before 2026-08-29 every one of the ~2,863 athletes sat within ±0.02° of one of 65 city
/// coordinates, so the globe drew 65 knots and forty-four people in a row said "Austin, TX".
/// `CommunityPlaces` (bundled `Resources/CommunityPlaces.json`, 2,990 reverse-geocoded places
/// across those 65 metros) gives each athlete a real home town inside their metro while their
/// ROUTES still come from the metro's bundled street loops.
///
/// The three failure modes these tests exist for:
/// 1. the JSON silently not being in the bundle (a resource that isn't copied fails at runtime,
///    not at build time — the table would decode to empty and everyone would quietly go back to
///    downtown);
/// 2. a regeneration reintroducing non-English names (the fetch came back with 渋谷区 / 文京区 for
///    Tokyo the first time, which reads as a rendering fault rather than a person's home town);
/// 3. the town name reaching `CommunityRoutes` as a route key — a suburb has no bundled loop, so
///    that would strip the maps off the whole community without failing anything else.
@MainActor
struct CommunityPlacesTests {

    private func sample() -> [CommunityAthlete] {
        let all = CommunityDirectory.all()
        return stride(from: 8, to: all.count, by: 3).map { all[$0] }
    }

    // MARK: The bundle

    @Test func everyMetroTheCommunityDrawsFromHasRealTowns() {
        let bundled = Set(CommunityPlaces.auditMetros)
        #expect(!bundled.isEmpty, "CommunityPlaces.json did not decode — is it in the app bundle?")
        for metro in CommunityGenerator.seedMetros {
            #expect(bundled.contains(metro), "\(metro) has no bundled places")
            let places = CommunityPlaces.auditPlaces(metro: metro)
            // Miami's rings mostly land in the Atlantic, which is exactly the behaviour we want
            // (water filters itself out), and it still ships 20. Anything under 8 would read as
            // tight as the single pin this replaced.
            #expect(places.count >= 8, "\(metro): only \(places.count) places")
        }
    }

    @Test func everyPlaceHasARealNameAndACoordinate() {
        for metro in CommunityPlaces.auditMetros {
            for p in CommunityPlaces.auditPlaces(metro: metro) {
                #expect(!p.name.trimmingCharacters(in: .whitespaces).isEmpty, "\(metro): empty name")
                #expect(p.name.count <= 48, "\(metro): implausible name \(p.name)")
                #expect(p.lat >= -90 && p.lat <= 90 && p.lon >= -180 && p.lon <= 180,
                        "\(metro): \(p.name) is off the planet")
                #expect(p.lat != 0 || p.lon != 0, "\(metro): \(p.name) sits at null island")
            }
        }
    }

    /// The Tokyo bug: the geocoder answers in the local script unless asked for English, and a
    /// location line nobody can read scans as a rendering fault. Accented Latin is fine and real
    /// ("Neukölln", "Vélizy-Villacoublay"); another script, a mojibake artefact or a replacement
    /// character is not.
    @Test func noPlaceNameArrivesInAnotherScriptOrAsMojibake() {
        for metro in CommunityPlaces.auditMetros {
            for p in CommunityPlaces.auditPlaces(metro: metro) {
                for scalar in p.name.unicodeScalars where !scalar.isASCII {
                    let readable = scalar.properties.name ?? ""
                    #expect(readable.hasPrefix("LATIN"),
                            "\(metro): \(p.name) is not Latin script (\(readable))")
                }
                #expect(!p.name.contains("\u{FFFD}"), "\(metro): \(p.name) carries a replacement char")
                // The classic UTF-8-read-as-Latin-1 signatures.
                #expect(!p.name.contains("Ã") && !p.name.contains("â€"),
                        "\(metro): \(p.name) looks like mojibake")
            }
        }
    }

    // MARK: The spread

    @Test func athletesSpreadAcrossTheirMetrosTownsInsteadOfOnePin() {
        var byMetro: [String: [String]] = [:]
        for a in CommunityDirectory.all() where a.isSample {
            guard let metro = a.metro, let loc = a.location else { continue }
            byMetro[metro, default: []].append(loc)
        }
        #expect(!byMetro.isEmpty)
        for (metro, locations) in byMetro where locations.count >= 40 {
            let distinct = Set(locations)
            #expect(distinct.count >= 8,
                    "\(metro): \(locations.count) athletes across only \(distinct.count) towns")
            // The core city keeps a population-shaped plurality (it holds ~a third of a real
            // metro) but must never be everyone again.
            let top = Dictionary(grouping: locations, by: { $0 }).values.map(\.count).max() ?? 0
            #expect(Double(top) / Double(locations.count) <= 0.6,
                    "\(metro): \(top)/\(locations.count) athletes still share one town")
        }
    }

    @Test func theCommunityNamesFarMoreThanSixtyFiveHomeTowns() {
        let towns = Set(CommunityDirectory.all().compactMap(\.location))
        #expect(towns.count >= 400, "the whole community only names \(towns.count) places")
    }

    @Test func everyAthleteLivesInABundledTownOfTheirOwnMetro() {
        for a in sample() {
            guard let metro = a.metro, let loc = a.location else { continue }
            let displays = Set(CommunityPlaces.auditPlaces(metro: metro).map(\.display))
            #expect(displays.contains(loc), "@\(a.handle) says \(loc), which is not a \(metro) place")
        }
    }

    /// Their globe dot sits on the town they name, not on the metro's downtown.
    @Test func theGlobeDotSitsOnTheTownTheyName() {
        var movedOffDowntown = 0
        var checked = 0
        for a in sample() {
            guard let metro = a.metro,
                  let home = CommunityPlaces.auditPlaces(metro: metro).first(where: { $0.display == a.location })
            else { continue }
            checked += 1
            // The generator keeps its ±0.02° jitter (≈2.2 km per axis) around the home place.
            #expect(abs(a.lat - home.lat) <= 0.021 && abs(a.lon - home.lon) <= 0.021,
                    "@\(a.handle)'s dot is \(a.lat),\(a.lon) but \(home.name) is \(home.lat),\(home.lon)")
            if home.display != metro { movedOffDowntown += 1 }
        }
        #expect(checked > 100)
        #expect(Double(movedOffDowntown) / Double(checked) >= 0.4,
                "only \(movedOffDowntown)/\(checked) athletes live outside their metro's core")
    }

    // MARK: The route key

    /// A town is a HOME, never a route key. If `location` ever reaches `CommunityRoutes` again,
    /// every lookup misses and the whole community loses its maps without one number changing.
    @Test func routesAreStillKeyedByTheMetroNotTheTown() {
        let bundled = Set(CommunityRoutes.auditCities)
        for a in CommunityDirectory.all() where a.isSample {
            #expect(bundled.contains(a.routeCity),
                    "@\(a.handle) would draw routes from \(a.routeCity), which has no bundled loops")
        }
    }

    @Test func theCommunityStillDrawsMaps() {
        var routed = 0
        var gps = 0
        for a in CommunityDirectory.all().prefix(200) where a.isSample {
            for tile in CommunityDirectory.gridPosts(for: a, limit: 6) where tile.type.isGPS {
                gps += 1
                if (tile.routeLatLon?.count ?? 0) > 1 { routed += 1 }
            }
        }
        #expect(gps > 100)
        // Structured sessions and trail runs ship mapless on purpose, so this is a floor, not a
        // rate — the failure it catches is maps vanishing wholesale.
        #expect(Double(routed) / Double(gps) >= 0.3, "only \(routed)/\(gps) GPS tiles carry a route")
    }

    // MARK: The identity contract

    /// **The rng draw order in `CommunityGenerator.athlete(index:)` is a contract.** Name, city and
    /// discipline come off one sequential generator; inserting, removing or reordering a draw
    /// silently turns every seeded athlete into a different person. The 2026-08-29 places pass
    /// spent NO new draw (the home is picked from a separate handle hash, and the two jitter draws
    /// that were already there were kept in place), which is why the tuples below are the same
    /// ones the directory produced before it. `metro` is the drawn city; `location` is the town
    /// chosen off the side hash.
    @Test func theDrawOrderStillNamesTheSamePeople() {
        let all = CommunityDirectory.all()
        for (index, handle, name, metro, sport, workouts) in Self.identityGoldens {
            let a = all[index]
            #expect(a.handle == handle, "index \(index): @\(a.handle) != @\(handle)")
            #expect(a.name == name, "index \(index): \(a.name) != \(name)")
            #expect(a.metro == metro, "index \(index): \(a.metro ?? "-") != \(metro)")
            #expect(a.primarySport?.rawValue == sport, "index \(index): sport moved")
            #expect(a.totalWorkouts == workouts, "index \(index): body of work moved")
        }
    }

    /// `(directory index, handle, name, metro, sport, sessions)`. Computed from an INDEPENDENT
    /// replication of the draw order (a 60-line Python model of `SeededRNG` plus the five draws),
    /// not copied out of a run of this code, so they pin the sequence itself rather than whatever
    /// the generator happens to produce. Index 0-7 are the featured eight; 8 + n is generated
    /// athlete n.
    private static let identityGoldens: [(Int, String, String, String, String, Int)] = [
        (8, "thebiancah", "Bianca Haddad", "Portland, OR", "strength", 718),
        (9, "sven103", "Sven Costa", "Ann Arbor, MI", "yoga", 16),
        (15, "rideswithsami", "Sami Lowe", "St. Louis, MO", "ride", 596),
        (50, "owen.berg", "Owen Berg", "Austin, TX", "run", 336),
        (145, "itskofi2", "Kofi Costa", "Dublin", "run", 47),
        (507, "thetomasw", "Tomas Walsh", "Madrid", "run", 6),
        (1008, "trainswithcole", "Cole Nguyen", "St. Louis, MO", "strength", 16),
        (1507, "sami104", "Sami Walsh", "Toronto", "run", 47),
        (2008, "noahn88", "Noah Nguyen", "Atlanta, GA", "ride", 237),
        (2508, "nairmiles2", "Greta Nair", "Sydney", "ride", 281),
        (2869, "ereed", "Esme Reed", "Asheville, NC", "trailRun", 10),
        (2870, "lpark", "Lucia Park", "Portland, OR", "swimming", 24),
    ]
}
