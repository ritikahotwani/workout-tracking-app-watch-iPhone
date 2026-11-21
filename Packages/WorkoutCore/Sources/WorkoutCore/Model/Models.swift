import Foundation
import SwiftData

// Foreign keys are plain UUIDs, not SwiftData relationships (PLAN §2.1).

@Model
public final class Routine: Syncable {
    @Attribute(.unique) public var id: UUID
    public var userID: UUID?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var needsPush: Bool

    public var name: String
    public var sortOrder: Int

    public init(
        id: UUID = UUID(), name: String, sortOrder: Int = 0,
        userID: UUID? = nil, createdAt: Date = .now, updatedAt: Date = .now, deletedAt: Date? = nil,
        needsPush: Bool = true
    ) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
        self.userID = userID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.needsPush = needsPush
    }
}

@Model
public final class RoutineExercise: Syncable {
    @Attribute(.unique) public var id: UUID
    public var userID: UUID?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var needsPush: Bool

    public var routineID: UUID
    public var exerciseID: UUID
    public var sortOrder: Int
    public var targetSets: Int
    public var targetReps: Int
    /// nil → exercise's `defaultRestSeconds`.
    public var restSeconds: Int?

    public init(
        id: UUID = UUID(), routineID: UUID, exerciseID: UUID, sortOrder: Int = 0,
        targetSets: Int = 3, targetReps: Int = 10, restSeconds: Int? = nil,
        userID: UUID? = nil, createdAt: Date = .now, updatedAt: Date = .now, deletedAt: Date? = nil,
        needsPush: Bool = true
    ) {
        self.id = id
        self.routineID = routineID
        self.exerciseID = exerciseID
        self.sortOrder = sortOrder
        self.targetSets = targetSets
        self.targetReps = targetReps
        self.restSeconds = restSeconds
        self.userID = userID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.needsPush = needsPush
    }
}

@Model
public final class WorkoutSession: Syncable {
    @Attribute(.unique) public var id: UUID
    public var userID: UUID?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var needsPush: Bool

    public var routineID: UUID?
    public var startedAt: Date
    public var endedAt: Date?
    public var pausedSeconds: Double
    public var sourceRaw: String
    public var activeCalories: Double?
    public var avgHeartRate: Double?
    public var healthKitWorkoutID: UUID?
    public var importKey: String?

    public init(
        id: UUID = UUID(), routineID: UUID? = nil, startedAt: Date = .now, endedAt: Date? = nil,
        pausedSeconds: Double = 0, source: SessionSource, activeCalories: Double? = nil,
        avgHeartRate: Double? = nil, healthKitWorkoutID: UUID? = nil, importKey: String? = nil,
        userID: UUID? = nil, createdAt: Date = .now, updatedAt: Date = .now, deletedAt: Date? = nil,
        needsPush: Bool = true
    ) {
        self.id = id
        self.routineID = routineID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.pausedSeconds = pausedSeconds
        self.sourceRaw = source.rawValue
        self.activeCalories = activeCalories
        self.avgHeartRate = avgHeartRate
        self.healthKitWorkoutID = healthKitWorkoutID
        self.importKey = importKey
        self.userID = userID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.needsPush = needsPush
    }

    public var source: SessionSource {
        get { SessionSource(rawValue: sourceRaw) ?? .phone }
        set { sourceRaw = newValue.rawValue }
    }
}

@Model
public final class SessionExercise: Syncable {
    @Attribute(.unique) public var id: UUID
    public var userID: UUID?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var needsPush: Bool

    public var sessionID: UUID
    public var exerciseID: UUID
    public var sortOrder: Int
    public var note: String?

    public init(
        id: UUID = UUID(), sessionID: UUID, exerciseID: UUID, sortOrder: Int = 0, note: String? = nil,
        userID: UUID? = nil, createdAt: Date = .now, updatedAt: Date = .now, deletedAt: Date? = nil,
        needsPush: Bool = true
    ) {
        self.id = id
        self.sessionID = sessionID
        self.exerciseID = exerciseID
        self.sortOrder = sortOrder
        self.note = note
        self.userID = userID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.needsPush = needsPush
    }
}

/// Pace and speed are derived from distance/duration (see `Units`), never stored.
@Model
public final class SetEntry: Syncable {
    @Attribute(.unique) public var id: UUID
    public var userID: UUID?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var needsPush: Bool

    public var sessionExerciseID: UUID
    public var sortOrder: Int
    public var weightKg: Double?
    public var reps: Int?
    public var distanceMeters: Double?
    public var durationSeconds: Double?
    /// Actual rest taken after this set.
    public var restSeconds: Double?
    public var completedAt: Date
    public var importKey: String?

    public init(
        id: UUID = UUID(), sessionExerciseID: UUID, sortOrder: Int = 0, weightKg: Double? = nil,
        reps: Int? = nil, distanceMeters: Double? = nil, durationSeconds: Double? = nil,
        restSeconds: Double? = nil, completedAt: Date = .now, importKey: String? = nil,
        userID: UUID? = nil, createdAt: Date = .now, updatedAt: Date = .now, deletedAt: Date? = nil,
        needsPush: Bool = true
    ) {
        self.id = id
        self.sessionExerciseID = sessionExerciseID
        self.sortOrder = sortOrder
        self.weightKg = weightKg
        self.reps = reps
        self.distanceMeters = distanceMeters
        self.durationSeconds = durationSeconds
        self.restSeconds = restSeconds
        self.completedAt = completedAt
        self.importKey = importKey
        self.userID = userID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.needsPush = needsPush
    }
}

@Model
public final class BodyWeightEntry: Syncable {
    @Attribute(.unique) public var id: UUID
    public var userID: UUID?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var needsPush: Bool

    public var date: Date
    public var weightKg: Double
    public var healthKitSampleID: UUID?
    public var sourceRaw: String

    public init(
        id: UUID = UUID(), date: Date = .now, weightKg: Double, healthKitSampleID: UUID? = nil,
        source: WeightSource = .app,
        userID: UUID? = nil, createdAt: Date = .now, updatedAt: Date = .now, deletedAt: Date? = nil,
        needsPush: Bool = true
    ) {
        self.id = id
        self.date = date
        self.weightKg = weightKg
        self.healthKitSampleID = healthKitSampleID
        self.sourceRaw = source.rawValue
        self.userID = userID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.needsPush = needsPush
    }

    public var source: WeightSource {
        get { WeightSource(rawValue: sourceRaw) ?? .app }
        set { sourceRaw = newValue.rawValue }
    }
}
