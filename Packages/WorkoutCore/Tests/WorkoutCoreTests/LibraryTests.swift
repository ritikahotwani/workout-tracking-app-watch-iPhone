import SwiftData
import Testing
@testable import WorkoutCore

@Suite struct LibraryTests {
    @MainActor @Test func seedIsIdempotent() throws {
        let container = try makeModelContainer(inMemory: true)  // must outlive the context
        let ctx = container.mainContext
        try ExerciseLibrary.seedIfNeeded(ctx)
        let first = try ctx.fetch(FetchDescriptor<Exercise>())
        #expect(first.count == ExerciseLibrary.builtIns.count)
        #expect(first.allSatisfy { $0.isBuiltIn && !$0.needsPush && $0.id == Exercise.builtInID(for: $0.name) })

        try ExerciseLibrary.seedIfNeeded(ctx)
        #expect(try ctx.fetchCount(FetchDescriptor<Exercise>()) == first.count)
    }

    @Test func noDuplicateNameKeys() {
        let keys = ExerciseLibrary.builtIns.map { Exercise.nameKey(for: $0.name) }
        #expect(Set(keys).count == keys.count)
    }

    @Test func coverage() {
        let all = ExerciseLibrary.builtIns
        #expect(all.count >= 75)
        #expect(Set(all.map(\.muscleGroup)) == Set(MuscleGroup.allCases))
        for e in all {
            #expect((e.kind == .cardio) == (e.cardioActivity != nil), "\(e.name)")
        }
    }
}
