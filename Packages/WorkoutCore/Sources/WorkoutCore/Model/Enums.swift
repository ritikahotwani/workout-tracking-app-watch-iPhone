public enum ExerciseKind: String, Codable, CaseIterable, Sendable {
    case strength, cardio
}

public enum MuscleGroup: String, Codable, CaseIterable, Sendable {
    case chest, back, shoulders, biceps, triceps, legs, glutes, core, fullBody, cardio, other
}

public enum CardioActivity: String, Codable, CaseIterable, Sendable {
    case running, walking, cycling, rowing, elliptical, stairs, other
}

public enum SessionSource: String, Codable, CaseIterable, Sendable {
    case watch, phone, `import`
}

public enum WeightSource: String, Codable, CaseIterable, Sendable {
    case app, health, `import`
}
