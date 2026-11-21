import Foundation

/// Plain value view of one completed strength set, the input to every Calc function.
public struct SetRecord: Hashable, Sendable {
    public var sessionID: UUID
    public var exerciseID: UUID
    public var date: Date
    public var weightKg: Double
    public var reps: Int

    public init(sessionID: UUID, exerciseID: UUID, date: Date, weightKg: Double, reps: Int) {
        self.sessionID = sessionID
        self.exerciseID = exerciseID
        self.date = date
        self.weightKg = weightKg
        self.reps = reps
    }

    public var volume: Double { Volume.of(weightKg: weightKg, reps: reps) }
    public var e1RM: Double? { OneRepMax.epley(weight: weightKg, reps: reps) }
}

extension Calendar {
    /// ISO 8601 weeks (Monday start) in the current time zone.
    public static var isoWeeks: Calendar { Calendar(identifier: .iso8601) }

    func start(of component: Calendar.Component, for date: Date) -> Date {
        dateInterval(of: component, for: date)?.start ?? startOfDay(for: date)
    }
}
