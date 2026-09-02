import Testing
import Foundation
import AVFoundation
@testable import Momentum

struct RouteReplayPlaybackTests {
    private let metresPerDegree = 111_320.0

    private func eastLine(lengthM: Double = 1_000) -> [GeoPoint] {
        [GeoPoint(lat: 0, lon: 0),
         GeoPoint(lat: 0, lon: lengthM / metresPerDegree)]
    }

    private func payload(points: Int = 30, alreadyTrimmed: Bool = false) -> RouteReplayPayload {
        let geometry = (0..<points).map {
            GeoPoint(lat: 37 + Double($0) * 0.001, lon: -122)
        }
        return RouteReplayPayload(
            timeline: RouteReplayTimeline(geometry: geometry,
                                           workoutDurationS: 1_800,
                                           totalDistanceM: 3_200),
            title: "Morning run", type: .run, startedAt: .now,
            style: .realistic, routeIsPrivacyTrimmed: alreadyTrimmed)
    }

    @Test func recordedMovingTimeControlsWhereTheRunnerAppears() throws {
        let points = [
            GPSDetail.RoutePoint(t: 0, cumulativeM: 0, altitudeM: 0, speedMS: 2),
            GPSDetail.RoutePoint(t: 50, cumulativeM: 250, altitudeM: 0, speedMS: 2),
            GPSDetail.RoutePoint(t: 100, cumulativeM: 1_000, altitudeM: 0, speedMS: 5),
        ]
        let timeline = RouteReplayTimeline(geometry: eastLine(), routePoints: points,
                                           workoutDurationS: 100, totalDistanceM: 1_000)
        let halfway = try #require(timeline.state(at: 0.5))

        #expect(abs(halfway.routeProgress - 0.25) < 0.001)
        #expect(abs(halfway.coordinate.lon - 250 / metresPerDegree) < 0.00002)
        #expect(abs(halfway.bearing - 90) < 1)
        #expect(abs(timeline.distance(at: 0.5) - 250) < 1)
        #expect(timeline.elapsedTime(at: 0.5) == 50)
    }

    @Test func sharedRouteWithoutTimestampsReplaysUniformly() throws {
        let timeline = RouteReplayTimeline(geometry: eastLine(), workoutDurationS: 600,
                                           totalDistanceM: 1_000)
        let state = try #require(timeline.state(at: 0.4))
        #expect(abs(state.routeProgress - 0.4) < 0.001)
        #expect(abs(timeline.distance(at: 0.4) - 400) < 1)
    }

    @Test func sharedPayloadDropsMalformedRemoteCoordinateRows() throws {
        var item = FeedItem(id: UUID(), authorName: "Runner", authorHandle: nil,
                            location: nil, isCommunity: false, type: .run, date: .now,
                            title: "Morning run", caption: nil,
                            statLine: "1.0 km · 10:00", prBadge: nil)
        item.routeLatLon = [[45], [0, 0], [.nan, 0.5], [0, 0.001]]

        let payload = try #require(RouteReplayPayload.sharedPost(item))
        #expect(payload.timeline.geometry.count == 2)
        #expect(payload.timeline.isPlayable)
    }

    @Test func malformedRouteWithNoRealSegmentIsUnavailable() {
        var item = FeedItem(id: UUID(), authorName: "Runner", authorHandle: nil,
                            location: nil, isCommunity: false, type: .run, date: .now,
                            title: "Bad route", caption: nil,
                            statLine: "1.0 km · 10:00", prBadge: nil)
        item.routeLatLon = [[45], [.nan, 0], [91, 0], [0, 181], [0, 0], [0, 0]]

        #expect(RouteReplayPayload.sharedPost(item) == nil)
    }

    @Test func localMatchedRouteIsSanitizedBeforeSmoothing() {
        let clean = RouteReplayPayload.sanitizedCoordinates([
            .init(latitude: .nan, longitude: 0),
            .init(latitude: 37.7, longitude: -122.4),
            .init(latitude: 37.71, longitude: -122.39),
            .init(latitude: -91, longitude: 0),
            .init(latitude: 0, longitude: .infinity),
        ])

        #expect(clean.count == 2)
        #expect(clean.allSatisfy { $0.latitude.isFinite && $0.longitude.isFinite })
    }

