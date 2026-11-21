import Foundation
import SwiftData
import Testing
@testable import WorkoutCore

private func set(_ name: String, _ date: String, reps: String = "10.0", kg: String = "50.0", lb: String = "",
                note: String = "") -> String {
    [name, date, reps, lb, kg, "", "", note, ""].map(CSV.escape).joined(separator: ",")
}

private func session(_ type: String, _ start: String, _ end: String, duration: String = "", kcal: String = "",
                    meters: String = "", location: String = "", notes: String = "") -> String {
    [type, start, end, duration, "", kcal, meters, "Setgraph", location, notes, ""].map(CSV.escape).joined(separator: ",")
}

/// Synthetic fixtures in SetGraph's export format (never real data).
@Suite struct SetGraphImportTests {
    static let setsHeader = "Exercise,Date,Repetitions,Weight (lb),Weight (kg),Duration (seconds),Duration (formatted),Note,Label"
    static let sessionsHeader = "Activity Type,Start Date,End Date,Duration (seconds),Duration (formatted),Calories (kcal),Distance (meters),Source,Location,Notes,Custom Metadata"
    let utc = TimeZone(identifier: "UTC")!

    static func sets(_ rows: String...) -> String { "\u{FEFF}" + ([setsHeader] + rows).joined(separator: "\r\n") + "\r\n" }
    static func sessions(_ rows: String...) -> String { "\u{FEFF}" + ([sessionsHeader] + rows).joined(separator: "\n") }

    func plan(_ sets: String, _ sessions: String? = nil, existing: SetGraphImport.Existing = .init()) -> ImportPlan {
        SetGraphImport.plan(setsCSV: sets, sessionsCSV: sessions, existing: existing, timeZone: utc)
    }

    func exerciseName(_ p: ImportPlan, entry: SessionExerciseDTO) -> String? {
        p.exercisesCreated.first { $0.id == entry.exerciseID }?.name
    }

    // MARK: Fixture with every case at once

    static let fixtureSets = sets(
        set("Squats", "2025-10-06 10:05:00", note: "knee, \"ok\""),                    // 2  alias → Back Squat
        set("Squats", "2025-10-06 10:05:00", note: "knee, \"ok\""),                    // 3  duplicate
        set("Squats", "2025-10-06 10:07:00", note: "knee, \"ok\""),                    // 4  same note, deduped
        set("Bench Press", "2025-10-06 10:31:00", reps: "8.0", kg: "0"),              // 5  in Walking overlap → strength
        set("Plank", "2025-10-06 10:50:00", reps: "1.0", kg: ""),                     // 6  empty weight
        set("Abductor", "2025-10-06 20:00:00", reps: "12.0", kg: "", lb: "100"),     // 7  outside any session, lb fallback
        set("Abductor", "2025-10-06 20:10:00"),                                         // 8
        set("Bench Press", "2025-10-06 abc", reps: "5.0"),                             // 9  bad date
        set("Bench Press", "2025-10-06 20:15:00", reps: "five"),                       // 10 bad reps
        set("", "2025-10-06 20:16:00"),                                                 // 11 missing name
        set("Bench Press", "2025-10-06 20:17:00", reps: "7.5"),                        // 12 fractional reps
        "Bench Press,2025-10-06 20:18:00,10.0,,50.0,,,,,extra",                        // 13 too many fields
        set("Hanging Knee Raise", "2025-10-07 08:10:00", reps: "15.0", kg: "0"))      // 14 inside a cardio session

    static let fixtureSessions = sessions(
        session("Strength Training", "2025-10-06 10:00:00", "2025-10-06 11:00:00", duration: "3000",
                notes: "Felt good, \"strong\""),                                                      // 2
        session("Walking", "2025-10-06 10:30:00", "2025-10-06 10:45:00", duration: "900", kcal: "50", meters: "1200"), // 3
        session("Cycling", "2025-10-07 08:00:00", "2025-10-07 08:30:00", duration: "1800", location: "Outdoor"), // 4
        session("Strength Training", "2025-10-06 10:00:00", "2025-10-06 11:00:00", duration: "3000"),  // 5 duplicate
        session("Strength Training", "2025-10-08 10:00:00", "2025-10-08 09:00:00"),                    // 6 end before start
        session("Yoga", "2025-10-09 07:00:00", "2025-10-09 07:20:00", duration: "1200"))              // 7

