import Foundation
import SwiftData

public struct BuiltInExercise: Sendable {
    public let name: String
    public let muscleGroup: MuscleGroup
    public let kind: ExerciseKind
    public let cardioActivity: CardioActivity?
}

public enum ExerciseLibrary {
    public static let builtIns: [BuiltInExercise] =
        strength(.chest, [
            "Bench Press", "Incline Bench Press", "Decline Bench Press", "Dumbbell Bench Press",
            "Incline Dumbbell Press", "Dumbbell Fly", "Cable Fly", "Chest Press Machine", "Pec Deck", "Push-Up", "Chest Dip",
        ]) + strength(.back, [
            "Deadlift", "Pull-Up", "Chin-Up", "Lat Pulldown", "Barbell Row", "Dumbbell Row", "Seated Cable Row",
            "T-Bar Row", "Chest-Supported Row", "Straight-Arm Pulldown", "Back Extension",
        ]) + strength(.shoulders, [
            "Overhead Press", "Dumbbell Shoulder Press", "Arnold Press", "Lateral Raise", "Cable Lateral Raise",
            "Front Raise", "Rear Delt Fly", "Face Pull", "Upright Row", "Shrug",
        ]) + strength(.biceps, [
            "Barbell Curl", "Dumbbell Curl", "Hammer Curl", "Preacher Curl", "Incline Dumbbell Curl", "Cable Curl",
            "Concentration Curl",
        ]) + strength(.triceps, [
            "Triceps Pushdown", "Overhead Triceps Extension", "Skull Crusher", "Close-Grip Bench Press", "Triceps Dip",
            "Triceps Kickback",
        ]) + strength(.legs, [
            "Back Squat", "Front Squat", "Leg Press", "Hack Squat", "Romanian Deadlift", "Bulgarian Split Squat",
            "Walking Lunge", "Goblet Squat", "Leg Extension", "Lying Leg Curl", "Seated Leg Curl",
            "Standing Calf Raise", "Seated Calf Raise",
        ]) + strength(.glutes, [
            "Hip Thrust", "Glute Bridge", "Cable Kickback", "Hip Abduction Machine", "Sumo Deadlift", "Step-Up",
        ]) + strength(.core, [
            "Plank", "Crunch", "Cable Crunch", "Hanging Leg Raise", "Ab Wheel Rollout", "Russian Twist", "Side Plank",
            "Pallof Press",
        ]) + strength(.fullBody, [
            "Power Clean", "Clean and Jerk", "Snatch", "Kettlebell Swing", "Thruster", "Burpee", "Farmer's Carry",
        ]) + strength(.other, [
            "Wrist Curl", "Reverse Wrist Curl",
        ]) + [
            cardio("Treadmill Run", .running), cardio("Outdoor Run", .running), cardio("Walking", .walking),
            cardio("Outdoor Cycling", .cycling), cardio("Indoor Cycling", .cycling), cardio("Rowing Machine", .rowing),
            cardio("Elliptical", .elliptical), cardio("Stair Climber", .stairs), cardio("Jump Rope", .other),
        ]

    /// Inserts built-ins missing from the store (matched by deterministic ID). Idempotent; never resurrects
    /// or overwrites an existing row, so user edits (e.g. default rest) survive.
    public static func seedIfNeeded(_ context: ModelContext) throws {
        let existing = Set(try context.fetch(FetchDescriptor<Exercise>()).map(\.id))
        var inserted = false
        // Epoch timestamps: any user edit or server copy always wins LWW over a fresh seed.
        for b in builtIns {
            let id = Exercise.builtInID(for: b.name)
            guard !existing.contains(id) else { continue }
            context.insert(Exercise(id: id, name: b.name, muscleGroup: b.muscleGroup, kind: b.kind,
                                    cardioActivity: b.cardioActivity, isBuiltIn: true,
                                    createdAt: .init(timeIntervalSince1970: 0), updatedAt: .init(timeIntervalSince1970: 0), needsPush: false))
            inserted = true
        }
        if inserted { try context.save() }
    }

    private static func strength(_ group: MuscleGroup, _ names: [String]) -> [BuiltInExercise] {
        names.map { BuiltInExercise(name: $0, muscleGroup: group, kind: .strength, cardioActivity: nil) }
    }

    private static func cardio(_ name: String, _ activity: CardioActivity) -> BuiltInExercise {
        BuiltInExercise(name: name, muscleGroup: .cardio, kind: .cardio, cardioActivity: activity)
    }
}
