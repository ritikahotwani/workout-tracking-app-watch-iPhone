import Foundation
import SwiftData
import Testing
@testable import WorkoutCore

@MainActor @Suite struct HistoryQueriesTests {
    let container: ModelContainer
    var ctx: ModelContext { container.mainContext }
    let bench = UUID(), row = UUID()
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws { container = try makeModelContainer(inMemory: true) }

    /// Session with one entry per exercise; each set is (exercise, kg, reps); reps nil = cardio.
    @discardableResult
    func session(day: Double, ended: Bool = true, deleted: Bool = false, sets: [(UUID, Double?, Int?)]) -> WorkoutSession {
        let start = t0 + day * 86_400
        let s = WorkoutSession(startedAt: start, endedAt: ended ? start + 3600 : nil, source: .phone,
                               deletedAt: deleted ? start : nil)
        ctx.insert(s)
        var entries: [UUID: SessionExercise] = [:]
        for (i, (ex, kg, reps)) in sets.enumerated() {
            let e = entries[ex] ?? SessionExercise(sessionID: s.id, exerciseID: ex)
            if entries[ex] == nil { ctx.insert(e); entries[ex] = e }
            ctx.insert(SetEntry(sessionExerciseID: e.id, sortOrder: i, weightKg: kg, reps: reps,
                                distanceMeters: reps == nil ? 1000 : nil, completedAt: start + Double(i)))
        }
        return s
    }

    @Test func loggedSetsOnlyEndedNonDeletedOldestFirst() throws {
        session(day: 2, sets: [(bench, 80, 8), (row, nil, nil)])
        session(day: 1, sets: [(bench, 70, 10)])
        session(day: 3, ended: false, sets: [(bench, 200, 1)])
        session(day: 4, deleted: true, sets: [(bench, 300, 1)])
        let all = try Queries.loggedSets(in: ctx)
        #expect(all.map(\.set.weightKg) == [70, 80, nil])
        #expect(all.compactMap(\.record).map(\.reps) == [10, 8])
        #expect(all.last?.exerciseID == row && all.last?.record == nil)
    }

    @Test func deleteSessionCascades() throws {
        let s = session(day: 1, sets: [(bench, 80, 8), (row, 50, 10)])
        let keep = session(day: 2, sets: [(bench, 90, 5)])
        try Queries.deleteSession(s, in: ctx)
        #expect(s.deletedAt != nil && s.needsPush)
        let deletedEntries = try ctx.fetch(FetchDescriptor<SessionExercise>()).filter { $0.deletedAt != nil }
        #expect(deletedEntries.count == 2 && deletedEntries.allSatisfy { $0.sessionID == s.id })
        #expect(try ctx.fetch(FetchDescriptor<SetEntry>()).count { $0.deletedAt != nil } == 2)
        #expect(try Queries.loggedSets(in: ctx).map(\.sessionID) == [keep.id])
    }
}
