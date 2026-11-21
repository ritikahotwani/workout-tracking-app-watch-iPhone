import Foundation
import SwiftData

/// SwiftData read helpers shared by watch and iPhone. Soft-deleted rows are always skipped.
/// Joins are done in memory because foreign keys are plain UUIDs (PLAN §2.1).
public enum Queries {
    /// Routine items in order, paired with their exercise. Items whose exercise is missing or deleted are dropped.
    public static func routineExercises(routineID: UUID, in context: ModelContext) throws
        -> [(item: RoutineExercise, exercise: Exercise)]
    {
        let items = try context.fetch(FetchDescriptor<RoutineExercise>(
            predicate: #Predicate { $0.routineID == routineID && $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.sortOrder)]))
        let ids = items.map(\.exerciseID)
        let exercises = try context.fetch(FetchDescriptor<Exercise>(
            predicate: #Predicate { ids.contains($0.id) && $0.deletedAt == nil }))
        let byID = Dictionary(exercises.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return items.compactMap { item in byID[item.exerciseID].map { (item, $0) } }
    }

    /// Non-deleted sets of one session exercise, in order.
    public static func sets(sessionExerciseID: UUID, in context: ModelContext) throws -> [SetEntry] {
        try context.fetch(FetchDescriptor<SetEntry>(
            predicate: #Predicate { $0.sessionExerciseID == sessionExerciseID && $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.sortOrder)]))
    }

    /// Sets from the most recent ended, non-deleted session (other than `excludingSession`) that has at
    /// least one set of this exercise. Empty when there is none.
    public static func lastPerformance(exerciseID: UUID, excludingSession: UUID?, in context: ModelContext) throws
        -> [SetEntry]
    {
        let (entries, sessions) = try entriesAndSessions(exerciseID: exerciseID, in: context)
        let ended = sessions.values
            .filter { $0.endedAt != nil && $0.id != excludingSession }
            .sorted { $0.startedAt > $1.startedAt }
        for session in ended {
            let sets = try entries.filter { $0.sessionID == session.id }
                .sorted { $0.sortOrder < $1.sortOrder }
                .flatMap { try Queries.sets(sessionExerciseID: $0.id, in: context) }
            if !sets.isEmpty { return sets }
        }
        return []
    }

    /// Strength sets (reps present) of one exercise across non-deleted sessions, as `SetRecord`s.
    /// Bodyweight sets with no weight count as 0 kg.
    public static func setRecords(exerciseID: UUID, in context: ModelContext) throws -> [SetRecord] {
        let (entries, sessions) = try entriesAndSessions(exerciseID: exerciseID, in: context)
        return try entries.flatMap { entry -> [SetRecord] in
            guard sessions[entry.sessionID] != nil else { return [] }
            return try sets(sessionExerciseID: entry.id, in: context).compactMap { set in
                set.reps.map {
                    SetRecord(sessionID: entry.sessionID, exerciseID: exerciseID, date: set.completedAt,
                              weightKg: set.weightKg ?? 0, reps: $0)
                }
            }
        }
    }

    /// PR baseline from every non-deleted session except `excludingSession` (typically the live one).
    public static func prBaseline(exerciseID: UUID, excludingSession: UUID?, in context: ModelContext) throws
        -> PRBaseline
    {
        PersonalRecords.baseline(for: try setRecords(exerciseID: exerciseID, in: context)
            .filter { $0.sessionID != excludingSession })
    }

    /// Non-deleted session exercises for `exerciseID` and their non-deleted sessions, keyed by session ID.
    private static func entriesAndSessions(exerciseID: UUID, in context: ModelContext) throws
        -> ([SessionExercise], [UUID: WorkoutSession])
    {
        let entries = try context.fetch(FetchDescriptor<SessionExercise>(
            predicate: #Predicate { $0.exerciseID == exerciseID && $0.deletedAt == nil }))
        let ids = Array(Set(entries.map(\.sessionID)))
        let sessions = try context.fetch(FetchDescriptor<WorkoutSession>(
            predicate: #Predicate { ids.contains($0.id) && $0.deletedAt == nil }))
        return (entries, Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }))
    }
}
