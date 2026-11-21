import Foundation

/// Wire format for one row (Supabase + WatchConnectivity). Mirrors its model 1:1, minus `needsPush`.
public protocol SyncDTO: Codable, Sendable, Equatable {
    associatedtype Model: Syncable
    var id: UUID { get }
    var updatedAt: Date { get }
    init(_ model: Model)
    /// Overwrites every synced field (incl. `deletedAt`) on `model`. Leaves `needsPush` alone.
    func apply(to model: Model)
    func makeModel() -> Model
}

extension JSONEncoder {
    /// ISO 8601 with fractional seconds.
    public static var sync: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
        }
        return e
    }
}

extension JSONDecoder {
    /// Accepts ISO 8601 with or without fractional seconds.
    public static var sync: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            if let date = try? Date(s, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
                return date
            }
            if let date = try? Date(s, strategy: .iso8601) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid ISO 8601 date: \(s)")
        }
        return d
    }
}

/// Encodes nil as an explicit JSON `null` (synthesized Codable omits the key), so clearing a
/// field such as `deleted_at` reaches the server on upsert. Missing keys decode as nil.
@propertyWrapper
public struct NullEncodable<T: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    public var wrappedValue: T?

    public init(wrappedValue: T?) { self.wrappedValue = wrappedValue }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        wrappedValue = c.decodeNil() ? nil : try c.decode(T.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        if let wrappedValue { try c.encode(wrappedValue) } else { try c.encodeNil() }
    }
}

extension KeyedDecodingContainer {
    public func decode<T>(_ type: NullEncodable<T>.Type, forKey key: Key) throws -> NullEncodable<T> {
        try decodeIfPresent(type, forKey: key) ?? NullEncodable(wrappedValue: nil)
    }
}

// MARK: - Exercise

public struct ExerciseDTO: SyncDTO {
    public var id: UUID
    @NullEncodable public var userID: UUID?
    public var createdAt: Date
    public var updatedAt: Date
    @NullEncodable public var deletedAt: Date?
    public var name: String
    public var nameKey: String
    public var muscleGroup: String
    public var kind: String
    @NullEncodable public var cardioActivity: String?
    public var isBuiltIn: Bool
    public var defaultRestSeconds: Int

    enum CodingKeys: String, CodingKey {
        case id, name, kind
        case userID = "user_id", createdAt = "created_at", updatedAt = "updated_at", deletedAt = "deleted_at"
        case nameKey = "name_key", muscleGroup = "muscle_group", cardioActivity = "cardio_activity"
        case isBuiltIn = "is_built_in", defaultRestSeconds = "default_rest_seconds"
    }
}

extension ExerciseDTO {
    public init(_ m: Exercise) {
        self.init(id: m.id, userID: m.userID, createdAt: m.createdAt, updatedAt: m.updatedAt, deletedAt: m.deletedAt,
                  name: m.name, nameKey: m.nameKey, muscleGroup: m.muscleGroupRaw, kind: m.kindRaw,
                  cardioActivity: m.cardioActivityRaw, isBuiltIn: m.isBuiltIn, defaultRestSeconds: m.defaultRestSeconds)
    }

    public func apply(to m: Exercise) {
        m.userID = userID; m.createdAt = createdAt; m.updatedAt = updatedAt; m.deletedAt = deletedAt
        m.setName(name)  // nameKey is recomputed locally, never trusted from the wire
        m.muscleGroupRaw = muscleGroup; m.kindRaw = kind; m.cardioActivityRaw = cardioActivity
        m.isBuiltIn = isBuiltIn; m.defaultRestSeconds = defaultRestSeconds
    }

    public func makeModel() -> Exercise {
        let m = Exercise(id: id, name: name)
        apply(to: m)
        return m
    }
}

// MARK: - Routine

public struct RoutineDTO: SyncDTO {
    public var id: UUID
    @NullEncodable public var userID: UUID?
    public var createdAt: Date
    public var updatedAt: Date
    @NullEncodable public var deletedAt: Date?
    public var name: String
    public var sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case id, name
        case userID = "user_id", createdAt = "created_at", updatedAt = "updated_at", deletedAt = "deleted_at"
        case sortOrder = "sort_order"
    }
}

extension RoutineDTO {
    public init(_ m: Routine) {
        self.init(id: m.id, userID: m.userID, createdAt: m.createdAt, updatedAt: m.updatedAt, deletedAt: m.deletedAt,
                  name: m.name, sortOrder: m.sortOrder)
    }

    public func apply(to m: Routine) {
        m.userID = userID; m.createdAt = createdAt; m.updatedAt = updatedAt; m.deletedAt = deletedAt
        m.name = name; m.sortOrder = sortOrder
    }

    public func makeModel() -> Routine {
        let m = Routine(id: id, name: name)
        apply(to: m)
        return m
    }
}

