import Foundation

/// Current vs previous session of the same routine/exercise.
public enum Compare {
    public struct Summary: Equatable, Sendable {
        public var volume: Double
        /// Heaviest set; ties → more reps.
        public var topSet: SetRecord?
        public var bestE1RM: Double?
    }

    public struct Comparison: Equatable, Sendable {
        public var current: Summary
        public var previous: Summary

        public var volumeDelta: Double { current.volume - previous.volume }
        public var topSetWeightDelta: Double? { diff(current.topSet?.weightKg, previous.topSet?.weightKg) }
        public var topSetRepsDelta: Int? {
            guard let c = current.topSet?.reps, let p = previous.topSet?.reps else { return nil }
            return c - p
        }
        public var e1RMDelta: Double? { diff(current.bestE1RM, previous.bestE1RM) }

        private func diff(_ a: Double?, _ b: Double?) -> Double? {
            guard let a, let b else { return nil }
            return a - b
        }
    }

    public static func summary(_ sets: [SetRecord]) -> Summary {
        let top = sets.filter { $0.reps > 0 }.max { ($0.weightKg, $0.reps) < ($1.weightKg, $1.reps) }
        return Summary(volume: Volume.total(sets), topSet: top, bestE1RM: sets.compactMap(\.e1RM).max())
    }

    public static func compare(current: [SetRecord], previous: [SetRecord]) -> Comparison {
        Comparison(current: summary(current), previous: summary(previous))
    }
}

public enum WorkoutCounts {
    public static func total(_ dates: [Date]) -> Int { dates.count }

    /// Keyed by ISO week start (Monday 00:00).
    public static func perWeek(_ dates: [Date], calendar: Calendar = .isoWeeks) -> [Date: Int] {
        dates.reduce(into: [:]) { $0[calendar.start(of: .weekOfYear, for: $1), default: 0] += 1 }
    }

    /// Keyed by the first day of each month.
    public static func perMonth(_ dates: [Date], calendar: Calendar = .isoWeeks) -> [Date: Int] {
        dates.reduce(into: [:]) { $0[calendar.start(of: .month, for: $1), default: 0] += 1 }
    }
}

public enum MovingAverage {
    public struct Point: Equatable, Sendable {
        public var date: Date
        public var value: Double
        public init(date: Date, value: Double) {
            self.date = date
            self.value = value
        }
    }

    /// One point per calendar day that has entries (dated start of day), sorted ascending.
    /// Same-day entries are averaged first; each output is the mean of the daily values within
    /// that day and the 6 calendar days before it. Days without entries are skipped, not zero-filled.
    public static func sevenDay(entries: [Point], calendar: Calendar = .current) -> [Point] {
        let daily = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.date) }
            .mapValues { $0.reduce(0) { $0 + $1.value } / Double($0.count) }
            .sorted { $0.key < $1.key }
        // ponytail: O(n·7) scan over sorted days; fine for years of daily weigh-ins.
        return daily.indices.map { i in
            let day = daily[i].key
            let windowStart = calendar.date(byAdding: .day, value: -6, to: day)!
            let window = daily[...i].reversed().prefix { $0.key >= windowStart }
            return Point(date: day, value: window.reduce(0) { $0 + $1.value } / Double(window.count))
        }
    }
}
