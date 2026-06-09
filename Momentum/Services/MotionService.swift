import Foundation
import CoreMotion

/// Cadence + elevation source (PRD §8.3). `CMPedometer` supplies running cadence (steps/min);
/// `CMAltimeter` accumulates positive relative-altitude deltas for elevation gain. Hardware-only
/// signals — validated on device, not simulator.
@MainActor
final class MotionService: MotionServing {
    private let pedometer = CMPedometer()
    private let altimeter = CMAltimeter()

    private(set) var cadenceStepsPerMin: Int?
    private(set) var elevationGainM: Double = 0
    private var lastAltitudeM: Double?

    var isAuthorized: Bool { CMPedometer.authorizationStatus() == .authorized }

    func requestAuthorization() {
        // CoreMotion prompts on first query; a throwaway query primes the permission sheet.
        pedometer.queryPedometerData(from: Date(), to: Date()) { _, _ in }
    }

    func start() {
        cadenceStepsPerMin = nil
        elevationGainM = 0
        lastAltitudeM = nil

        if CMPedometer.isCadenceAvailable() {
            pedometer.startUpdates(from: Date()) { [weak self] data, _ in
                guard let cadence = data?.currentCadence?.doubleValue else { return }
                Task { @MainActor in
                    self?.cadenceStepsPerMin = Int((cadence * 60).rounded()) // steps/s → steps/min
                }
            }
        }
        if CMAltimeter.isRelativeAltitudeAvailable() {
            altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
                guard let meters = data?.relativeAltitude.doubleValue else { return }
                Task { @MainActor in self?.accumulateAltitude(meters) }
            }
        }
    }

    func stop() {
        pedometer.stopUpdates()
        altimeter.stopRelativeAltitudeUpdates()
    }

    private func accumulateAltitude(_ meters: Double) {
        if let last = lastAltitudeM, meters > last {
            elevationGainM += meters - last
        }
        lastAltitudeM = meters
    }
}
