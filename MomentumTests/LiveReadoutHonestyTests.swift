import Testing
@testable import Momentum

/// The live page must never show a reading nobody took (CLAUDE.md: honest first). A GPS outage
/// freezes the engine's smoothed pace at its last value, so the CURRENT pace cell has to go to a
/// placeholder while AVERAGE pace keeps degrading honestly off the real clock and real distance.
struct LiveReadoutHonestyTests {

    // MARK: Running

    @Test func currentPaceReadsTheSmoothedValueWhileTheSignalHolds() {
        let cell = CardioViewModel.currentPaceCell(smoothedPaceSPerKm: 335,
                                                   gpsLost: false, cycling: false, unit: .imperial)
        #expect(cell.value == "8:59")
        #expect(cell.unit == "/mi")
    }

    /// The bug: mid-tunnel the page read "9:11 /mi" beside a Signal of "Lost".
    @Test func currentPaceBlanksWhileTheSignalIsLost() {
        let cell = CardioViewModel.currentPaceCell(smoothedPaceSPerKm: 335,
                                                   gpsLost: true, cycling: false, unit: .imperial)
        #expect(cell.value == "--:--")
    }

    /// The unit stays put so the row keeps its width — losing signal must not reflow the page.
    @Test func theBlankedPaceKeepsItsUnitInBothSystems() {
        let imperial = CardioViewModel.currentPaceCell(smoothedPaceSPerKm: 335,
                                                       gpsLost: true, cycling: false, unit: .imperial)
        let metric = CardioViewModel.currentPaceCell(smoothedPaceSPerKm: 335,
                                                     gpsLost: true, cycling: false, unit: .metric)
        #expect(imperial.unit == "/mi")
        #expect(metric.unit == "/km")
        #expect(metric.value == "--:--")
    }

    @Test func currentPaceBlanksBeforeTheFirstFixLands() {
        let cell = CardioViewModel.currentPaceCell(smoothedPaceSPerKm: 0,
                                                   gpsLost: false, cycling: false, unit: .metric)
        #expect(cell.value == "--:--")
        #expect(cell.unit == "/km")
    }

    // MARK: Riding — a frozen value here is worse than stale

    /// `Formatters.speed(ms: 0)` renders "0.0", which asserts the rider has STOPPED. Blanking a
    /// lost signal must not be spelled that way.
    @Test func currentSpeedBlanksRatherThanClaimingZero() {
        let cell = CardioViewModel.currentPaceCell(smoothedPaceSPerKm: 120,
                                                   gpsLost: true, cycling: true, unit: .imperial)
        #expect(cell.value == "--")
        #expect(cell.value != "0.0")
        #expect(cell.unit == "mph")
    }

    @Test func currentSpeedReadsWhileTheSignalHolds() {
        // 120 s/km → 8.33 m/s → 30.0 km/h.
        let cell = CardioViewModel.currentPaceCell(smoothedPaceSPerKm: 120,
                                                   gpsLost: false, cycling: true, unit: .metric)
        #expect(cell.value == "30.0")
        #expect(cell.unit == "km/h")
    }

    @Test func nonFiniteSmoothedPaceCannotReachTheFormatter() {
        let cell = CardioViewModel.currentPaceCell(smoothedPaceSPerKm: .infinity,
                                                   gpsLost: false, cycling: false, unit: .imperial)
        #expect(cell.value == "--:--")
    }
}
