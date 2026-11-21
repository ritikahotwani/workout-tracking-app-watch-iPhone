import Foundation
import SwiftData

// Watch ↔ iPhone payloads (PLAN §3.1). Rows travel as the same DTOs used for Supabase and merge through `LWW`.

/// One WatchConnectivity message: application context / file (phone → watch) or userInfo (watch → phone).
public struct ConnectivityPayload: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// Phone → watch: library, routines, units, snapshots.
        case context
        /// Watch → phone: one session with its exercises and sets.
        case session
        /// Watch → phone: body-weight entries.
        case bodyWeight
    }

    /// Key of the encoded payload in the WatchConnectivity dictionary.
    public static let key = "payload"

    public var kind: Kind
    /// Lets the watch drop a context older than one it already applied (context and file can race).
    public var sentAt: Date
    public var exercises: [ExerciseDTO]
    public var routines: [RoutineDTO]
    public var routineExercises: [RoutineExerciseDTO]
    public var sessions: [WorkoutSessionDTO]
    public var sessionExercises: [SessionExerciseDTO]
    public var sets: [SetEntryDTO]
    public var bodyWeights: [BodyWeightEntryDTO]
    /// `WeightUnit` / `DistanceUnit` raw values; nil leaves the watch's setting alone.
    public var weightUnit: String?
    public var distanceUnit: String?
    public var snapshots: [ExerciseSnapshot]

    public init(kind: Kind, sentAt: Date = .now, exercises: [ExerciseDTO] = [], routines: [RoutineDTO] = [],
                routineExercises: [RoutineExerciseDTO] = [], sessions: [WorkoutSessionDTO] = [],
                sessionExercises: [SessionExerciseDTO] = [], sets: [SetEntryDTO] = [],
                bodyWeights: [BodyWeightEntryDTO] = [], weightUnit: String? = nil, distanceUnit: String? = nil,
                snapshots: [ExerciseSnapshot] = []) {
        self.kind = kind
        self.sentAt = sentAt
        self.exercises = exercises
        self.routines = routines
        self.routineExercises = routineExercises
        self.sessions = sessions
        self.sessionExercises = sessionExercises
        self.sets = sets
        self.bodyWeights = bodyWeights
        self.weightUnit = weightUnit
        self.distanceUnit = distanceUnit
        self.snapshots = snapshots
    }

    public func encoded() throws -> Data { try JSONEncoder.sync.encode(self) }

    public static func decode(_ data: Data) throws -> ConnectivityPayload {
        try JSONDecoder.sync.decode(ConnectivityPayload.self, from: data)
    }

    /// LWW-merges every row in dependency order, then dedupes body weight by Health sample.
    /// Returns how many rows were applied. The caller saves.
    @discardableResult
    public func merge(into context: ModelContext, markForPush: Bool) throws -> Int {
        func upsert<D: SyncDTO>(_ rows: [D]) throws -> Int {
            try rows.reduce(0) { $0 + (try LWW.upsert($1, into: context, markForPush: markForPush) ? 1 : 0) }
        }
        var applied = try upsert(exercises) + upsert(routines) + upsert(routineExercises)
        applied += try upsert(sessions) + upsert(sessionExercises) + upsert(sets)
        applied += try upsert(bodyWeights)
        for dto in bodyWeights {
            guard let sample = dto.healthKitSampleID else { continue }
            let sid: UUID? = sample
            let holders = try context.fetch(FetchDescriptor<BodyWeightEntry>(predicate: #Predicate { $0.healthKitSampleID == sid }))
            BodyWeightDedupe.apply(incoming: dto, to: holders)
        }
        return applied
    }
}

public enum BodyWeightDedupe {
    /// The phone may import a watch-written Health sample before the watch's own row arrives. Keeps the
    /// incoming row and soft-deletes any other live entry holding the same sample. Returns the deleted entries.
    @discardableResult
    public static func apply(incoming: BodyWeightEntryDTO, to existing: [BodyWeightEntry]) -> [BodyWeightEntry] {
        guard incoming.deletedAt == nil, let sample = incoming.healthKitSampleID else { return [] }
        let dupes = existing.filter { $0.id != incoming.id && $0.healthKitSampleID == sample && $0.deletedAt == nil }
        for d in dupes { d.markDeleted() }
        return dupes
    }
}

// MARK: - Snapshot

/// Values of one set from the last session, canonical units.
public struct SnapshotSet: Codable, Sendable, Equatable {
    public var weightKg: Double?
    public var reps: Int?
    public var distanceMeters: Double?
    public var durationSeconds: Double?

    public init(weightKg: Double? = nil, reps: Int? = nil, distanceMeters: Double? = nil, durationSeconds: Double? = nil) {
        self.weightKg = weightKg
        self.reps = reps
        self.distanceMeters = distanceMeters
        self.durationSeconds = durationSeconds
    }
}

/// Per-exercise summary of all phone history, so the watch knows "last time" and PRs beyond its own store.
public struct ExerciseSnapshot: Codable, Sendable, Equatable {
    public var exerciseID: UUID
    /// `completedAt` of the newest set in `lastSets`.
    public var lastDate: Date?
    public var lastSets: [SnapshotSet]
    public var baseline: PRBaseline

    public init(exerciseID: UUID, lastDate: Date?, lastSets: [SnapshotSet], baseline: PRBaseline) {
        self.exerciseID = exerciseID
        self.lastDate = lastDate
        self.lastSets = lastSets
        self.baseline = baseline
    }

    /// One snapshot per exercise in `logged` (oldest first, as `Queries.loggedSets` returns).
    public static func make(from logged: [Queries.LoggedSet]) -> [ExerciseSnapshot] {
        let baselines = PersonalRecords.baselines(logged.compactMap(\.record))
        return Dictionary(grouping: logged, by: \.exerciseID).map { id, sets in
            let lastSession = sets.last?.sessionID
            let last = sets.filter { $0.sessionID == lastSession }.map(\.set)
            return ExerciseSnapshot(
                exerciseID: id, lastDate: last.map(\.completedAt).max(),
                lastSets: last.map { SnapshotSet(weightKg: $0.weightKg, reps: $0.reps, distanceMeters: $0.distanceMeters,
                                                 durationSeconds: $0.durationSeconds) },
                baseline: baselines[id] ?? PRBaseline())
        }
    }

    /// `local` (this device's last-session sets) unless the snapshot's are newer; ties keep local.
    /// Snapshot sets come back as unsaved `SetEntry`s, never inserted.
    public func lastPerformance(local: [SetEntry]) -> [SetEntry] {
        guard let lastDate, !lastSets.isEmpty, lastDate > (local.map(\.completedAt).max() ?? .distantPast) else { return local }
        return lastSets.enumerated().map { i, s in
            SetEntry(sessionExerciseID: exerciseID, sortOrder: i, weightKg: s.weightKg, reps: s.reps,
                     distanceMeters: s.distanceMeters, durationSeconds: s.durationSeconds, completedAt: lastDate)
        }
    }
}

extension PRBaseline {
    /// Field-wise max of two baselines.
    public func merged(with other: PRBaseline) -> PRBaseline {
        func best(_ a: Double?, _ b: Double?) -> Double? { [a, b].compactMap { $0 }.max() }
        return PRBaseline(heaviestKg: best(heaviestKg, other.heaviestKg), bestE1RM: best(bestE1RM, other.bestE1RM),
                          bestRepsByWeight: bestRepsByWeight.merging(other.bestRepsByWeight, uniquingKeysWith: max),
                          bestSessionVolume: best(bestSessionVolume, other.bestSessionVolume))
    }
}