    @Test func playbackClockIsCondensedAndBounded() {
        #expect(RouteReplayTimeline.condensedDuration(for: 0) == 12)
        #expect(RouteReplayTimeline.condensedDuration(for: 5 * 60) == 10)
        #expect(RouteReplayTimeline.condensedDuration(for: 30 * 60) == 10)
        #expect(RouteReplayTimeline.condensedDuration(for: 60 * 60) == 20)
        #expect(RouteReplayTimeline.condensedDuration(for: 4 * 60 * 60) == 30)
    }

    @Test func corruptAndDuplicateCoordinatesCannotPoisonMapbox() {
        let timeline = RouteReplayTimeline(
            geometry: [GeoPoint(lat: .nan, lon: 0), GeoPoint(lat: 0, lon: 0),
                       GeoPoint(lat: 0, lon: 0), GeoPoint(lat: 95, lon: 0),
                       GeoPoint(lat: 0, lon: 0.001)],
            workoutDurationS: 60, totalDistanceM: 100)
        #expect(timeline.geometry.count == 2)
        #expect(timeline.isPlayable)
        #expect(timeline.state(at: -.infinity)?.routeProgress == 0)
        #expect(timeline.state(at: .infinity)?.routeProgress == 0)
    }

    @Test func nonMonotonicOrInvalidKeyframesAreSanitized() throws {
        let points = [
            GPSDetail.RoutePoint(t: 0, cumulativeM: 0, altitudeM: 0, speedMS: 1),
            GPSDetail.RoutePoint(t: 20, cumulativeM: 300, altitudeM: 0, speedMS: 1),
            GPSDetail.RoutePoint(t: 10, cumulativeM: 200, altitudeM: 0, speedMS: 1),
            GPSDetail.RoutePoint(t: .nan, cumulativeM: 900, altitudeM: 0, speedMS: 1),
            GPSDetail.RoutePoint(t: 40, cumulativeM: 1_000, altitudeM: 0, speedMS: 1),
        ]
        let timeline = RouteReplayTimeline(geometry: eastLine(), routePoints: points,
                                           workoutDurationS: 40, totalDistanceM: 1_000)
        let state = try #require(timeline.state(at: 0.75))
        #expect((0...1).contains(state.routeProgress))
        #expect(zip(timeline.keyframes, timeline.keyframes.dropFirst()).allSatisfy {
            $0.movingTimeS <= $1.movingTimeS && $0.routeProgress <= $1.routeProgress
        })
    }

    @Test func longRouteRemainsFiniteAcrossTheWholePlayback() throws {
        let geometry = (0..<20_000).map { index in
            GeoPoint(lat: 37.7 + sin(Double(index) / 300) * 0.002,
                     lon: -122.4 + Double(index) * 0.000001)
        }
        let timeline = RouteReplayTimeline(geometry: geometry,
                                           workoutDurationS: 4 * 60 * 60,
                                           totalDistanceM: 42_195)
        #expect(timeline.isPlayable)
        #expect(timeline.playbackDurationS == 30)

        for step in 0...1_000 {
            let state = try #require(timeline.state(at: Double(step) / 1_000))
            #expect(state.coordinate.lat.isFinite)
            #expect(state.coordinate.lon.isFinite)
            #expect(state.bearing.isFinite)
            #expect((0...1).contains(state.routeProgress))
        }
    }

    @Test func localVideoPlanNeverContainsThePreciseEndpoints() throws {
        let source = payload()
        let plan = try #require(RouteReplayExportPlan.make(from: source))

        #expect(plan.timeline.geometry.count < source.timeline.geometry.count)
        #expect(plan.timeline.geometry.first != source.timeline.geometry.first)
        #expect(plan.timeline.geometry.last != source.timeline.geometry.last)
        #expect(plan.privacyLabel == "START + FINISH HIDDEN")
    }

    @Test func alreadyPrivateSharedRouteIsNotTrimmedTwice() throws {
        let source = payload(alreadyTrimmed: true)
        let plan = try #require(RouteReplayExportPlan.make(from: source))

        #expect(plan.timeline.geometry == source.timeline.geometry)
        #expect(plan.privacyLabel == "PRIVACY-SAFE SHARED ROUTE")
    }

    @Test func shortLocalRouteCannotBecomeAShareVideo() {
        let source = payload(points: 4)
        #expect(RouteReplayExportPlan.make(from: source) == nil)
    }

    @Test func offlineProjectionStaysFiniteAndHandlesTheDateLine() {
        let points = [GeoPoint(lat: 10, lon: 179.9),
                      GeoPoint(lat: 10.01, lon: -179.98),
                      GeoPoint(lat: 10.02, lon: -179.9)]
        let fitted = RouteReplayProjection.fitted(
            points, in: CGSize(width: 1_000, height: 1_000), inset: 64)

        #expect(fitted.count == points.count)
        #expect(fitted.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        #expect(fitted.allSatisfy { (0...1_000).contains($0.x) && (0...1_000).contains($0.y) })
        #expect(abs(fitted[1].x - fitted[0].x) < 900)
    }

    @Test func mapboxTrimHidesOnlyFutureRouteTail() {
        #expect(RouteReplayLineTrim.hiddenTail(afterVisibleProgress: -0.2) == [0, 1])
        #expect(RouteReplayLineTrim.hiddenTail(afterVisibleProgress: 0.35) == [0.35, 1])
        #expect(RouteReplayLineTrim.hiddenTail(afterVisibleProgress: 1.4) == [1, 1])
    }

    @Test func postRouteRevealDrawsTheEntireRouteAtAnEvenReadablePace() {
        #expect(RouteMapRevealMotion.progress(elapsedS: -1) == 0)
        #expect(RouteMapRevealMotion.progress(elapsedS: RouteMapRevealMotion.durationS / 2) == 0.5)
        #expect(RouteMapRevealMotion.progress(elapsedS: RouteMapRevealMotion.durationS) == 1)
        #expect(RouteMapRevealMotion.progress(elapsedS: RouteMapRevealMotion.durationS * 2) == 1)

        let samples = stride(from: 0.0, through: RouteMapRevealMotion.durationS, by: 0.05)
            .map { RouteMapRevealMotion.progress(elapsedS: $0) }
        #expect(zip(samples, samples.dropFirst()).allSatisfy { pair in pair.0 <= pair.1 })
    }

    @Test func privacySafeReplayEncodesARealVerticalVideo() async throws {
        let plan = try #require(RouteReplayExportPlan.make(from: payload()))
        let backdrop = RouteReplayVideoBackdrop.fallback(
            for: plan, size: CGSize(width: 160, height: 160))
        let output = try await RouteReplayVideoExporter.export(
            plan: plan, backdrop: backdrop, distanceUnit: .metric,
            canvas: CGSize(width: 180, height: 320),
            routeDurationS: 0.2, holdDurationS: 0.1)
        defer { try? FileManager.default.removeItem(at: output) }

        #expect(FileManager.default.fileExists(atPath: output.path))
        let asset = AVURLAsset(url: output)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.naturalSize) == CGSize(width: 180, height: 320))
        #expect(try await asset.load(.duration).seconds > 0.2)
    }

    @Test func terminalWriterStatesCannotKeepTheReadinessLoopAlive() {
        #expect(RouteReplayVideoExporter.isWriterActive(.writing))
        #expect(!RouteReplayVideoExporter.isWriterActive(.failed))
        #expect(!RouteReplayVideoExporter.isWriterActive(.cancelled))
        #expect(!RouteReplayVideoExporter.isWriterActive(.completed))
        #expect(!RouteReplayVideoExporter.isWriterActive(.unknown))
    }
}
