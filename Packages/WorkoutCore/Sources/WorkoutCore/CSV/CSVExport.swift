import Foundation
import SwiftData

/// Flat CSV backups of all non-deleted data. Canonical units (kg, meters, seconds), named in the headers;
/// dates are ISO 8601 UTC.
public enum CSVExport {
    public static let workoutColumns = ["date", "session_id", "routine", "exercise", "muscle_group", "kind", "set_number",
                                        "weight_kg", "reps", "distance_m", "duration_s", "rest_s", "exercise_note",
                                        "session_note"]
    public static let bodyWeightColumns = ["date", "weight_kg", "source"]

    /// One row per set, sessions oldest first, then exercise and set order.
    public static func workouts(in context: ModelContext) throws -> String {
        let sessions = try context.fetch(FetchDescriptor<WorkoutSession>(
            predicate: #Predicate { $0.deletedAt == nil }, sortBy: [SortDescriptor(\.startedAt)]))
        let entries = Dictionary(grouping: try context.fetch(FetchDescriptor<SessionExercise>(
            predicate: #Predicate { $0.deletedAt == nil }, sortBy: [SortDescriptor(\.sortOrder)])), by: \.sessionID)
        let sets = Dictionary(grouping: try context.fetch(FetchDescriptor<SetEntry>(
            predicate: #Predicate { $0.deletedAt == nil }, sortBy: [SortDescriptor(\.sortOrder)])), by: \.sessionExerciseID)
        // Deleted exercises/routines keep their names here: the sets referencing them are still live data.
        let exercises = Dictionary(try context.fetch(FetchDescriptor<Exercise>()).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let routines = Dictionary(try context.fetch(FetchDescriptor<Routine>()).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })

        var rows = [workoutColumns]
        for session in sessions {
            for entry in entries[session.id] ?? [] {
                let exercise = exercises[entry.exerciseID]
                for (i, set) in (sets[entry.id] ?? []).enumerated() {
                    rows.append([
                        date(set.completedAt), session.id.uuidString, session.routineID.flatMap { routines[$0] } ?? "",
                        exercise?.name ?? "", exercise?.muscleGroupRaw ?? "", exercise?.kindRaw ?? "", String(i + 1),
                        number(set.weightKg), set.reps.map(String.init) ?? "", number(set.distanceMeters),
                        number(set.durationSeconds), number(set.restSeconds), entry.note ?? "", session.note ?? "",
                    ])
                }
            }
        }
        return CSV.write(rows)
    }

    public static func bodyWeights(in context: ModelContext) throws -> String {
        let entries = try context.fetch(FetchDescriptor<BodyWeightEntry>(
            predicate: #Predicate { $0.deletedAt == nil }, sortBy: [SortDescriptor(\.date)]))
        return CSV.write([bodyWeightColumns] + entries.map { [date($0.date), number($0.weightKg), $0.sourceRaw] })
    }

    static func date(_ d: Date) -> String { d.formatted(.iso8601) }

    /// "60" not "60.0"; locale-independent.
    static func number(_ d: Double?) -> String {
        guard let d else { return "" }
        return d == d.rounded() && abs(d) < 1e15 ? String(Int(d)) : String(d)
    }
}
