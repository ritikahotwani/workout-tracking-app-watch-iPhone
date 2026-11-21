import Foundation
import SwiftData
import Testing
@testable import WorkoutCore

@MainActor @Suite struct QueriesTests {
    let container: ModelContainer
    var ctx: ModelContext { container.mainContext }
    let bench = Exercise(name: "Bench Press")
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws {
        container = try makeModelContainer(inMemory: true)
        container.mainContext.insert(bench)
    }

    /// Inserts a session with one bench entry and the given (kg, reps) sets.
    @discardableResult
    func session(daysAgo: Double, ended: Bool = true, deleted: Bool = false, sets: [(Double, Int)]) -> WorkoutSession {
        let start = t0 - daysAgo * 86_400
        let s = WorkoutSession(startedAt: start, endedAt: ended ? start + 3600 : nil, source: .watch,
                               deletedAt: deleted ? start : nil)
        let e = SessionExercise(sessionID: s.id, exerciseID: bench.id)
        ctx.insert(s)
        ctx.insert(e)
        for (i, (kg, reps)) in sets.enumerated() {
            ctx.insert(SetEntry(sessionExerciseID: e.id, sortOrder: i, weightKg: kg, reps: reps, completedAt: start))
        }
        return s
    }

    @Test func lastPerformancePicksMostRecentEndedNonDeletedWithSets() throws {
        session(daysAgo: 10, sets: [(60, 10)])
        session(daysAgo: 5, sets: [(80, 8), (80, 6)])
        session(daysAgo: 3, deleted: true, sets: [(100, 1)])
        session(daysAgo: 2, sets: [])                 // contains the exercise but no sets
        let live = session(daysAgo: 0, ended: false, sets: [(90, 5)])
        let last = try Queries.lastPerformance(exerciseID: bench.id, excludingSession: live.id, in: ctx)
        #expect(last.map(\.reps) == [8, 6])
        #expect(last.map(\.weightKg) == [80, 80])
    }

    @Test func lastPerformanceEmptyAndExcluded() throws {
        #expect(try Queries.lastPerformance(exerciseID: bench.id, excludingSession: nil, in: ctx).isEmpty)
        let s = session(daysAgo: 1, sets: [(50, 5)])
        #expect(try Queries.lastPerformance(exerciseID: bench.id, excludingSession: s.id, in: ctx).isEmpty)
    }

    @Test func deletedSetsAreSkipped() throws {
        session(daysAgo: 1, sets: [(50, 5), (55, 5)])
        try ctx.fetch(FetchDescriptor<SetEntry>()).first { $0.weightKg == 55 }!.markDeleted()
        #expect(try Queries.lastPerformance(exerciseID: bench.id, excludingSession: nil, in: ctx).count == 1)
    }

    @Test func prBaselineExcludesLiveAndDeletedSessions() throws {
        session(daysAgo: 5, sets: [(80, 8), (100, 1)])
        session(daysAgo: 3, deleted: true, sets: [(200, 1)])
        let live = session(daysAgo: 0, ended: false, sets: [(150, 1)])
        let b = try Queries.prBaseline(exerciseID: bench.id, excludingSession: live.id, in: ctx)
        #expect(b.heaviestKg == 100)
        #expect(b.bestRepsByWeight[80] == 8)
        #expect(b.bestSessionVolume == 740)
        #expect(try Queries.setRecords(exerciseID: bench.id, in: ctx).count == 3)
    }

    @Test func routineExercisesOrderedAndFiltered() throws {
        let squat = Exercise(name: "Squat")
        let gone = Exercise(name: "Gone", deletedAt: t0)
        let r = Routine(name: "Day")
        [squat, gone].forEach(ctx.insert)
        ctx.insert(r)
        ctx.insert(RoutineExercise(routineID: r.id, exerciseID: squat.id, sortOrder: 2))
        ctx.insert(RoutineExercise(routineID: r.id, exerciseID: bench.id, sortOrder: 1))
        ctx.insert(RoutineExercise(routineID: r.id, exerciseID: gone.id, sortOrder: 0))
        ctx.insert(RoutineExercise(routineID: r.id, exerciseID: bench.id, sortOrder: 3, deletedAt: t0))
        ctx.insert(RoutineExercise(routineID: UUID(), exerciseID: bench.id))
        let names = try Queries.routineExercises(routineID: r.id, in: ctx).map(\.exercise.name)
        #expect(names == ["Bench Press", "Squat"])
    }
}