// MARK: - RoutineExercise

public struct RoutineExerciseDTO: SyncDTO {
    public var id: UUID
    @NullEncodable public var userID: UUID?
    public var createdAt: Date
    public var updatedAt: Date
    @NullEncodable public var deletedAt: Date?
    public var routineID: UUID
    public var exerciseID: UUID
    public var sortOrder: Int
    public var targetSets: Int
    public var targetReps: Int
    @NullEncodable public var restSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id", createdAt = "created_at", updatedAt = "updated_at", deletedAt = "deleted_at"
        case routineID = "routine_id", exerciseID = "exercise_id", sortOrder = "sort_order"
        case targetSets = "target_sets", targetReps = "target_reps", restSeconds = "rest_seconds"
    }
}

extension RoutineExerciseDTO {
    public init(_ m: RoutineExercise) {
        self.init(id: m.id, userID: m.userID, createdAt: m.createdAt, updatedAt: m.updatedAt, deletedAt: m.deletedAt,
                  routineID: m.routineID, exerciseID: m.exerciseID, sortOrder: m.sortOrder,
                  targetSets: m.targetSets, targetReps: m.targetReps, restSeconds: m.restSeconds)
    }

    public func apply(to m: RoutineExercise) {
        m.userID = userID; m.createdAt = createdAt; m.updatedAt = updatedAt; m.deletedAt = deletedAt
        m.routineID = routineID; m.exerciseID = exerciseID; m.sortOrder = sortOrder
        m.targetSets = targetSets; m.targetReps = targetReps; m.restSeconds = restSeconds
    }

    public func makeModel() -> RoutineExercise {
        let m = RoutineExercise(id: id, routineID: routineID, exerciseID: exerciseID)
        apply(to: m)
        return m
    }
}

// MARK: - WorkoutSession

public struct WorkoutSessionDTO: SyncDTO {
    public var id: UUID
    @NullEncodable public var userID: UUID?
    public var createdAt: Date
    public var updatedAt: Date
    @NullEncodable public var deletedAt: Date?
    public var routineID: UUID?
    public var startedAt: Date
    @NullEncodable public var endedAt: Date?
    public var pausedSeconds: Double
    public var source: String
    @NullEncodable public var activeCalories: Double?
    public var avgHeartRate: Double?
    @NullEncodable public var healthKitWorkoutID: UUID?
    public var importKey: String?

    enum CodingKeys: String, CodingKey {
        case id, source
        case userID = "user_id", createdAt = "created_at", updatedAt = "updated_at", deletedAt = "deleted_at"
        case routineID = "routine_id", startedAt = "started_at", endedAt = "ended_at"
        case pausedSeconds = "paused_seconds", activeCalories = "active_calories", avgHeartRate = "avg_heart_rate"
        case healthKitWorkoutID = "healthkit_workout_id", importKey = "import_key"
    }
}

extension WorkoutSessionDTO {
    public init(_ m: WorkoutSession) {
        self.init(id: m.id, userID: m.userID, createdAt: m.createdAt, updatedAt: m.updatedAt, deletedAt: m.deletedAt,
                  routineID: m.routineID, startedAt: m.startedAt, endedAt: m.endedAt, pausedSeconds: m.pausedSeconds,
                  source: m.sourceRaw, activeCalories: m.activeCalories, avgHeartRate: m.avgHeartRate,
                  healthKitWorkoutID: m.healthKitWorkoutID, importKey: m.importKey)
    }

    public func apply(to m: WorkoutSession) {
        m.userID = userID; m.createdAt = createdAt; m.updatedAt = updatedAt; m.deletedAt = deletedAt
        m.routineID = routineID; m.startedAt = startedAt; m.endedAt = endedAt; m.pausedSeconds = pausedSeconds
        m.sourceRaw = source; m.activeCalories = activeCalories; m.avgHeartRate = avgHeartRate
        m.healthKitWorkoutID = healthKitWorkoutID; m.importKey = importKey
    }

    public func makeModel() -> WorkoutSession {
        let m = WorkoutSession(id: id, source: .phone)
        apply(to: m)
        return m
    }
}

// MARK: - SessionExercise

public struct SessionExerciseDTO: SyncDTO {
    public var id: UUID
    @NullEncodable public var userID: UUID?
    public var createdAt: Date
    public var updatedAt: Date
    @NullEncodable public var deletedAt: Date?
    public var sessionID: UUID
    public var exerciseID: UUID
    public var sortOrder: Int
    @NullEncodable public var note: String?

    enum CodingKeys: String, CodingKey {
        case id, note
        case userID = "user_id", createdAt = "created_at", updatedAt = "updated_at", deletedAt = "deleted_at"
        case sessionID = "session_id", exerciseID = "exercise_id", sortOrder = "sort_order"
    }
}

