import CoreLocation
import HealthKit
import Observation
import WorkoutCore

/// GPS for outdoor cardio (PLAN §4): filtered fixes feed the workout's route and a fallback distance + current pace.
@Observable @MainActor
final class LocationRoute: NSObject, CLLocationManagerDelegate {
    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var routeBuilder: HKWorkoutRouteBuilder?
    private var tracker = RouteTracker()

    /// Meters summed from GPS fixes since `start`.
    var distanceMeters: Double { tracker.distanceMeters }
    /// Distance and time over the last ~30 s, for current pace.
    var recentWindow: (meters: Double, seconds: TimeInterval)? { tracker.recentWindow }

    override init() {
        super.init()
        manager.delegate = self
        manager.activityType = .fitness
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func start(routeBuilder: HKWorkoutRouteBuilder?) {
        tracker = RouteTracker()
        self.routeBuilder = routeBuilder
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        manager.startUpdatingLocation()
    }

    func pause() { manager.stopUpdatingLocation() }

    func resume() {
        tracker.breakSegment()
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
        routeBuilder = nil
    }

    // Delegate calls arrive on the main run loop, where the manager was created.
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            let accepted = tracker.add(locations)
            guard !accepted.isEmpty, let routeBuilder else { return }
            routeBuilder.insertRouteData(accepted) { _, error in
                if let error { print("Route insert failed: \(error)") }
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        print("Location failed: \(error)")
    }
}
