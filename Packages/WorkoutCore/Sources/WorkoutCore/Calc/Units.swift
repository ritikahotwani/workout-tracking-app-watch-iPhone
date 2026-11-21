import Foundation

/// Storage is canonical kg / meters / seconds; convert only for display.
public enum WeightUnit: String, Codable, CaseIterable, Sendable {
    case kg, lb

    public static let kgPerPound = 0.45359237

    public func fromKg(_ kg: Double) -> Double { self == .kg ? kg : kg / Self.kgPerPound }
    public func toKg(_ value: Double) -> Double { self == .kg ? value : value * Self.kgPerPound }
}

public enum DistanceUnit: String, Codable, CaseIterable, Sendable {
    case km, mi

    public static let metersPerMile = 1609.344

    public var metersPerUnit: Double { self == .km ? 1000 : Self.metersPerMile }
    public func fromMeters(_ m: Double) -> Double { m / metersPerUnit }
    public func toMeters(_ value: Double) -> Double { value * metersPerUnit }

    /// Seconds per km/mi. nil when distance or duration is not positive.
    public func pace(distanceMeters: Double, durationSeconds: Double) -> Double? {
        guard distanceMeters > 0, durationSeconds > 0 else { return nil }
        return durationSeconds / fromMeters(distanceMeters)
    }

    /// km/h or mph. nil when distance or duration is not positive.
    public func speed(distanceMeters: Double, durationSeconds: Double) -> Double? {
        guard distanceMeters > 0, durationSeconds > 0 else { return nil }
        return fromMeters(distanceMeters) / (durationSeconds / 3600)
    }
}