extension SessionExerciseDTO {
    public init(_ m: SessionExercise) {
        self.init(id: m.id, userID: m.userID, createdAt: m.createdAt, updatedAt: m.updatedAt, deletedAt: m.deletedAt,
                  sessionID: m.sessionID, exerciseID: m.exerciseID, sortOrder: m.sortOrder, note: m.note)
    }

    public func apply(to m: SessionExercise) {
        m.userID = userID; m.createdAt = createdAt; m.updatedAt = updatedAt; m.deletedAt = deletedAt
        m.sessionID = sessionID; m.exerciseID = exerciseID; m.sortOrder = sortOrder; m.note = note
    }

    public func makeModel() -> SessionExercise {
        let m = SessionExercise(id: id, sessionID: sessionID, exerciseID: exerciseID)
        apply(to: m)
        return m
    }
}

// MARK: - SetEntry

public struct SetEntryDTO: SyncDTO {
    public var id: UUID
    @NullEncodable public var userID: UUID?
    public var createdAt: Date
    public var updatedAt: Date
    @NullEncodable public var deletedAt: Date?
    public var sessionExerciseID: UUID
    public var sortOrder: Int
    @NullEncodable public var weightKg: Double?
    public var reps: Int?
    @NullEncodable public var distanceMeters: Double?
    public var durationSeconds: Double?
    @NullEncodable public var restSeconds: Double?
    public var completedAt: Date
    @NullEncodable public var importKey: String?

    enum CodingKeys: String, CodingKey {
        case id, reps
        case userID = "user_id", createdAt = "created_at", updatedAt = "updated_at", deletedAt = "deleted_at"
        case sessionExerciseID = "session_exercise_id", sortOrder = "sort_order", weightKg = "weight_kg"
        case distanceMeters = "distance_meters", durationSeconds = "duration_seconds", restSeconds = "rest_seconds"
        case completedAt = "completed_at", importKey = "import_key"
    }
}

extension SetEntryDTO {
    public init(_ m: SetEntry) {
        self.init(id: m.id, userID: m.userID, createdAt: m.createdAt, updatedAt: m.updatedAt, deletedAt: m.deletedAt,
                  sessionExerciseID: m.sessionExerciseID, sortOrder: m.sortOrder, weightKg: m.weightKg, reps: m.reps,
                  distanceMeters: m.distanceMeters, durationSeconds: m.durationSeconds, restSeconds: m.restSeconds,
                  completedAt: m.completedAt, importKey: m.importKey)
    }

    public func apply(to m: SetEntry) {
        m.userID = userID; m.createdAt = createdAt; m.updatedAt = updatedAt; m.deletedAt = deletedAt
        m.sessionExerciseID = sessionExerciseID; m.sortOrder = sortOrder; m.weightKg = weightKg; m.reps = reps
        m.distanceMeters = distanceMeters; m.durationSeconds = durationSeconds; m.restSeconds = restSeconds
        m.completedAt = completedAt; m.importKey = importKey
    }

    public func makeModel() -> SetEntry {
        let m = SetEntry(id: id, sessionExerciseID: sessionExerciseID)
        apply(to: m)
        return m
    }
}

// MARK: - BodyWeightEntry

public struct BodyWeightEntryDTO: SyncDTO {
    public var id: UUID
    @NullEncodable public var userID: UUID?
    public var createdAt: Date
    public var updatedAt: Date
    @NullEncodable public var deletedAt: Date?
    public var date: Date
    public var weightKg: Double
    @NullEncodable public var healthKitSampleID: UUID?
    public var source: String

    enum CodingKeys: String, CodingKey {
        case id, date, source
        case userID = "user_id", createdAt = "created_at", updatedAt = "updated_at", deletedAt = "deleted_at"
        case weightKg = "weight_kg", healthKitSampleID = "healthkit_sample_id"
    }
}

extension BodyWeightEntryDTO {
    public init(_ m: BodyWeightEntry) {
        self.init(id: m.id, userID: m.userID, createdAt: m.createdAt, updatedAt: m.updatedAt, deletedAt: m.deletedAt,
                  date: m.date, weightKg: m.weightKg, healthKitSampleID: m.healthKitSampleID, source: m.sourceRaw)
    }

    public func apply(to m: BodyWeightEntry) {
        m.userID = userID; m.createdAt = createdAt; m.updatedAt = updatedAt; m.deletedAt = deletedAt
        m.date = date; m.weightKg = weightKg; m.healthKitSampleID = healthKitSampleID; m.sourceRaw = source
    }

    public func makeModel() -> BodyWeightEntry {
        let m = BodyWeightEntry(id: id, weightKg: weightKg)
        apply(to: m)
        return m
    }
}
