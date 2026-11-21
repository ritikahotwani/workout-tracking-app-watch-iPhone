import Foundation
import SwiftData

/// Pull cursor: the last row seen, ordered by `(server_updated_at, id)`.
/// `serverUpdatedAt` is the server's raw timestamp text, passed back verbatim so comparisons are exact
/// (a `Date` would lose Postgres' microseconds). The `id` tie-break matters because every row written
/// by one upsert statement gets the same `server_updated_at`.
public struct SyncCursor: Codable, Sendable, Equatable {
    public var serverUpdatedAt: String
    public var id: UUID

    public init(serverUpdatedAt: String, id: UUID) {
        self.serverUpdatedAt = serverUpdatedAt
        self.id = id
    }
}

/// A pulled row plus its `server_updated_at`, decoded from the same JSON object.
public struct RemoteRow<D: SyncDTO>: Decodable, Sendable {
    public var row: D
    public var serverUpdatedAt: String

    public init(row: D, serverUpdatedAt: String) {
        self.row = row
        self.serverUpdatedAt = serverUpdatedAt
    }

    private enum CodingKeys: String, CodingKey { case serverUpdatedAt = "server_updated_at" }

    public init(from decoder: Decoder) throws {
        row = try D(from: decoder)
        serverUpdatedAt = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .serverUpdatedAt)
    }
}

/// The server side of sync. The app implements it with supabase-swift; tests use a fake.
public protocol RemoteStore: Sendable {
    /// Upsert on conflict `(user_id, id)`.
    func upsert<D: SyncDTO>(_ rows: [D], table: String) async throws
    /// Rows with `(server_updated_at, id) > cursor` (all rows when nil), ordered by `server_updated_at, id`.
    func fetch<D: SyncDTO>(_ type: D.Type, table: String, after cursor: SyncCursor?, limit: Int) async throws -> [RemoteRow<D>]
}

/// Errors a `RemoteStore` should throw so `friendlyMessage(for:)` can explain them.
/// Network failures can be thrown as the underlying `URLError`.
public enum SyncError: Error, Equatable {
    case signedOut
    case serverRejected
}

public struct SyncResult: Sendable, Equatable {
    public var pushed: Int
    public var pulled: Int
    public var finishedAt: Date
}

