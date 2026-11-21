import Foundation

public enum Volume {
    /// weight × reps; 0 when either is missing or not positive (cardio, unweighted bodyweight).
    public static func of(weightKg: Double?, reps: Int?) -> Double {
        guard let weightKg, let reps, weightKg > 0, reps > 0 else { return 0 }
        return weightKg * Double(reps)
    }

    public static func total(_ sets: [SetRecord]) -> Double {
        sets.reduce(0) { $0 + $1.volume }
    }

    public static func bySession(_ sets: [SetRecord]) -> [UUID: Double] {
        sets.reduce(into: [:]) { $0[$1.sessionID, default: 0] += $1.volume }
    }

    public static func byExercise(_ sets: [SetRecord]) -> [UUID: Double] {
        sets.reduce(into: [:]) { $0[$1.exerciseID, default: 0] += $1.volume }
    }

    /// Keyed by the start (Monday 00:00) of each ISO week.
    public static func byWeek(_ sets: [SetRecord], calendar: Calendar = .isoWeeks) -> [Date: Double] {
        sets.reduce(into: [:]) { $0[calendar.start(of: .weekOfYear, for: $1.date), default: 0] += $1.volume }
    }
}

public enum OneRepMax {
    /// Epley: weight × (1 + reps/30); reps == 1 → weight; nil when weight or reps is not positive.
    public static func epley(weight: Double, reps: Int) -> Double? {
        guard weight > 0, reps > 0 else { return nil }
        return reps == 1 ? weight : weight * (1 + Double(reps) / 30)
    }
}
