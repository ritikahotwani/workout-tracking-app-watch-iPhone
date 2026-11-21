import Foundation
import WorkoutCore

// Display formatting. `short` is for the screen, `spoken` is the VoiceOver sentence (PLAN §6.1).

extension WeightUnit {
    /// Crown / adjustable step in this unit.
    var step: Double { self == .kg ? 2.5 : 5 }
    var unitMass: UnitMass { self == .kg ? .kilograms : .pounds }

    func short(_ kg: Double) -> String { fromKg(kg).formatted(.number.precision(.fractionLength(0...1))) }

    func spoken(_ kg: Double) -> String {
        Measurement(value: fromKg(kg), unit: unitMass)
            .formatted(.measurement(width: .wide, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0...1))))
    }
}

extension DistanceUnit {
    var step: Double { 0.05 }
    var unitLength: UnitLength { self == .km ? .kilometers : .miles }
    var speedUnit: UnitSpeed { self == .km ? .kilometersPerHour : .milesPerHour }

    func short(_ meters: Double) -> String { fromMeters(meters).formatted(.number.precision(.fractionLength(2))) }

    func spoken(_ meters: Double) -> String {
        Measurement(value: fromMeters(meters), unit: unitLength)
            .formatted(.measurement(width: .wide, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0...2))))
    }

    func spokenSpeed(_ value: Double) -> String {
        Measurement(value: value, unit: speedUnit)
            .formatted(.measurement(width: .wide, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0...1))))
    }
}

/// "1 set", "2 sets" (regular English plurals only).
func plural(_ n: Int, _ noun: String) -> String {
    "\(n.formatted()) \(n == 1 ? noun : noun + "s")"
}

/// "5 minutes, 30 seconds" — never "5:30" for VoiceOver.
func spokenDuration(_ seconds: TimeInterval) -> String {
    Duration.seconds(Int(seconds.rounded())).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
}

/// "5:30" or "1:02:03".
func clock(_ seconds: TimeInterval) -> String {
    let s = Int(max(0, seconds))
    return Duration.seconds(s).formatted(.time(pattern: s >= 3600 ? .hourMinuteSecond : .minuteSecond))
}

/// Last session as a short line and a spoken sentence, e.g. "Last 3×8 @ 80" / "Last time: 3 sets, 8 reps at 80 kilograms".
func lastLine(_ sets: [SetEntry], weight: WeightUnit, distance: DistanceUnit) -> (short: String, spoken: String)? {
    guard !sets.isEmpty else { return nil }
    if sets.allSatisfy({ $0.reps == nil }) {  // cardio
        let short = sets.map { s in
            [s.distanceMeters.map { distance.short($0) + " " + distance.rawValue }, clock(s.durationSeconds ?? 0)]
                .compactMap { $0 }.joined(separator: " in ")
        }
        let spoken = sets.map { s in
            [s.distanceMeters.map(distance.spoken), spokenDuration(s.durationSeconds ?? 0)]
                .compactMap { $0 }.joined(separator: " in ")
        }
        return ("Last " + short.joined(separator: " · "), "Last time: " + spoken.joined(separator: ", "))
    }
    let pairs = sets.map { ($0.weightKg ?? 0, $0.reps ?? 0) }
    if let first = pairs.first, pairs.allSatisfy({ $0 == first }) {
        return ("Last \(pairs.count)×\(first.1) @ \(weight.short(first.0))",
                "Last time: \(plural(pairs.count, "set")), \(plural(first.1, "rep")) at \(weight.spoken(first.0))")
    }
    return ("Last " + pairs.map { "\(weight.short($0.0))×\($0.1)" }.joined(separator: " · "),
            "Last time: " + pairs.map { "\(plural($0.1, "rep")) at \(weight.spoken($0.0))" }.joined(separator: ", "))
}
