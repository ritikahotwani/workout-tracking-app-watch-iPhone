import Foundation
import SwiftData
import Testing
@testable import WorkoutCore

@MainActor @Suite struct ConnectivityTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let bench = Exercise.builtInID(for: "Bench Press")

    /// A watch session batch: one session, one exercise, two sets.
    func sessionBatch() -> ConnectivityPayload {
        let session = WorkoutSession(startedAt: t0, endedAt: t0 + 600, source: .watch, createdAt: t0, updatedAt: t0 + 600)
        let entry = SessionExercise(sessionID: session.id, exerciseID: bench, createdAt: t0, updatedAt: t0)
        let sets = [80.0, 85].enumerated().map { i, kg in
            SetEntry(sessionExerciseID: entry.id, sortOrder: i, weightKg: kg, reps: 5, completedAt: t0 + Double(i) * 60,
                     createdAt: t0, updatedAt: t0)
        }
        return ConnectivityPayload(kind: .session, sentAt: t0, sessions: [.init(session)], sessionExercises: [.init(entry)],
                                   sets: sets.map(SetEntryDTO.init))
    }

    func count<M: PersistentModel>(_: M.Type, _ ctx: ModelContext) throws -> Int { try ctx.fetchCount(FetchDescriptor<M>()) }

    @Test func envelopeRoundTrip() throws {
        var p = sessionBatch()
        p.kind = .context
        p.exercises = [ExerciseDTO(Exercise(id: bench, name: "Bench Press", createdAt: t0, updatedAt: t0))]
        let routine = Routine(name: "Chest", createdAt: t0, updatedAt: t0)
        p.routines = [RoutineDTO(routine)]
        p.routineExercises = [RoutineExerciseDTO(RoutineExercise(routineID: routine.id, exerciseID: bench, createdAt: t0, updatedAt: t0))]
        p.bodyWeights = [BodyWeightEntryDTO(BodyWeightEntry(date: t0, weightKg: 80, healthKitSampleID: UUID(), createdAt: t0, updatedAt: t0))]
        p.weightUnit = "lb"
        p.snapshots = [ExerciseSnapshot(exerciseID: bench, lastDate: t0, lastSets: [SnapshotSet(weightKg: 80, reps: 5)],
                                        baseline: PRBaseline(heaviestKg: 100, bestE1RM: 110, bestRepsByWeight: [80: 8, 100: 1],
                                                             bestSessionVolume: 2000))]
        #expect(try ConnectivityPayload.decode(p.encoded()) == p)
    }

    @Test func mergeSessionIntoEmptyPhoneStore() throws {
        let container = try makeModelContainer(inMemory: true)
        let ctx = container.mainContext
        #expect(try sessionBatch().merge(into: ctx, markForPush: true) == 4)
        try ctx.save()
        #expect(try count(WorkoutSession.self, ctx) == 1)
        #expect(try ctx.fetch(FetchDescriptor<SetEntry>()).allSatisfy(\.needsPush))
        let logged = try Queries.loggedSets(in: ctx)
        #expect(logged.map { $0.set.weightKg } == [80, 85])
        #expect(logged.allSatisfy { $0.exerciseID == bench })
    }

    @Test func redeliveryIsIdempotent() throws {
        let container = try makeModelContainer(inMemory: true)
        let ctx = container.mainContext
        let batch = sessionBatch()
        try batch.merge(into: ctx, markForPush: true)
        try ctx.save()
        #expect(try batch.merge(into: ctx, markForPush: true) == 0)
        try ctx.save()
        #expect(try count(SetEntry.self, ctx) == 2)
        #expect(try count(SessionExercise.self, ctx) == 1)
    }

    @Test func olderUpdateDoesNotOverwriteNewer() throws {
        let container = try makeModelContainer(inMemory: true)
        let ctx = container.mainContext
        var batch = sessionBatch()
        batch.sets[0].weightKg = 90
        batch.sets[0].updatedAt = t0 + 100
        try batch.merge(into: ctx, markForPush: true)
        try ctx.save()

        let stale = sessionBatch()  // same rows, older updatedAt
        try stale.merge(into: ctx, markForPush: true)
        let id = batch.sets[0].id
        let set = try #require(try ctx.fetch(FetchDescriptor<SetEntry>(predicate: #Predicate { $0.id == id })).first)
        #expect(set.weightKg == 90)
    }

    @Test func snapshotMergePicksNewerLastTimeAndMaxPRs() throws {
        let local = [SetEntry(sessionExerciseID: UUID(), weightKg: 60, reps: 10, completedAt: t0)]
        let snap = ExerciseSnapshot(exerciseID: bench, lastDate: t0 + 100, lastSets: [SnapshotSet(weightKg: 80, reps: 5)],
                                    baseline: PRBaseline(heaviestKg: 100, bestE1RM: 105, bestRepsByWeight: [60: 8, 100: 1]))
        #expect(snap.lastPerformance(local: local).map(\.weightKg) == [80])
        var older = snap
        older.lastDate = t0 - 100
        #expect(older.lastPerformance(local: local).map(\.weightKg) == [60])
        older.lastDate = t0
        #expect(older.lastPerformance(local: local).map(\.weightKg) == [60])  // tie keeps local
        #expect(snap.lastPerformance(local: []).map(\.reps) == [5])

        let localBaseline = PRBaseline(heaviestKg: 90, bestE1RM: 120, bestRepsByWeight: [60: 12, 70: 6], bestSessionVolume: 3000)
        let merged = localBaseline.merged(with: snap.baseline)
        #expect(merged == PRBaseline(heaviestKg: 100, bestE1RM: 120, bestRepsByWeight: [60: 12, 70: 6, 100: 1],
                                     bestSessionVolume: 3000))

        // Built from phone history: last session's sets and the all-history baseline.
        let container = try makeModelContainer(inMemory: true)
        let ctx = container.mainContext
        try sessionBatch().merge(into: ctx, markForPush: true)
        let built = try #require(ExerciseSnapshot.make(from: try Queries.loggedSets(in: ctx)).first)
        #expect(built.exerciseID == bench)
        #expect(built.lastSets == [SnapshotSet(weightKg: 80, reps: 5), SnapshotSet(weightKg: 85, reps: 5)])
        #expect(built.lastDate == t0 + 60)
        #expect(built.baseline.heaviestKg == 85)
        #expect(built.baseline.bestSessionVolume == 825)
    }

    @Test func bodyWeightDedupe() throws {
        let sample = UUID()
        let imported = BodyWeightEntry(date: t0, weightKg: 80, healthKitSampleID: sample, source: .health, needsPush: false)
        let other = BodyWeightEntry(date: t0, weightKg: 81, healthKitSampleID: UUID(), source: .health, needsPush: false)
        let watch = BodyWeightEntryDTO(BodyWeightEntry(date: t0, weightKg: 80, healthKitSampleID: sample, source: .app,
                                                       createdAt: t0, updatedAt: t0))

        #expect(BodyWeightDedupe.apply(incoming: watch, to: [imported, other]).map(\.id) == [imported.id])
        #expect(imported.deletedAt != nil && imported.needsPush)
        #expect(other.deletedAt == nil && !other.needsPush)
        #expect(BodyWeightDedupe.apply(incoming: watch, to: [imported]).isEmpty)  // already deleted

        // Through merge: one live row left, with the watch's id.
        let container = try makeModelContainer(inMemory: true)
        let ctx = container.mainContext
        ctx.insert(BodyWeightEntry(date: t0, weightKg: 80, healthKitSampleID: sample, source: .health, needsPush: false))
        try ctx.save()
        try ConnectivityPayload(kind: .bodyWeight, bodyWeights: [watch]).merge(into: ctx, markForPush: true)
        try ctx.save()
        let live = try ctx.fetch(FetchDescriptor<BodyWeightEntry>(predicate: #Predicate { $0.deletedAt == nil }))
        #expect(live.map(\.id) == [watch.id])
        #expect(try count(BodyWeightEntry.self, ctx) == 2)
    }
}
