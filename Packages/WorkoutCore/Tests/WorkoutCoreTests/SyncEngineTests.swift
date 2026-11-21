import Foundation
import SwiftData
import Testing
@testable import WorkoutCore

/// In-memory Supabase stand-in for one signed-in user. Emulates the migration's behaviour:
/// RLS user check, upsert on (user_id, id), the keep_newer trigger, and server_updated_at
/// stamped once per statement (like now()) and also on rejected writes.
actor FakeRemoteStore: RemoteStore {
    struct Stored { var json: Data; var updatedAt: Date; var serverUpdatedAt: String }

    let userID: UUID
    private var tables: [String: [UUID: Stored]] = [:]
    private var tick = 0
    var upsertCalls: [String: Int] = [:]
    var fetchCalls: [String: Int] = [:]
    var failUpsert: Error?
    var onUpsert: (@Sendable () async throws -> Void)?

    init(userID: UUID) { self.userID = userID }

    func setFailUpsert(_ e: Error?) { failUpsert = e }
    func setOnUpsert(_ f: (@Sendable () async throws -> Void)?) { onUpsert = f }

    func upsert<D: SyncDTO>(_ rows: [D], table: String) async throws {
        upsertCalls[table, default: 0] += 1
        if let failUpsert { throw failUpsert }
        try await onUpsert?()
        tick += 1
        let now = String(format: "%012d", tick)
        for row in rows {
            let json = try JSONEncoder.sync.encode(row)
            let object = try JSONSerialization.jsonObject(with: json) as! [String: Any]
            guard object["user_id"] as? String == userID.uuidString else { throw SyncError.serverRejected }
            let wire = try JSONDecoder.sync.decode(D.self, from: json)  // what Postgres would store
            if let old = tables[table]?[row.id], wire.updatedAt < old.updatedAt {
                tables[table]![row.id]!.serverUpdatedAt = now
            } else {
                tables[table, default: [:]][row.id] = Stored(json: json, updatedAt: wire.updatedAt, serverUpdatedAt: now)
            }
        }
    }

    func fetch<D: SyncDTO>(_ type: D.Type, table: String, after cursor: SyncCursor?, limit: Int) async throws -> [RemoteRow<D>] {
        fetchCalls[table, default: 0] += 1
        func key(_ ts: String, _ id: UUID) -> (String, String) { (ts, id.uuidString.lowercased()) }  // Postgres uuid order
        return try (tables[table] ?? [:])
            .filter { cursor == nil || key($0.value.serverUpdatedAt, $0.key) > key(cursor!.serverUpdatedAt, cursor!.id) }
            .sorted { key($0.value.serverUpdatedAt, $0.key) < key($1.value.serverUpdatedAt, $1.key) }
            .prefix(limit)
            .map { _, stored in
                var object = try JSONSerialization.jsonObject(with: stored.json) as! [String: Any]
                object["server_updated_at"] = stored.serverUpdatedAt
                return try JSONDecoder.sync.decode(RemoteRow<D>.self, from: JSONSerialization.data(withJSONObject: object))
            }
    }

    func rows<D: SyncDTO>(_: D.Type, _ table: String) throws -> [D] {
        try (tables[table] ?? [:]).values.map { try JSONDecoder.sync.decode(D.self, from: $0.json) }
    }
}

/// One phone: its own store, cursor defaults and engine.
struct Device {
    let container: ModelContainer
    let engine: SyncEngine
    let defaultsSuite = UUID().uuidString

    init(_ remote: FakeRemoteStore, pageSize: Int = 1000) throws {
        container = try makeModelContainer(inMemory: true)
        engine = SyncEngine(container: container, remote: remote, defaultsSuite: defaultsSuite, pageSize: pageSize)
    }

    func insert(_ models: any PersistentModel...) throws { try insert(models) }

    func insert(_ models: [any PersistentModel]) throws {
        let ctx = ModelContext(container)
        for m in models { ctx.insert(m) }
        try ctx.save()
    }

