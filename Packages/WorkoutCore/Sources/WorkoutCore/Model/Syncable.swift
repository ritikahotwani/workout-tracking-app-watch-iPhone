import Foundation
import SwiftData

/// Common sync fields carried by every model (PLAN §2.1).
public protocol Syncable: PersistentModel {
    var id: UUID { get set }
    var userID: UUID? { get set }
    var createdAt: Date { get set }
    var updatedAt: Date { get set }
    var deletedAt: Date? { get set }
    /// Local-only dirty flag; never synced.
    var needsPush: Bool { get set }
}

extension Syncable {
    /// Call after every local mutation.
    public func touch() {
        updatedAt = .now
        needsPush = true
    }

    /// Soft delete.
    public func markDeleted() {
        deletedAt = .now
        touch()
    }
}

/// Container with every model registered. Both apps and tests use this.
public func makeModelContainer(inMemory: Bool = false) throws -> ModelContainer {
    let schema = Schema([
        Exercise.self, Routine.self, RoutineExercise.self,
        WorkoutSession.self, SessionExercise.self, SetEntry.self,
        BodyWeightEntry.self,
    ])
    return try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: inMemory))
}
