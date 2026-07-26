import Foundation
import Testing
@testable import Momentum

/// What Today's sport picker shows for a planned session — which is also what its Start button
/// claims it will do.
///
/// The picker was hardcoded to `.run` and never moved off it. On a running day that was invisible;
/// on every other day the deck read "TODAY'S PLAN — Strength — 4 exercises" directly above a large
/// primary button saying "Start run". The most prominent control on the home screen advertised the
/// opposite of the card it sat under.
struct TodaySportPickerTests {

    /// `workoutType` is derived from the stored `sportType` string, so set that.
    private func session(_ d: Discipline, type: WorkoutType? = nil) -> PlannedSession {
        let s = PlannedSession()
        s.discipline = d
        s.sportType = type?.rawValue
        return s
    }

    @Test func everyDisciplineMapsToItsOwnSport() {
        #expect(WorkoutType.forDiscipline(.running) == .run)
        #expect(WorkoutType.forDiscipline(.cycling) == .ride)
        #expect(WorkoutType.forDiscipline(.walking) == .walk)
        #expect(WorkoutType.forDiscipline(.strength) == .strength)
    }

    /// The regression this whole change exists for.
    @Test func aStrengthDayDoesNotOfferToStartARun() {
        let picked = WorkoutType.forPlanned(session(.strength))
        #expect(picked == .strength)
        #expect(picked != .run, "a planned strength session must never leave the picker on Run")
        #expect(picked.isStrengthStyle)
    }

    /// A planned swim/yoga/row must not collapse into its discipline bucket — "Start run" for a
    /// planned swim would be the same bug wearing a different hat.
    @Test func theSessionsPreciseSportWinsOverTheBucket() {
        // A precise sport recorded on the session overrides the coarse discipline.
        let swim = session(.running, type: .swimming)
        #expect(WorkoutType.forPlanned(swim) == .swimming)

        let yoga = session(.strength, type: .yoga)
        #expect(WorkoutType.forPlanned(yoga) == .yoga)

        let trail = session(.running, type: .trailRun)
        #expect(WorkoutType.forPlanned(trail) == .trailRun)
    }

    /// With no precise sport set, fall back to the discipline rather than to a hardcoded default.
    @Test func fallsBackToTheDisciplineNotToRun() {
        #expect(WorkoutType.forPlanned(session(.cycling)) == .ride)
        #expect(WorkoutType.forPlanned(session(.walking)) == .walk)
        #expect(WorkoutType.forPlanned(session(.running)) == .run)
    }
}
