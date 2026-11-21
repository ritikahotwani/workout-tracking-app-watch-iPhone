import Foundation

public enum SessionTitle {
    /// History title: the routine name; else, when only cardio was logged, the cardio exercise ("Walking");
    /// else the top one or two muscle groups by set count ("Back · Biceps"); else "Workout".
    /// `setExercises` holds the exercise of each logged set, in logging order (it breaks ties).
    public static func make(routine: String?, setExercises: [Exercise]) -> String {
        if let routine { return routine }
        let strength = setExercises.filter { $0.kind == .strength }
        if strength.isEmpty, let names = top(setExercises.map(\.name)) { return names }
        return top(strength.map(\.muscleGroup).filter { $0 != .other && $0 != .cardio }.map(\.title)) ?? "Workout"
    }

    /// The two most frequent keys, most first, joined with " · "; nil when empty.
    private static func top(_ keys: [String]) -> String? {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for key in keys {
            if counts[key] == nil { order.append(key) }
            counts[key, default: 0] += 1
        }
        let ranked = order.enumerated().sorted { (counts[$0.element]!, $1.offset) > (counts[$1.element]!, $0.offset) }
        return ranked.isEmpty ? nil : ranked.prefix(2).map(\.element).joined(separator: " · ")
    }
}

extension MuscleGroup {
    public var title: String { self == .fullBody ? "Full Body" : rawValue.capitalized }
}
