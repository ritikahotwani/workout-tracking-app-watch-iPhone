import Foundation
import SwiftData

extension Queries {
    /// One non-deleted set of an ended, non-deleted session.
    public struct LoggedSet {
        public let sessionID: UUID
        public let exerciseID: UUID
        public let set: SetEntry

        /// Strength view of the set; nil for cardio (no reps). Unweighted sets count as 0 kg.
        public var record: SetRecord? {
            self.set.reps.map {
                SetRecord(sessionID: sessionID, exerciseID: exerciseID, date: self.set.completedAt,
                          weightKg: self.set.weightKg ?? 0, reps: $0)
            }
        }
    }

    /// Every set of every ended, non-deleted session, oldest first. One fetch per table, joined in memory,
    /// for history rows, charts and PRs across all history.
    public static func loggedSets(in context: ModelContext) throws -> [LoggedSet] {
        let sessions = try context.fetch(FetchDescriptor<WorkoutSession>(
            predicate: #Predicate { $0.deletedAt == nil && $0.endedAt != nil }))
        let ended = Set(sessions.map(\.id))
        let entries = try context.fetch(FetchDescriptor<SessionExercise>(predicate: #Predicate { $0.deletedAt == nil }))
            .filter { ended.contains($0.sessionID) }
        let byEntry = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let sets = try context.fetch(FetchDescriptor<SetEntry>(
            predicate: #Predicate { $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.completedAt), SortDescriptor(\.sortOrder)]))
        return sets.compactMap { set in
            byEntry[set.sessionExerciseID].map { LoggedSet(sessionID: $0.sessionID, exerciseID: $0.exerciseID, set: set) }
        }
    }

    /// Soft-deletes a session with its session exercises and sets, then saves.
    public static func deleteSession(_ session: WorkoutSession, in context: ModelContext) throws {
        let sid = session.id
        let entries = try context.fetch(FetchDescriptor<SessionExercise>(
            predicate: #Predicate { $0.sessionID == sid && $0.deletedAt == nil }))
        for entry in entries {
            for set in try sets(sessionExerciseID: entry.id, in: context) { set.markDeleted() }
            entry.markDeleted()
        }
        session.markDeleted()
        try context.save()
    }
}
