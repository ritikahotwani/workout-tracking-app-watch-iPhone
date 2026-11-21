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

/// Push-then-pull sync with Supabase (PLAN §3.2). Single-flight: concurrent calls share one run.
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
    private var inFlight: Task<SyncResult, Error>?

    /// Pull cursors persist in `UserDefaults(suiteName: defaultsSuite)` (standard when nil), keyed by user and table.
    public init(container: ModelContainer, remote: any RemoteStore, defaultsSuite: String? = nil, pageSize: Int = 1000) {
        self.container = container
        self.remote = remote
        self.defaults = defaultsSuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        self.pageSize = pageSize
    }

    public func sync(userID: UUID) async throws -> SyncResult {
        if let inFlight { return try await inFlight.value }
        let task = Task { try await run(userID: userID) }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }

    private func run(userID: UUID) async throws -> SyncResult {
        var pushed = 0, pulled = 0
        for t in Self.tables { pushed += try await push(t.dto, table: t.table, userID: userID) }
        for t in Self.tables { pulled += try await pull(t.dto, table: t.table, userID: userID) }
        return SyncResult(pushed: pushed, pulled: pulled, finishedAt: .now)
    }

    // ModelContexts are short-lived and never held across an `await`, so each read sees the store's
    // current state (e.g. edits saved by the UI while an upsert was in flight).

    private func push<D: SyncDTO>(_: D.Type, table: String, userID: UUID) async throws -> Int {
        var pushed = 0
        while true {
            var descriptor = FetchDescriptor<D.Model>(predicate: #Predicate { $0.needsPush == true })
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

    private func pull<D: SyncDTO>(_: D.Type, table: String, userID: UUID) async throws -> Int {
        let key = "syncCursor.\(userID.uuidString).\(table)"
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
            if page.count < pageSize { return applied }
        }
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
