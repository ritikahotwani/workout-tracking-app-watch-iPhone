import CoreLocation
import HealthKit
import Testing
@testable import WorkoutCore

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

/// A fix `meters` north of a fixed origin, `seconds` after t0.
private func fix(_ meters: Double, at seconds: TimeInterval, accuracy: Double = 5) -> CLLocation {
    CLLocation(coordinate: CLLocationCoordinate2D(latitude: 51.5 + meters / 111_195, longitude: -0.1),
               altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: -1, timestamp: t0 + seconds)
}

@Suite struct CardioTests {
    @Test func filtersPoorAndStaleFixes() {
        let now = t0 + 100
        #expect(RouteTracker.isUsable(fix(0, at: 100), now: now))
        #expect(RouteTracker.isUsable(fix(0, at: 100, accuracy: 50), now: now))
        #expect(!RouteTracker.isUsable(fix(0, at: 100, accuracy: 51), now: now))
        #expect(!RouteTracker.isUsable(fix(0, at: 100, accuracy: -1), now: now))  // invalid
        #expect(!RouteTracker.isUsable(fix(0, at: 80), now: now))  // 20 s old
    }

    @Test func accumulatesDistanceAndSkipsBadFixes() {
        var tracker = RouteTracker()
        let fixes = [fix(0, at: 51), fix(100, at: 55), fix(5_000, at: 56, accuracy: 200), fix(200, at: 60), fix(150, at: 59)]
        let accepted = tracker.add(fixes, now: t0 + 60)
        #expect(accepted.count == 3)  // inaccurate and out-of-order fixes dropped
        #expect(abs(tracker.distanceMeters - 200) < 1)
    }

    @Test func breakSegmentSkipsTheGap() {
        var tracker = RouteTracker()
        _ = tracker.add([fix(0, at: 0), fix(100, at: 5)], now: t0 + 5)
        tracker.breakSegment()
        _ = tracker.add([fix(1_000, at: 10), fix(1_050, at: 15)], now: t0 + 15)
        #expect(abs(tracker.distanceMeters - 150) < 1)
    }

    @Test func rollingWindowCoversLast30Seconds() {
        var tracker = RouteTracker()
        #expect(tracker.recentWindow == nil)
        // 2 m/s for 60 s, then 4 m/s for 30 s.
        for s in stride(from: 0.0, through: 60, by: 5) { _ = tracker.add([fix(s * 2, at: s)], now: t0 + s) }
        for s in stride(from: 65.0, through: 90, by: 5) { _ = tracker.add([fix(120 + (s - 60) * 4, at: s)], now: t0 + s) }
        let w = try! #require(tracker.recentWindow)
        #expect(w.seconds == 30)
        #expect(abs(w.meters - 120) < 1)
        let pace = try! #require(DistanceUnit.km.pace(distanceMeters: w.meters, durationSeconds: w.seconds))
        #expect(abs(pace - 250) < 2)  // 4 m/s = 4:10 /km, not the whole-run average
    }

    @Test func activityMapping() {
        #expect(CardioActivity.running.hkType == .running)
        #expect(CardioActivity.stairs.hkType == .stairClimbing)
        #expect(CardioActivity.other.hkType == .mixedCardio)
        #expect(CardioActivity.walking.distanceType == .distanceWalkingRunning)
        #expect(CardioActivity.cycling.distanceType == .distanceCycling)
        #expect(CardioActivity.rowing.distanceType == .distanceRowing)
        #expect(CardioActivity.elliptical.distanceType == nil)
    }

    @Test func indoorOutdoorDefaults() {
        #expect(CardioActivity.isOutdoor(name: "Outdoor Run", activity: .running) == true)
        #expect(CardioActivity.isOutdoor(name: "Outdoor Cycling", activity: .cycling) == true)
        #expect(CardioActivity.isOutdoor(name: "Treadmill Run", activity: .running) == false)
        #expect(CardioActivity.isOutdoor(name: "Indoor Cycling", activity: .cycling) == false)
        #expect(CardioActivity.isOutdoor(name: "Elliptical", activity: .elliptical) == false)
        #expect(CardioActivity.isOutdoor(name: "Stair Climber", activity: .stairs) == false)
        #expect(CardioActivity.isOutdoor(name: "Rowing Machine", activity: .rowing) == false)
        #expect(CardioActivity.isOutdoor(name: "Walking", activity: .walking) == nil)
        #expect(CardioActivity.isOutdoor(name: "Jump Rope", activity: .other) == nil)
    }
}