    @Test func fixtureSummary() {
        let p = plan(Self.fixtureSets, Self.fixtureSessions)
        #expect(p.sessionsByType == ["Strength Training": 1, "Walking": 1, "Cycling": 1, "Yoga": 1, "Synthetic": 1])
        #expect(p.strengthSessions == 1 && p.cardioSessions == 3 && p.syntheticSessions == 1)
        #expect(p.sets.count == 7 + 3)  // 7 strength + 3 cardio
        #expect(p.duplicates == [.init(file: .sessions, line: 5, reason: "duplicate row, skipped"),
                                 .init(file: .sets, line: 3, reason: "duplicate row, skipped")])
        #expect(p.errors.map { "\($0.file.rawValue):\($0.line)" } == ["sessions:6", "sets:9", "sets:10", "sets:11", "sets:12", "sets:13"])
        #expect(p.errors.first { $0.line == 6 }?.reason == "end before start")
        #expect(p.errors.first { $0.line == 13 }?.reason == "expected 9 fields, found 10")
        #expect(p.aliasMerges == [.init(from: "Squats", to: "Back Squat", rows: 2)])
        #expect(p.alreadyImported == 0)

        let strength = p.sessions.first { $0.importKey == "setgraph:session:Strength Training|2025-10-06 10:00:00" }!
        #expect(strength.note == "Felt good, \"strong\"" && strength.pausedSeconds == 600 && strength.source == "import")
        let squatEntry = p.sessionExercises.first { $0.sessionID == strength.id && $0.sortOrder == 0 }!
        #expect(exerciseName(p, entry: squatEntry) == "Back Squat")
        #expect(squatEntry.note == "knee, \"ok\"")
        #expect(p.sessionExercises.filter { $0.sessionID == strength.id }.count == 3)  // Squat, Bench, Plank
    }

    @Test func weightsEmptyZeroAndPounds() {
        let p = plan(Self.fixtureSets, Self.fixtureSessions)
        let byKey = Dictionary(uniqueKeysWithValues: p.sets.compactMap { s in s.importKey.map { ($0, s) } })
        #expect(byKey["setgraph:set:bench press|2025-10-06 10:31:00|8.0|0|0"]?.weightKg == 0)
        #expect(byKey["setgraph:set:plank|2025-10-06 10:50:00|1.0||0"]?.weightKg == nil)
        let lb = byKey["setgraph:set:abductor|2025-10-06 20:00:00|12.0||0"]!
        #expect(abs(lb.weightKg! - 45.359237) < 1e-9 && lb.reps == 12)
    }

    // MARK: Exercise matching

    @Test func aliasMergeAndExistingMatch() {
        let deadlift = UUID()
        let p = plan(Self.sets(
            set("Dead Lift", "2025-10-06 10:00:00"), set("Deadlift ", "2025-10-06 10:02:00"),
            set("Hammer Curls", "2025-10-06 10:04:00"), set("Dumbbell Hammer Curl", "2025-10-06 10:06:00"),
            set("Seated Incline Db Curl", "2025-10-06 10:08:00"), set("Side Lateral Raises", "2025-10-06 10:10:00"),
            set("DB Side Lateral Raises", "2025-10-06 10:12:00")),
            existing: .init(exercises: ["deadlift": deadlift]))
        #expect(p.exercisesMatched == 1)
        #expect(p.exercisesCreated.map(\.name).sorted() == ["DB Side Lateral Raise", "Hammer Curl", "Incline Dumbbell Curl", "Side Lateral Raises"])
        #expect(p.sessionExercises.filter { $0.exerciseID == deadlift }.count == 1)  // both spellings in one entry
        #expect(p.aliasMerges.map(\.from) == ["DB Side Lateral Raises", "Dead Lift", "Dumbbell Hammer Curl", "Hammer Curls", "Seated Incline Db Curl"])
    }

    @Test(arguments: [
        ("Abs - Crunches", MuscleGroup.core), ("Machine ab", .core), ("Seated Leg Press", .legs), ("Abductor", .legs),
        ("Glutes hip thrust", .glutes), ("Cable Lat Pullover (bar)", .back), ("Scapula pullups", .back),
        ("Flat Bench Press", .chest), ("Pec deck flies", .chest), ("Db Front Raises", .shoulders),
        ("Rear Deltoid Machine (Ped Dec)", .shoulders), ("Mts Arm Extension", .triceps), ("Tricep Push Down", .triceps),
        ("Bicep Curls", .biceps), ("Leg Curl", .legs), ("Farmer Walk", .other), ("Assist Pull-Ups", .back),
        // First match wins: these keywords sit in an earlier group than the mapping's later entry.
        ("Reverse Pec Deck", .chest),
    ])
    func keywordGroups(name: String, group: MuscleGroup) {
        #expect(SetGraphImport.muscleGroup(forNameKey: Exercise.nameKey(for: name)) == group)
    }

    @Test func createdStrengthExerciseGetsKeywordGroup() {
        let p = plan(Self.sets(set("Wide Grip Lat Pull Down", "2025-10-06 10:00:00")))
        let e = p.exercisesCreated[0]
        #expect(e.name == "Wide Grip Lat Pull Down" && e.muscleGroup == "back" && e.kind == "strength" && !e.isBuiltIn)
    }

    // MARK: Sessions

    @Test func overlappingSessionsPreferStrengthThenShortest() {
        let p = plan(Self.sets(set("Row", "2025-10-06 10:20:00"), set("Row", "2025-10-06 12:10:00")), Self.sessions(
            session("Walking", "2025-10-06 10:10:00", "2025-10-06 10:30:00"),
            session("Strength Training", "2025-10-06 10:00:00", "2025-10-06 11:00:00"),
            session("Cycling", "2025-10-06 12:00:00", "2025-10-06 13:00:00"),
            session("Elliptical", "2025-10-06 12:05:00", "2025-10-06 12:20:00")))
        func owner(_ setDate: String) -> String? {
            let set = p.sets.first { $0.importKey?.contains(setDate) == true }!
            let entry = p.sessionExercises.first { $0.id == set.sessionExerciseID }!
            return p.sessions.first { $0.id == entry.sessionID }?.importKey
        }
        #expect(owner("10:20:00") == "setgraph:session:Strength Training|2025-10-06 10:00:00")
        #expect(owner("12:10:00") == "setgraph:session:Elliptical|2025-10-06 12:05:00")
    }

    @Test func syntheticGroupingSplitsOnGapAndDay() {
        let p = plan(Self.sets(
            set("Row", "2025-10-06 18:00:00"), set("Row", "2025-10-06 19:30:00"),   // 90 min: same group
            set("Row", "2025-10-06 21:01:00"),                                       // 91 min: new group
            set("Row", "2025-10-06 23:50:00"), set("Row", "2025-10-07 00:10:00")))   // 20 min but new day
        #expect(p.syntheticSessions == 4 && p.sessions.count == 4)
        let first = p.sessions.min { $0.startedAt < $1.startedAt }!
        #expect(first.importKey == "setgraph:session:synthetic|2025-10-06 18:00:00")
        #expect(first.startedAt == p.sets[0].completedAt - 60 && first.endedAt == p.sets[1].completedAt)
        #expect(first.note == nil && first.activeCalories == nil)
    }

    @Test func restEstimateAndOrdering() {
        let p = plan(Self.sets(
            set("Curl", "2025-10-06 10:00:00"), set("Row", "2025-10-06 10:01:30"),
            set("Curl", "2025-10-06 10:11:30"), set("Curl", "2025-10-06 10:11:30", reps: "9.0"),
            set("Row", "2025-10-06 10:13:00")))
        let rests = p.sets.map(\.restSeconds)  // emitted in time order
        #expect(rests == [90, 600, nil, 90, nil])  // 600 kept, 0 s gap and last set → nil
        let curl = p.sessionExercises.first { exerciseName(p, entry: $0) == "Curl" }!
        let row = p.sessionExercises.first { exerciseName(p, entry: $0) == "Row" }!
        #expect(curl.sortOrder == 0 && row.sortOrder == 1)
        #expect(p.sets.filter { $0.sessionExerciseID == curl.id }.map(\.sortOrder) == [0, 1, 2])
        let gapOver = plan(Self.sets(set("Curl", "2025-10-06 10:00:00"), set("Curl", "2025-10-06 10:10:01")))
        #expect(gapOver.sets.map(\.restSeconds) == [nil, nil])
    }

    @Test func cardioSessionBecomesCardioSet() {
        let walking = UUID()
        let p = plan(Self.sets(set("Plank", "2025-10-06 07:10:00", reps: "1.0", kg: "")), Self.sessions(
            session("Walking", "2025-10-06 07:00:00", "2025-10-06 07:40:00", duration: "2100", kcal: "180.5", meters: "3200.5")),
            existing: .init(exercises: ["walking": walking]))
        let s = p.sessions[0]
        #expect(s.activeCalories == 180.5 && s.pausedSeconds == 300 && s.endedAt == s.startedAt + 2400)
        let entries = p.sessionExercises.sorted { $0.sortOrder < $1.sortOrder }
        #expect(entries.map(\.exerciseID).first == walking && entries.count == 2)  // cardio first, then the extra set
        let cardio = p.sets.first { $0.sessionExerciseID == entries[0].id }!
        #expect(cardio.durationSeconds == 2100 && cardio.distanceMeters == 3200.5 && cardio.reps == nil)
        #expect(cardio.importKey == "setgraph:cardio:setgraph:session:Walking|2025-10-06 07:00:00")
        #expect(p.exercisesMatched == 1 && p.cardioSessions == 1)
    }

    @Test func locationPicksCardioExercise() {
        let p = plan(Self.sets(), Self.sessions(
            session("Cycling", "2025-10-06 07:00:00", "2025-10-06 07:30:00", location: "Outdoor"),
            session("Cycling", "2025-10-07 07:00:00", "2025-10-07 07:30:00", location: "Indoor"),
            session("Running", "2025-10-08 07:00:00", "2025-10-08 07:30:00", location: "Outdoor"),
            session("Running", "2025-10-09 07:00:00", "2025-10-09 07:30:00"),
            session("Stair Climbing", "2025-10-10 07:00:00", "2025-10-10 07:30:00"),
            session("Mixed Cardio", "2025-10-11 07:00:00", "2025-10-11 07:30:00"),
            session("Rowing", "2025-10-12 07:00:00", "2025-10-12 07:30:00")))
        let created = p.exercisesCreated.map { "\($0.name)/\($0.cardioActivity ?? "")/\($0.kind)/\($0.muscleGroup)" }
        #expect(created == ["Outdoor Cycling/cycling/cardio/cardio", "Indoor Cycling/cycling/cardio/cardio",
                            "Outdoor Run/running/cardio/cardio", "Treadmill Run/running/cardio/cardio",
                            "Stair Climber/stairs/cardio/cardio", "Mixed Cardio/other/cardio/cardio",
                            "Rowing/other/cardio/cardio"])
        // Missing duration → span.
        #expect(p.sets.allSatisfy { $0.durationSeconds == 1800 })
    }

    @Test func setsFileAloneUsesSyntheticSessions() {
        let p = plan(Self.fixtureSets)
        #expect(p.sessions.allSatisfy { $0.importKey!.hasPrefix("setgraph:session:synthetic|") })
        #expect(p.sets.count == 7 && p.syntheticSessions == 3)
    }

    @Test func missingColumnAndEmptyFile() {
        let p = plan("Exercise,Date\nSquat,2025-10-06 10:00:00\n", "")
        #expect(p.errors.map(\.line) == [1, 1])
        #expect(p.errors.contains { $0.file == .sets && $0.reason.hasPrefix("missing column Repetitions") })
        #expect(p.isEmpty)
    }

    @Test func detectsFileKind() {
        #expect(SetGraphImport.detect(Self.sets()) == .sets)
        #expect(SetGraphImport.detect(Self.sessions()) == .sessions)
        #expect(SetGraphImport.detect("a,b\n1,2") == nil)
    }

    // MARK: Commit + idempotency

    @MainActor @Test func commitThenReimportAddsNothing() throws {
        let container = try makeModelContainer(inMemory: true)
        let ctx = container.mainContext
        try ExerciseLibrary.seedIfNeeded(ctx)
        let first = SetGraphImport.plan(setsCSV: Self.fixtureSets, sessionsCSV: Self.fixtureSessions,
                                        existing: try .init(context: ctx), timeZone: utc)
        #expect(first.exercisesMatched == 5)  // Back Squat, Bench Press, Plank, Walking, Outdoor Cycling
        try first.commit(into: ctx)

        #expect(try ctx.fetchCount(FetchDescriptor<WorkoutSession>()) == first.sessions.count)
        #expect(try ctx.fetchCount(FetchDescriptor<SetEntry>()) == first.sets.count)
        #expect(try ctx.fetch(FetchDescriptor<SetEntry>()).allSatisfy(\.needsPush))
        #expect(try ctx.fetch(FetchDescriptor<WorkoutSession>()).allSatisfy { $0.needsPush && $0.source == .import })
        #expect(try ctx.fetch(FetchDescriptor<Exercise>(predicate: #Predicate { !$0.isBuiltIn })).allSatisfy(\.needsPush))
        #expect(try Queries.loggedSets(in: ctx).count == first.sets.count)  // feeds history/stats

        let again = SetGraphImport.plan(setsCSV: Self.fixtureSets, sessionsCSV: Self.fixtureSessions,
                                        existing: try .init(context: ctx), timeZone: utc)
        #expect(again.isEmpty && again.sessionExercises.isEmpty)
        #expect(again.alreadyImported == first.sessions.count + first.sets.count)
        #expect(again.errors == first.errors)  // bad rows are still reported, not swallowed

        // A soft-deleted session is no longer "already imported".
        let s = try ctx.fetch(FetchDescriptor<WorkoutSession>()).first { $0.importKey!.contains("Yoga") }!
        try Queries.deleteSession(s, in: ctx)
        let afterDelete = SetGraphImport.plan(setsCSV: Self.fixtureSets, sessionsCSV: Self.fixtureSessions,
                                              existing: try .init(context: ctx), timeZone: utc)
        #expect(afterDelete.sessions.count == 1 && afterDelete.sets.count == 1)
    }

    @Test func newSetInAlreadyImportedSessionIsReported() {
        let existing = SetGraphImport.Existing(importKeys: ["setgraph:session:synthetic|2025-10-06 10:00:00"])
        let p = plan(Self.sets(set("Row", "2025-10-06 10:00:00"), set("Row", "2025-10-06 10:05:00")), existing: existing)
        #expect(p.isEmpty && p.alreadyImported == 1)
        #expect(p.errors.map(\.line) == [2, 3])
    }

    @MainActor @Test func aliasesPointAtBuiltIns() throws {
        let container = try makeModelContainer(inMemory: true)
        let ctx = container.mainContext
        try ExerciseLibrary.seedIfNeeded(ctx)
        let names = ["Squats", "Squat", "Tricep Push Down", "Tricep Pushdown", "Chest Press", "Seated Incline DB Curl",
                     "Seated Inclined DB Curls", "Shrugs", "Lateral Raises", "Bicep Curls", "Leg Curl"]
        let p = SetGraphImport.plan(
            setsCSV: ([Self.setsHeader] + names.enumerated().map { set($1, "2025-10-06 10:\(String(format: "%02d", $0)):00") })
                .joined(separator: "\n"),
            sessionsCSV: nil, existing: try .init(context: ctx), timeZone: utc)
        let builtIns = ["Back Squat", "Triceps Pushdown", "Chest Press Machine", "Incline Dumbbell Curl"]
        #expect(Set(p.sessionExercises.map(\.exerciseID)).isSuperset(of: builtIns.map(Exercise.builtInID(for:))))
        #expect(p.exercisesMatched == 4)
        #expect(p.exercisesCreated.map(\.name).sorted() == ["Bicep Curls", "Lateral Raises", "Leg Curl", "Shrugs"])
    }

    @MainActor @Test func setsAloneThenWithSessionsAddsNoEmptySessions() throws {
        let container = try makeModelContainer(inMemory: true)
        let ctx = container.mainContext
        let sets = Self.sets(set("Row", "2025-10-06 10:05:00"), set("Row", "2025-10-06 10:10:00"))
        let sessions = Self.sessions(
            session("Strength Training", "2025-10-06 10:00:00", "2025-10-06 11:00:00", duration: "3600"),
            session("Strength Training", "2025-10-07 10:00:00", "2025-10-07 11:00:00", duration: "3600"))  // no sets
        try SetGraphImport.plan(setsCSV: sets, sessionsCSV: nil, existing: try .init(context: ctx), timeZone: utc)
            .commit(into: ctx)

        let p = SetGraphImport.plan(setsCSV: sets, sessionsCSV: sessions, existing: try .init(context: ctx), timeZone: utc)

        // The 10-06 session's sets are already in (synthetic); only the genuinely empty 10-07 session is new.
        #expect(p.sessions.map(\.importKey) == ["setgraph:session:Strength Training|2025-10-07 10:00:00"])
        #expect(p.sets.isEmpty && p.sessionExercises.isEmpty)
        #expect(p.alreadyImported == 2 + 1)  // two sets + the skipped session
    }
}