/// Push-then-pull sync with Supabase (PLAN §3.2). Single-flight: concurrent calls for the same user share
/// one run; a call for another user waits for the current run to finish.
public actor SyncEngine {
    /// Table name per DTO, in dependency order.
    public static var tables: [(dto: any SyncDTO.Type, table: String)] {
        [(ExerciseDTO.self, "exercises"), (RoutineDTO.self, "routines"),
         (RoutineExerciseDTO.self, "routine_exercises"), (WorkoutSessionDTO.self, "workout_sessions"),
         (SessionExerciseDTO.self, "session_exercises"), (SetEntryDTO.self, "set_entries"),
         (BodyWeightEntryDTO.self, "body_weight_entries")]
    }

    let container: ModelContainer
    let remote: any RemoteStore
    let defaults: UserDefaults
    let pageSize: Int
    let pushBatchSize = 500
    private var inFlight: (userID: UUID, task: Task<SyncResult, Error>)?

    /// Pull cursors persist in `UserDefaults(suiteName: defaultsSuite)` (standard when nil), keyed by user and table.
    public init(container: ModelContainer, remote: any RemoteStore, defaultsSuite: String? = nil, pageSize: Int = 1000) {
        self.container = container
        self.remote = remote
        self.defaults = defaultsSuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        self.pageSize = pageSize
    }

    public func sync(userID: UUID) async throws -> SyncResult {
        while let current = inFlight {
            if current.userID == userID { return try await current.task.value }
            _ = try? await current.task.value
            // Its caller may not have resumed yet; clear it here or this loop spins on a finished task.
            if inFlight?.task == current.task { inFlight = nil }
        }
        let task = Task { try await run(userID: userID) }
        inFlight = (userID, task)
        defer { if inFlight?.task == task { inFlight = nil } }
        return try await task.value
    }

    private func run(userID: UUID) async throws -> SyncResult {
        var pushed = 0, pulled = 0
        // A failed push must not block restore: pull anyway, then report the push error.
        var pushError: Error?
        do {
            for t in Self.tables { pushed += try await push(t.dto, table: t.table, userID: userID) }
        } catch { pushError = error }
        do {
            for t in Self.tables {
                let n = try await pull(t.dto, table: t.table, userID: userID)
                if t.table == "body_weight_entries", n > 0 { try dedupeBodyWeights() }
                pulled += n
            }
        } catch { throw pushError ?? error }
        if let pushError { throw pushError }
        return SyncResult(pushed: pushed, pulled: pulled, finishedAt: .now)
    }

    /// A restore can bring back rows for Health samples this install already imported.
    private func dedupeBodyWeights() throws {
        let ctx = ModelContext(container)
        let live = try ctx.fetch(FetchDescriptor<BodyWeightEntry>(predicate: #Predicate {
            $0.deletedAt == nil && $0.healthKitSampleID != nil }))
        if BodyWeightDedupe.dedupe(live) > 0 { try ctx.save() }
    }

    // ModelContexts are short-lived and never held across an `await`, so each read sees the store's
    // current state (e.g. edits saved by the UI while an upsert was in flight).

    private func push<D: SyncDTO>(_: D.Type, table: String, userID: UUID) async throws -> Int {
        var pushed = 0
        while true {
            // Rows owned by another account (left from before an account switch) are never pushed.
            let owner: UUID? = userID
            var descriptor = FetchDescriptor<D.Model>(predicate: #Predicate {
                $0.needsPush == true && ($0.userID == nil || $0.userID == owner) })
            descriptor.fetchLimit = pushBatchSize
            let dirty = try ModelContext(container).fetch(descriptor)
            if dirty.isEmpty { return pushed }
            let sentAt = Dictionary(uniqueKeysWithValues: dirty.map { ($0.id, $0.updatedAt) })
            let rows = dirty.map { model -> D in
                model.userID = userID  // this context is never saved; the stamp persists below on success
                return D(model)
            }

            try await remote.upsert(rows, table: table)
            pushed += rows.count

            let ctx = ModelContext(container)
            let ids = Array(sentAt.keys)
            for model in try ctx.fetch(FetchDescriptor<D.Model>(predicate: #Predicate { ids.contains($0.id) })) {
                model.userID = userID
                // Edited while the upsert was in flight: stays dirty and goes in the next batch.
                if model.updatedAt == sentAt[model.id] { model.needsPush = false }
            }
            try ctx.save()
        }
    }

    // MARK: Account switch

    /// Whether any synced row belongs to `owner`.
    public static func hasRows(ownedBy owner: UUID, in context: ModelContext) throws -> Bool {
        func owns<D: SyncDTO>(_: D.Type) throws -> Bool {
            let o: UUID? = owner
            var d = FetchDescriptor<D.Model>(predicate: #Predicate { $0.userID == o })
            d.fetchLimit = 1
            return try context.fetchCount(d) > 0
        }
        for t in tables where try owns(t.dto) { return true }
        return false
    }

    /// Hard-deletes every synced row, then re-seeds the built-in exercises. Saves.
    public static func wipeLocalData(_ context: ModelContext) throws {
        func wipe<D: SyncDTO>(_: D.Type) throws {
            for m in try context.fetch(FetchDescriptor<D.Model>()) { context.delete(m) }
        }
        for t in tables { try wipe(t.dto) }
        try context.save()
        try ExerciseLibrary.seedIfNeeded(context)
    }

    /// Forgets `userID`'s pull cursors, so the next sync is a full restore.
    public func clearCursors(userID: UUID) {
        for t in Self.tables { defaults.removeObject(forKey: cursorKey(userID, t.table)) }
    }

    private func cursorKey(_ userID: UUID, _ table: String) -> String { "syncCursor.\(userID.uuidString).\(table)" }

    private func pull<D: SyncDTO>(_: D.Type, table: String, userID: UUID) async throws -> Int {
        let key = cursorKey(userID, table)
        var cursor = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(SyncCursor.self, from: $0) }
        var applied = 0
        while true {
            let page = try await remote.fetch(D.self, table: table, after: cursor, limit: pageSize)
            guard let last = page.last else { return applied }
            let ctx = ModelContext(container)
            for r in page {
                if try LWW.upsert(r.row, into: ctx, markForPush: false) { applied += 1 }
            }
            try ctx.save()
            cursor = SyncCursor(serverUpdatedAt: last.serverUpdatedAt, id: last.row.id)
            defaults.set(try JSONEncoder().encode(cursor), forKey: key)
        }
    }
}

extension BodyWeightDedupe {
    /// Leaves one live entry per Health sample: the one not imported from Health, else the oldest
    /// `createdAt`. Soft-deletes the rest (so the deletion syncs) and returns how many.
    @discardableResult
    public static func dedupe(_ entries: [BodyWeightEntry]) -> Int {
        var deleted = 0
        let live = entries.filter { $0.deletedAt == nil && $0.healthKitSampleID != nil }
        for group in Dictionary(grouping: live, by: \.healthKitSampleID).values where group.count > 1 {
            let keep = group.min { a, b in
                (a.source == .health) != (b.source == .health) ? b.source == .health : a.createdAt < b.createdAt
            }!
            for e in group where e !== keep { e.markDeleted(); deleted += 1 }
        }
        return deleted
    }
}

/// Plain-language text for Settings.
public func friendlyMessage(for error: Error) -> String {
    switch error {
    case let e as URLError where [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
                                  .internationalRoamingOff, .cannotFindHost, .cannotConnectToHost,
                                  .dnsLookupFailed, .timedOut].contains(e.code):
        return "No internet. Changes will back up later."
    case SyncError.signedOut:
        return "Signed out. Sign in to back up."
    case SyncError.serverRejected:
        return "The server rejected some changes. They'll be retried on the next backup."
    default:
        return "Backup failed. It will be retried later."
    }
}
