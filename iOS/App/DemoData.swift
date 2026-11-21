import Foundation
import SwiftData
import WorkoutCore

/// Launch arguments `-demoData` (charts demo) and `-uiTesting` (UI tests) run on an in-memory store seeded
/// with ~8 weeks of sessions. Real data is never touched, and rows are not marked for backup.
enum DemoData {
    static let isUITesting = ProcessInfo.processInfo.arguments.contains("-uiTesting")
    static let isEnabled = isUITesting || ProcessInfo.processInfo.arguments.contains("-demoData")

    /// (routine, [(exercise, start kg, kg added per week)]).
    private static let plan: [(String, [(String, Double, Double)])] = [
        ("Chest Day", [("Bench Press", 60, 2.5), ("Incline Dumbbell Press", 22, 1), ("Cable Fly", 15, 0.5), ("Triceps Pushdown", 25, 1)]),
        ("Back Day", [("Deadlift", 100, 5), ("Lat Pulldown", 50, 2.5), ("Barbell Row", 50, 2.5), ("Barbell Curl", 25, 1)]),
        ("Leg Day", [("Back Squat", 80, 2.5), ("Romanian Deadlift", 70, 2.5), ("Leg Press", 120, 5), ("Standing Calf Raise", 40, 2.5)]),
    ]

    static func seed(_ context: ModelContext) throws {
        let cal = Calendar.isoWeeks
        let thisWeek = cal.dateInterval(of: .weekOfYear, for: .now)!.start
        var routines: [Routine] = []
        for (r, (name, items)) in plan.enumerated() {
            let routine = Routine(name: name, sortOrder: r, needsPush: false)
            context.insert(routine)
            routines.append(routine)
            for (i, item) in items.enumerated() {
                context.insert(RoutineExercise(routineID: routine.id, exerciseID: Exercise.builtInID(for: item.0),
                                               sortOrder: i, targetSets: 4, targetReps: 8, needsPush: false))
            }
        }
        let treadmill = Exercise.builtInID(for: "Treadmill Run")

        for week in 0..<8 {
            let weekStart = cal.date(byAdding: .weekOfYear, value: week - 7, to: thisWeek)!
            // Mon / Wed / Fri at 18:00, skipping a session now and then.
            for (slot, dayOffset) in [0, 2, 4].enumerated() where (week * 3 + slot) % 7 != 5 {
                let start = cal.date(byAdding: .minute, value: dayOffset * 1440 + 18 * 60, to: weekStart)!
                guard start < .now else { continue }
                let (routine, items) = (routines[slot], plan[slot].1)
                let session = WorkoutSession(routineID: routine.id, startedAt: start, source: week % 2 == 0 ? .watch : .phone,
                                             activeCalories: 280 + Double(week * 6 + slot * 15),
                                             avgHeartRate: 112 + Double((week + slot) % 5) * 3, needsPush: false)
                context.insert(session)
                var t = start + 300
                for (i, (name, base, perWeek)) in items.enumerated() {
                    let entry = SessionExercise(sessionID: session.id, exerciseID: Exercise.builtInID(for: name),
                                                sortOrder: i, note: i == 0 && week == 5 ? "Felt strong today" : nil,
                                                needsPush: false)
                    context.insert(entry)
                    for s in 0..<4 {
                        t += 150
                        context.insert(SetEntry(sessionExerciseID: entry.id, sortOrder: s,
                                                weightKg: base + perWeek * Double(week), reps: [10, 8, 8, 6][s] - (week % 3 == 2 ? 1 : 0),
                                                restSeconds: s < 3 ? 90 + Double((s * 17 + week * 7) % 40) : nil,
                                                completedAt: t, needsPush: false))
                    }
                }
                if slot == 2 {
                    let entry = SessionExercise(sessionID: session.id, exerciseID: treadmill, sortOrder: items.count, needsPush: false)
                    context.insert(entry)
                    t += 900
                    context.insert(SetEntry(sessionExerciseID: entry.id, distanceMeters: 2000 + Double(week) * 100,
                                            durationSeconds: 780 - Double(week) * 10, completedAt: t, needsPush: false))
                }
                session.endedAt = t + 60
            }
        }
        try context.save()
    }
}
