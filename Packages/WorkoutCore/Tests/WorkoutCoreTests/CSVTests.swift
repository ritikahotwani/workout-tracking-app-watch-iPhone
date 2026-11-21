import Foundation
import SwiftData
import Testing
@testable import WorkoutCore

@Suite struct CSVTests {
    func fields(_ text: String) -> [[String]] { CSV.parse(text).map(\.fields) }

    @Test func plainRowsAndLineNumbers() {
        let rows = CSV.parse("a,b,c\n1,2,3\n\n4,,6\n")
        #expect(rows.map(\.fields) == [["a", "b", "c"], ["1", "2", "3"], ["4", "", "6"]])
        #expect(rows.map(\.line) == [1, 2, 4])  // blank line skipped but counted
    }

    @Test func quotedFields() {
        #expect(fields(#"x,"a, b","say ""hi""",""\#n"# + "\n") == [["x", "a, b", #"say "hi""#, ""]])
    }

    @Test func newlinesInsideQuotesKeepLineNumbers() {
        let rows = CSV.parse("h\r\n\"one\r\ntwo\nthree\"\r\nnext\r\n")
        #expect(rows.map(\.fields) == [["h"], ["one\r\ntwo\nthree"], ["next"]])
        #expect(rows.map(\.line) == [1, 2, 5])
    }

    @Test func crlfLfAndBareCR() {
        #expect(fields("a,b\r\nc,d\ne,f\rg,h") == [["a", "b"], ["c", "d"], ["e", "f"], ["g", "h"]])
    }

    @Test func bomAndNoTrailingNewline() {
        let rows = CSV.parse("\u{FEFF}Exercise,Date\nSquat,x")
        #expect(rows.first?.fields.first == "Exercise")
        #expect(rows.last?.fields == ["Squat", "x"])
    }

    @Test func trailingEmptyFieldAndLenientQuotes() {
        #expect(fields("a,\n") == [["a", ""]])
        #expect(fields("5\" plate,x\n") == [["5\" plate", "x"]])  // stray quote mid-field is text
        #expect(fields("\"open,never closed\n") == [["open,never closed\n"]])
    }

    @Test func writerQuotesOnlyWhenNeeded() {
        let out = CSV.write([["plain", "a,b", "say \"hi\"", "two\nlines", ""]])
        #expect(out == "plain,\"a,b\",\"say \"\"hi\"\"\",\"two\nlines\",\r\n")
        #expect(fields(out) == [["plain", "a,b", "say \"hi\"", "two\nlines", ""]])
    }

    @Test func writerParserRoundTrip() {
        let rows = [["h1", "h2"], ["é ✓", "\"\""], [",", "\r\n"], ["", "x"]]
        #expect(fields(CSV.write(rows)) == rows)
    }

    // MARK: Export

    @MainActor @Test func exportRoundTrip() throws {
        let container = try makeModelContainer(inMemory: true)
        let ctx = container.mainContext
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let bench = Exercise(name: "Bench Press", muscleGroup: .chest)
        let run = Exercise(name: "Outdoor Run", muscleGroup: .cardio, kind: .cardio, cardioActivity: .running)
        let routine = Routine(name: "Push, heavy")
        let s = WorkoutSession(routineID: routine.id, startedAt: t, endedAt: t + 3600, source: .watch, note: "good \"day\"")
        let gone = WorkoutSession(startedAt: t + 10, source: .phone, deletedAt: t)
        let e1 = SessionExercise(sessionID: s.id, exerciseID: bench.id, sortOrder: 0, note: "elbow, fine")
        let e2 = SessionExercise(sessionID: s.id, exerciseID: run.id, sortOrder: 1)
        let e3 = SessionExercise(sessionID: gone.id, exerciseID: bench.id)
        [bench, run].forEach(ctx.insert)
        ctx.insert(routine)
        [s, gone].forEach(ctx.insert)
        [e1, e2, e3].forEach(ctx.insert)
        ctx.insert(SetEntry(sessionExerciseID: e1.id, sortOrder: 1, weightKg: 82.5, reps: 5, completedAt: t + 200))
        ctx.insert(SetEntry(sessionExerciseID: e1.id, sortOrder: 0, weightKg: 80, reps: 5, restSeconds: 120, completedAt: t + 60))
        ctx.insert(SetEntry(sessionExerciseID: e1.id, sortOrder: 2, weightKg: 80, reps: 5, completedAt: t, deletedAt: t))
        ctx.insert(SetEntry(sessionExerciseID: e2.id, distanceMeters: 5000, durationSeconds: 1500.5, completedAt: t + 3600))
        ctx.insert(SetEntry(sessionExerciseID: e3.id, weightKg: 1, reps: 1, completedAt: t))
        ctx.insert(BodyWeightEntry(date: t, weightKg: 75.4, source: .health))
        ctx.insert(BodyWeightEntry(date: t, weightKg: 99, deletedAt: t))

        let rows = CSV.parse(try CSVExport.workouts(in: ctx)).map(\.fields)
        #expect(rows.first == CSVExport.workoutColumns)
        #expect(rows.count == 4)
        let col = { (row: [String], name: String) in row[CSVExport.workoutColumns.firstIndex(of: name)!] }
        #expect(rows[1] == [t.addingTimeInterval(60).formatted(.iso8601), s.id.uuidString, "Push, heavy", "Bench Press",
                            "chest", "strength", "1", "80", "5", "", "", "120", "elbow, fine", "good \"day\""])
        #expect(col(rows[2], "weight_kg") == "82.5" && col(rows[2], "set_number") == "2")
        #expect(col(rows[3], "exercise") == "Outdoor Run" && col(rows[3], "kind") == "cardio")
        #expect(col(rows[3], "distance_m") == "5000" && col(rows[3], "duration_s") == "1500.5" && col(rows[3], "reps") == "")
        let parsedDate = try Date(col(rows[1], "date"), strategy: .iso8601)
        #expect(parsedDate == t + 60)

        let weights = CSV.parse(try CSVExport.bodyWeights(in: ctx)).map(\.fields)
        #expect(weights == [["date", "weight_kg", "source"], [t.formatted(.iso8601), "75.4", "health"]])
    }
}
