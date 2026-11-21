import CoreLocation
import Foundation
import HealthKit

extension CardioActivity {
    public var hkType: HKWorkoutActivityType {
        switch self {
        case .running: .running
        case .walking: .walking
        case .cycling: .cycling
        case .rowing: .rowing
        case .elliptical: .elliptical
        case .stairs: .stairClimbing
        case .other: .mixedCardio
        }
    }

    /// Health distance type for this activity; nil when it has no distance (elliptical, stairs, other).
    public var distanceType: HKQuantityTypeIdentifier? {
        switch self {
        case .running, .walking: .distanceWalkingRunning
        case .cycling: .distanceCycling
        case .rowing: .distanceRowing
        case .elliptical, .stairs, .other: nil
        }
    }

    /// Default location from the exercise name and activity: true outdoor, false indoor, nil = let the user pick.
    public static func isOutdoor(name: String, activity: CardioActivity?) -> Bool? {
        let name = name.lowercased()
        if name.contains("outdoor") { return true }
        if name.contains("indoor") || name.contains("treadmill") { return false }
        switch activity {
        case .rowing, .elliptical, .stairs: return false
        default: return nil
        }
    }
}

/// Filters GPS fixes, sums distance between them and keeps a ~30 s window for current pace.
public struct RouteTracker {
    public static let maxAccuracy: CLLocationAccuracy = 50
    public static let maxAge: TimeInterval = 10
    public static let window: TimeInterval = 30

    public private(set) var distanceMeters = 0.0
    private var last: CLLocation?
    private var recent: [(time: Date, distance: Double)] = []

    public init() {}

    public static func isUsable(_ location: CLLocation, now: Date) -> Bool {
        location.horizontalAccuracy >= 0 && location.horizontalAccuracy <= maxAccuracy
            && abs(now.timeIntervalSince(location.timestamp)) <= maxAge
    }

    /// Adds fixes and returns the ones accepted (in order), for the Health route.
    public mutating func add(_ locations: [CLLocation], now: Date = .now) -> [CLLocation] {
        var accepted: [CLLocation] = []
        for location in locations where Self.isUsable(location, now: now) {
            if let last {
                guard location.timestamp > last.timestamp else { continue }
                distanceMeters += location.distance(from: last)
            }
            last = location
            recent.append((location.timestamp, distanceMeters))
            accepted.append(location)
        }
        if let latest = recent.last?.time {
            recent.removeAll { latest.timeIntervalSince($0.time) > Self.window }
        }
        return accepted
    }

    /// Distance and time over the last ~30 s; nil until two fixes.
    public var recentWindow: (meters: Double, seconds: TimeInterval)? {
        guard let first = recent.first, let latest = recent.last, latest.time > first.time else { return nil }
        return (latest.distance - first.distance, latest.time.timeIntervalSince(first.time))
    }

    /// After a pause: don't count the gap between the last fix and the next one.
    public mutating func breakSegment() {
        last = nil
        recent = []
    }
}