    /// Reads with a fresh context, so it sees what the engine saved.
    func read<M: PersistentModel, T>(_: M.Type, _ f: ([M]) throws -> T) throws -> T {
        try f(ModelContext(container).fetch(FetchDescriptor<M>()))
    }

    func edit<M: Syncable>(_: M.Type, id: UUID, _ f: (M) -> Void) throws {
        let ctx = ModelContext(container)
        try ctx.fetch(FetchDescriptor<M>(predicate: #Predicate { $0.id == id })).forEach(f)
        try ctx.save()
    }
}

@Suite struct SyncEngineTests {
    let user = UUID()
    let t0 = Date(timeIntervalSince1970: 1_800_000_000.25)  // exact through millisecond ISO 8601

    @Test func pushClearsDirtyFlags() async throws {
        let fake = FakeRemoteStore(userID: user)
        let phone = try Device(fake)
        try phone.insert(Routine(name: "Chest", updatedAt: t0), Exercise(name: "Squat", updatedAt: t0))

        let result = try await phone.engine.sync(userID: user)

        #expect(result.pushed == 2)
        try phone.read(Routine.self) { #expect($0.allSatisfy { !$0.needsPush && $0.userID == user }) }
        try phone.read(Exercise.self) { #expect($0.allSatisfy { !$0.needsPush && $0.userID == user }) }
        #expect(try await fake.rows(RoutineDTO.self, "routines").map(\.name) == ["Chest"])
    }

    @Test func failedPushKeepsDirtyFlags() async throws {
        let fake = FakeRemoteStore(userID: user)
        await fake.setFailUpsert(URLError(.notConnectedToInternet))
        let phone = try Device(fake)
        try phone.insert(Routine(name: "Chest", updatedAt: t0))

        await #expect(throws: URLError.self) { try await phone.engine.sync(userID: user) }

        try phone.read(Routine.self) { #expect($0.count == 1 && $0[0].needsPush) }
        #expect(friendlyMessage(for: URLError(.notConnectedToInternet)) == "No internet. Changes will back up later.")
        #expect(friendlyMessage(for: SyncError.signedOut) == "Signed out. Sign in to back up.")
        #expect(friendlyMessage(for: SyncError.serverRejected).contains("rejected"))
        #expect(friendlyMessage(for: CocoaError(.fileNoSuchFile)) == "Backup failed. It will be retried later.")
    }

    @Test func editDuringPushStaysDirty() async throws {
        let fake = FakeRemoteStore(userID: user)
        let phone = try Device(fake)
        let routine = Routine(name: "Chest", updatedAt: t0)
        let id = routine.id
        try phone.insert(routine)
        let container = phone.container, t0 = t0
        await fake.setOnUpsert {
            await fake.setOnUpsert(nil)  // only during the first upsert
            let ctx = ModelContext(container)
            let r = try ctx.fetch(FetchDescriptor<Routine>(predicate: #Predicate { $0.id == id }))[0]
            r.name = "Chest Day"; r.updatedAt = t0 + 5; r.needsPush = true
            try ctx.save()
        }

        _ = try await phone.engine.sync(userID: user)

        // Not cleared after the first upsert, so it went again in the next batch.
        #expect(await fake.upsertCalls["routines"] == 2)
        #expect(try await fake.rows(RoutineDTO.self, "routines").map(\.name) == ["Chest Day"])
        try phone.read(Routine.self) { #expect($0[0].name == "Chest Day" && !$0[0].needsPush) }
    }

    @Test func pullAppliesNewerAndSkipsOlder() async throws {
        let fake = FakeRemoteStore(userID: user)
        let phone = try Device(fake)
        let a = Routine(name: "Local A", updatedAt: t0, needsPush: false)
        let b = Routine(name: "Local B", updatedAt: t0, needsPush: false)
        try phone.insert(a, b)
        var newer = RoutineDTO(a), older = RoutineDTO(b)
        newer.userID = user; newer.name = "Remote A"; newer.updatedAt = t0 + 10
        older.userID = user; older.name = "Remote B"; older.updatedAt = t0 - 10
        try await fake.upsert([newer, older], table: "routines")

        let result = try await phone.engine.sync(userID: user)

        #expect(result.pulled == 1)
        try phone.read(Routine.self) { rs in
            #expect(Set(rs.map(\.name)) == ["Remote A", "Local B"])
            #expect(rs.allSatisfy { !$0.needsPush })
        }
    }

    @Test func softDeletePropagatesBothWays() async throws {
        let fake = FakeRemoteStore(userID: user)
        let a = try Device(fake), b = try Device(fake)
        let r1 = Routine(name: "Push", updatedAt: t0), r2 = Routine(name: "Pull", updatedAt: t0)
        let id1 = r1.id, id2 = r2.id
        try a.insert(r1, r2)
        _ = try await a.engine.sync(userID: user)
        _ = try await b.engine.sync(userID: user)
        try b.read(Routine.self) { #expect($0.count == 2) }

        let t1 = t0 + 10
        try a.edit(Routine.self, id: id1) { $0.deletedAt = t1; $0.updatedAt = t1; $0.needsPush = true }
        try b.edit(Routine.self, id: id2) { $0.deletedAt = t1; $0.updatedAt = t1; $0.needsPush = true }
        _ = try await a.engine.sync(userID: user)
        _ = try await b.engine.sync(userID: user)
        _ = try await a.engine.sync(userID: user)

        for device in [a, b] {
            try device.read(Routine.self) { #expect($0.count == 2 && $0.allSatisfy { $0.deletedAt == t1 }) }
        }
    }

    @Test func cursorPagination() async throws {
        let fake = FakeRemoteStore(userID: user)
        let a = try Device(fake)
        let sessionExerciseID = UUID()
        // One upsert statement, so all 7 rows share a server_updated_at: pages must tie-break on id.
        try a.insert((0..<7).map { SetEntry(sessionExerciseID: sessionExerciseID, sortOrder: $0, reps: 5, updatedAt: t0) })
        _ = try await a.engine.sync(userID: user)
        #expect(await fake.upsertCalls["set_entries"] == 1)

        let before = await fake.fetchCalls["set_entries"] ?? 0
        let b = try Device(fake, pageSize: 3)
        let first = try await b.engine.sync(userID: user)
        #expect(first.pulled == 7)
        #expect(await fake.fetchCalls["set_entries"] == before + 3)  // 3 + 3 + 1
        try b.read(SetEntry.self) { #expect(Set($0.map(\.sortOrder)) == Set(0..<7)) }

        // Cursor persisted in defaults: a new engine on the same device fetches nothing new.
        let again = SyncEngine(container: b.container, remote: fake, defaultsSuite: b.defaultsSuite, pageSize: 3)
        #expect(try await again.sync(userID: user).pulled == 0)
        #expect(await fake.fetchCalls["set_entries"] == before + 4)
    }

    @Test func fullRestoreIntoEmptyContainer() async throws {
        let fake = FakeRemoteStore(userID: user)
        let old = try Device(fake)
        let ex = Exercise(name: "Bench Press", updatedAt: t0)
        let routine = Routine(name: "Chest", updatedAt: t0)
        let session = WorkoutSession(routineID: routine.id, startedAt: t0, source: .watch, updatedAt: t0)
        let se = SessionExercise(sessionID: session.id, exerciseID: ex.id, note: "slow", updatedAt: t0)
        try old.insert(ex, routine, RoutineExercise(routineID: routine.id, exerciseID: ex.id, updatedAt: t0), session, se,
                       SetEntry(sessionExerciseID: se.id, weightKg: 80, reps: 5, completedAt: t0, updatedAt: t0),
                       BodyWeightEntry(date: t0, weightKg: 75, updatedAt: t0))
        #expect(try await old.engine.sync(userID: user).pushed == 7)

        let fresh = try Device(fake)
        let result = try await fresh.engine.sync(userID: user)

        #expect(result.pushed == 0 && result.pulled == 7)
        try fresh.read(Exercise.self) { #expect($0.map(\.name) == ["Bench Press"] && !$0[0].needsPush) }
        try fresh.read(Routine.self) { #expect($0.map(\.name) == ["Chest"]) }
        try fresh.read(RoutineExercise.self) { #expect($0.map(\.routineID) == [routine.id]) }
        try fresh.read(WorkoutSession.self) { #expect($0.map(\.routineID) == [routine.id] && $0[0].source == .watch) }
        try fresh.read(SessionExercise.self) { #expect($0.map(\.note) == ["slow"]) }
        try fresh.read(SetEntry.self) { #expect($0.map(\.weightKg) == [80] && $0[0].durationSeconds == nil) }
        try fresh.read(BodyWeightEntry.self) { #expect($0.map(\.weightKg) == [75] && $0[0].userID == user) }
    }

    @Test func builtInExerciseIDsDoNotDuplicateOnRestore() async throws {
        let fake = FakeRemoteStore(userID: user)
        let id = Exercise.builtInID(for: "Bench Press")
        let old = try Device(fake)
        try old.insert(Exercise(id: id, name: "Bench Press", isBuiltIn: true, defaultRestSeconds: 120, updatedAt: t0))
        _ = try await old.engine.sync(userID: user)

        // Fresh install seeds the same built-in before restoring (old timestamp, still dirty).
        let fresh = try Device(fake)
        try fresh.insert(Exercise(id: id, name: "Bench Press", isBuiltIn: true, defaultRestSeconds: 90,
                                  updatedAt: Date(timeIntervalSince1970: 0)))
        _ = try await fresh.engine.sync(userID: user)

        try fresh.read(Exercise.self) { #expect($0.count == 1 && $0[0].defaultRestSeconds == 120 && !$0[0].needsPush) }
        #expect(try await fake.rows(ExerciseDTO.self, "exercises").map(\.defaultRestSeconds) == [120])
    }

    @Test func twoDevicesConvergeToNewestUpdatedAt() async throws {
        let fake = FakeRemoteStore(userID: user)
        let a = try Device(fake), b = try Device(fake)
        let routine = Routine(name: "Chest", updatedAt: t0)
        let id = routine.id
        try a.insert(routine)
        _ = try await a.engine.sync(userID: user)
        _ = try await b.engine.sync(userID: user)

        func both() throws -> [String] {
            try [a, b].map { try $0.read(Routine.self) { $0[0].name } }
        }

        // Older edit syncs second: the server keeps the newer row and hands it back.
        try a.edit(Routine.self, id: id) { $0.name = "A"; $0.updatedAt = t0 + 10; $0.needsPush = true }
        try b.edit(Routine.self, id: id) { $0.name = "B"; $0.updatedAt = t0 + 20; $0.needsPush = true }
        _ = try await b.engine.sync(userID: user)
        _ = try await a.engine.sync(userID: user)
        _ = try await b.engine.sync(userID: user)
        #expect(try both() == ["B", "B"])

        // Newer edit syncs first.
        try a.edit(Routine.self, id: id) { $0.name = "A2"; $0.updatedAt = t0 + 40; $0.needsPush = true }
        try b.edit(Routine.self, id: id) { $0.name = "B2"; $0.updatedAt = t0 + 30; $0.needsPush = true }
        _ = try await a.engine.sync(userID: user)
        _ = try await b.engine.sync(userID: user)
        _ = try await a.engine.sync(userID: user)
        #expect(try both() == ["A2", "A2"])
        #expect(try await fake.rows(RoutineDTO.self, "routines").map(\.name) == ["A2"])
    }

    @Test func concurrentSyncsCoalesce() async throws {
        let fake = FakeRemoteStore(userID: user)
        let phone = try Device(fake)
        try phone.insert(Routine(name: "Chest", updatedAt: t0))
        await fake.setOnUpsert { try await Task.sleep(for: .milliseconds(50)) }

        let engine = phone.engine, user = user
        async let first = engine.sync(userID: user)
        async let second = engine.sync(userID: user)
        let results = try await [first, second]

        #expect(results[0] == results[1])
        #expect(await fake.upsertCalls["routines"] == 1)
    }
}
