import Foundation
import SwiftData

/// SetGraph CSV → value rows, exactly as `docs/setgraph-mapping.md`. Pure: `plan` never touches a store.
public enum SetGraphImport {
    public enum File: String, Sendable { case sets, sessions }

    /// One reported row: an error or a skipped duplicate.
    public struct Issue: Sendable, Equatable {
        public let file: File
        public let line: Int
        public let reason: String
    }

    public struct AliasMerge: Sendable, Equatable {
        /// Name as written in the file (trimmed).
        public let from: String
        public let to: String
        public let rows: Int
    }

    /// What is already in the store: non-deleted exercises by `nameKey` and non-deleted import keys.
    public struct Existing: Sendable {
        public var exercises: [String: UUID]
        public var importKeys: Set<String>

        public init(exercises: [String: UUID] = [:], importKeys: Set<String> = []) {
            self.exercises = exercises
            self.importKeys = importKeys
        }

        public init(context: ModelContext) throws {
            let ex = try context.fetch(FetchDescriptor<Exercise>(predicate: #Predicate { $0.deletedAt == nil }))
            exercises = Dictionary(ex.map { ($0.nameKey, $0.id) }, uniquingKeysWith: { a, _ in a })
            let sessions = try context.fetch(FetchDescriptor<WorkoutSession>(
                predicate: #Predicate { $0.deletedAt == nil && $0.importKey != nil }))
            let sets = try context.fetch(FetchDescriptor<SetEntry>(
                predicate: #Predicate { $0.deletedAt == nil && $0.importKey != nil }))
            importKeys = Set(sessions.compactMap(\.importKey) + sets.compactMap(\.importKey))
        }
    }

    static let setsHeader = ["Exercise", "Date", "Repetitions", "Weight (lb)", "Weight (kg)", "Duration (seconds)", "Note"]
    static let sessionsHeader = ["Activity Type", "Start Date", "End Date", "Duration (seconds)", "Calories (kcal)",
                                 "Distance (meters)", "Location", "Notes"]
    static let strengthTypes: Set<String> = ["Strength Training", "Functional Strength Training", "Core Training"]
    static let syntheticType = "Synthetic"

    /// Approved merges: source nameKey → display name of the target (some are built-ins, spelled exactly).
    static let aliases: [String: String] = [
        "dumbell shrugs": "Dumbbell Shrugs",
        "squats": "Back Squat", "squat": "Back Squat",
        "dead lift": "Deadlift",
        "tricep push down": "Triceps Pushdown", "tricep pushdown": "Triceps Pushdown",
        "chest press": "Chest Press Machine",
        "leg extentions": "Leg Extension",
        "barbell shrugs": "Barbell Shrug",
        "seated incline db curl": "Incline Dumbbell Curl", "seated inclined db curls": "Incline Dumbbell Curl",
        "hammer curls": "Hammer Curl", "dumbbell hammer curl": "Hammer Curl",
        "dumbell side laterals": "DB Side Lateral Raise", "db side lateral raises": "DB Side Lateral Raise",
    ]
    /// Alias targets by nameKey, so a target spelled differently in the file still gets the approved name.
    static let aliasTargets = Dictionary(aliases.values.map { (Exercise.nameKey(for: $0), $0) }, uniquingKeysWith: { a, _ in a })

    /// First match wins. A keyword must start at a word start (so "lat " doesn't hit "flat bench"); punctuation
    /// counts as a space and the name is padded with one, so "ab " and "lat " also hit a final word.
    static let muscleRules: [(MuscleGroup, [String])] = [
        (.core, ["crunch", "plank", "knee raise", "abs", "ab "]),
        (.legs, ["squat", "leg press", "leg extension", "leg curl", "lunge", "calf", "hack", "adduct", "abduct"]),
        (.glutes, ["hip thrust", "glute"]),
        (.back, ["row", "lat ", "pulldown", "pull down", "pullover", "pull up", "pullup", "deadlift", "shrug", "scapula"]),
        (.chest, ["bench", "chest press", "pec", "fly", "flies", "incline press", "dumbbell press"]),
        (.shoulders, ["lateral", "front raise", "overhead press", "shoulder press", "face pull", "rear delt", "reverse pec"]),
        (.triceps, ["tricep", "triceps", "pushdown", "push down", "arm extension"]),
        (.biceps, ["curl"]),
    ]

    static func muscleGroup(forNameKey key: String) -> MuscleGroup {
        let words = " " + key.map { $0.isLetter || $0.isNumber ? $0 : " " }.split(separator: " ").joined(separator: " ") + " "
        return muscleRules.first { $0.1.contains { words.contains(" " + $0) } }?.0 ?? .other
    }

    static func cardioExercise(type: String, location: String) -> (name: String, activity: CardioActivity) {
        let outdoor = location == "Outdoor"
        switch type {
        case "Walking": return ("Walking", .walking)
        case "Cycling": return (outdoor ? "Outdoor Cycling" : "Indoor Cycling", .cycling)
        case "Elliptical": return ("Elliptical", .elliptical)
        case "Stair Climbing": return ("Stair Climber", .stairs)
        case "Running": return (outdoor ? "Outdoor Run" : "Treadmill Run", .running)
        default: return (type, .other)  // incl. Mixed Cardio, Yoga
        }
    }

    /// Which SetGraph file this is, from its header.
    public static func detect(_ csv: String) -> File? {
        guard let header = CSV.parse(String(csv.prefix(2000))).first?.fields else { return nil }
        if Set(setsHeader).isSubset(of: header) { return .sets }
        if Set(sessionsHeader).isSubset(of: header) { return .sessions }
        return nil
    }

    // MARK: - Plan

    private struct SetRow {
        let line: Int
        let rawName: String
        let dateRaw: String
        let date: Date
        let reps: Int
        let weightKg: Double?
        let duration: Double?
        let note: String?
        let importKey: String
    }

    private struct SessionRow {
        let line: Int
        let type: String
        let startRaw: String
        let start: Date
        let end: Date
        let duration: Double?
        let calories: Double?
        let distance: Double?
        let location: String
        let note: String?
        var importKey: String { "setgraph:session:\(type == SetGraphImport.syntheticType ? "synthetic" : type)|\(startRaw)" }
        var isStrength: Bool { SetGraphImport.strengthTypes.contains(type) }
    }

    public static func plan(setsCSV: String, sessionsCSV: String?, existing: Existing,
                            timeZone: TimeZone = .current, now: Date = .now) -> ImportPlan
    {
        var plan = ImportPlan()
        let dates = DateFormatter()
        dates.locale = Locale(identifier: "en_US_POSIX")
        dates.calendar = Calendar(identifier: .gregorian)
        dates.timeZone = timeZone
        dates.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        func fail(_ file: File, _ line: Int, _ reason: String) { plan.errors.append(Issue(file: file, line: line, reason: reason)) }

        /// Rows as column-name → trimmed value; reports a missing header or a wrong field count.
        func table(_ text: String, _ file: File, required: [String]) -> [(line: Int, v: [String: String])] {
            var rows = CSV.parse(text)
            guard !rows.isEmpty else { fail(file, 1, "file is empty"); return [] }
            let header = rows.removeFirst().fields.map { $0.trimmingCharacters(in: .whitespaces) }
            let missing = required.filter { !header.contains($0) }
            guard missing.isEmpty else { fail(file, 1, "missing column \(missing.joined(separator: ", "))"); return [] }
            return rows.compactMap { row in
                guard row.fields.count == header.count else {
                    fail(file, row.line, "expected \(header.count) fields, found \(row.fields.count)")
                    return nil
                }
                let values = row.fields.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                return (row.line, Dictionary(zip(header, values), uniquingKeysWith: { a, _ in a }))
            }
        }

        /// nil = empty; .none inside = present but not a number.
        func number(_ s: String) -> Double?? {
            if s.isEmpty { return .some(nil) }
            guard let d = Double(s), d.isFinite else { return nil }
            return .some(d)
        }

        // Sessions file.
        var sessions: [SessionRow] = []
        var seenSessions = Set<String>()
        let sessionRows = sessionsCSV.map { table($0, .sessions, required: sessionsHeader) } ?? []
        for (line, v) in sessionRows {
            let type = v["Activity Type"]!, startRaw = v["Start Date"]!, endRaw = v["End Date"]!
            guard !type.isEmpty else { fail(.sessions, line, "missing activity type"); continue }
            guard let start = dates.date(from: startRaw) else { fail(.sessions, line, "bad start date \"\(startRaw)\""); continue }
            guard let end = dates.date(from: endRaw) else { fail(.sessions, line, "bad end date \"\(endRaw)\""); continue }
            guard end >= start else { fail(.sessions, line, "end before start"); continue }
            guard let duration = number(v["Duration (seconds)"]!), duration.map({ $0 >= 0 }) ?? true else {
                fail(.sessions, line, "bad duration \"\(v["Duration (seconds)"]!)\""); continue
            }
            guard let calories = number(v["Calories (kcal)"]!) else {
                fail(.sessions, line, "bad calories \"\(v["Calories (kcal)"]!)\""); continue
            }
            guard let distance = number(v["Distance (meters)"]!) else {
                fail(.sessions, line, "bad distance \"\(v["Distance (meters)"]!)\""); continue
            }
            let row = SessionRow(line: line, type: type, startRaw: startRaw, start: start, end: end, duration: duration,
                                 calories: calories, distance: distance, location: v["Location"]!,
                                 note: v["Notes"]!.isEmpty ? nil : v["Notes"]!)
            guard seenSessions.insert(row.importKey).inserted else {
                plan.duplicates.append(Issue(file: .sessions, line: line, reason: "duplicate row, skipped")); continue
            }
            sessions.append(row)
        }

        // Sets file.
        var sets: [SetRow] = []
        var occurrences: [String: Int] = [:]
        for (line, v) in table(setsCSV, .sets, required: setsHeader) {
            let name = v["Exercise"]!, dateRaw = v["Date"]!, repsRaw = v["Repetitions"]!
            let kgRaw = v["Weight (kg)"]!, lbRaw = v["Weight (lb)"]!
            guard !name.isEmpty else { fail(.sets, line, "missing exercise name"); continue }
            guard let date = dates.date(from: dateRaw) else { fail(.sets, line, "bad date \"\(dateRaw)\""); continue }
            guard let r = Double(repsRaw), r.isFinite, r >= 0, r == r.rounded(), r < 100_000 else {
                fail(.sets, line, "repetitions must be a whole number ≥ 0, got \"\(repsRaw)\""); continue
            }
            guard let kg = number(kgRaw) else { fail(.sets, line, "bad weight (kg) \"\(kgRaw)\""); continue }
            guard let lb = number(lbRaw) else { fail(.sets, line, "bad weight (lb) \"\(lbRaw)\""); continue }
            guard let duration = number(v["Duration (seconds)"]!) else {
                fail(.sets, line, "bad duration \"\(v["Duration (seconds)"]!)\""); continue
            }
            let tuple = "\(Exercise.nameKey(for: name))|\(dateRaw)|\(repsRaw)|\(kgRaw)"
            let n = occurrences[tuple, default: 0]
            occurrences[tuple] = n + 1
            guard n == 0 else { plan.duplicates.append(Issue(file: .sets, line: line, reason: "duplicate row, skipped")); continue }
            sets.append(SetRow(line: line, rawName: name, dateRaw: dateRaw, date: date, reps: Int(r),
                               weightKg: kg ?? lb.map(WeightUnit.lb.toKg), duration: duration,
                               note: v["Note"]!.isEmpty ? nil : v["Note"]!, importKey: "setgraph:set:\(tuple)|\(n)"))
        }
        sets.sort { ($0.date, $0.line) < ($1.date, $1.line) }

        // Assign sets to sessions (rule 1), the rest to synthetic sessions (rule 2).
        var setsBySession: [[SetRow]] = Array(repeating: [], count: sessions.count)
        var loose: [SetRow] = []
        for set in sets {
            let best = sessions.indices
                .filter { sessions[$0].start <= set.date && set.date <= sessions[$0].end }
                .min { a, b in
                    let (x, y) = (sessions[a], sessions[b])
                    return (x.isStrength ? 0 : 1, x.end.timeIntervalSince(x.start))
                        < (y.isStrength ? 0 : 1, y.end.timeIntervalSince(y.start))
                }
            if let best { setsBySession[best].append(set) } else { loose.append(set) }
        }
        var groups: [[SetRow]] = []
        for set in loose {
            if let last = groups.last?.last, set.date.timeIntervalSince(last.date) <= 90 * 60,
               calendar.isDate(set.date, inSameDayAs: last.date)
            {
                groups[groups.count - 1].append(set)
            } else {
                groups.append([set])
            }
        }
        for group in groups {
            let first = group[0]
            sessions.append(SessionRow(line: first.line, type: syntheticType, startRaw: first.dateRaw,
                                       start: first.date - 60, end: group.last!.date, duration: nil, calories: nil,
                                       distance: nil, location: "", note: nil))
            setsBySession.append(group)
        }

        // Exercises.
        var exerciseIDs = existing.exercises
        var createdKeys = Set<String>()
        var matched = Set<UUID>()
        var merges: [String: (to: String, rows: Int)] = [:]
        func exerciseID(named display: String, cardio: CardioActivity? = nil) -> UUID {
            let key = Exercise.nameKey(for: display)
            if let id = exerciseIDs[key] {
                if !createdKeys.contains(key) { matched.insert(id) }
                return id
            }
            let id = UUID()
            exerciseIDs[key] = id
            createdKeys.insert(key)
            plan.exercisesCreated.append(ExerciseDTO(
                id: id, userID: nil, createdAt: now, updatedAt: now, deletedAt: nil, name: display, nameKey: key,
                muscleGroup: (cardio == nil ? muscleGroup(forNameKey: key) : .cardio).rawValue,
                kind: (cardio == nil ? ExerciseKind.strength : .cardio).rawValue, cardioActivity: cardio?.rawValue,
                isBuiltIn: false, defaultRestSeconds: 90))
            return id
        }
        func strengthExerciseID(raw: String) -> UUID {
            let key = Exercise.nameKey(for: raw)
            if let target = aliases[key] {
                merges[raw, default: (target, 0)].rows += 1
                return exerciseID(named: target)
            }
            return exerciseID(named: aliasTargets[key] ?? raw)
        }

        // Emit rows.
        let order = sessions.indices.sorted { (sessions[$0].start, sessions[$0].line) < (sessions[$1].start, sessions[$1].line) }
        for i in order {
            let s = sessions[i], members = setsBySession[i]
            let isCardio = !s.isStrength && s.type != syntheticType
            let cardioKey = "setgraph:cardio:\(s.importKey)"
            var alreadyHere = members.filter { existing.importKeys.contains($0.importKey) }.count
            if isCardio && existing.importKeys.contains(cardioKey) { alreadyHere += 1 }
            plan.alreadyImported += alreadyHere

            guard !existing.importKeys.contains(s.importKey) else {
                plan.alreadyImported += 1
                for set in members where !existing.importKeys.contains(set.importKey) {
                    fail(.sets, set.line, "belongs to an already-imported session, skipped")
                }
                continue
            }
            // Its sets all came in earlier (e.g. under synthetic sessions from a sets-only import): an empty
            // copy would be a duplicate. Cardio sessions are kept, as they carry their own entry.
            if !isCardio, !members.isEmpty, alreadyHere == members.count {
                plan.alreadyImported += 1
                continue
            }

            let span = s.end.timeIntervalSince(s.start)
            let sessionID = UUID()
            plan.sessions.append(WorkoutSessionDTO(
                id: sessionID, userID: nil, createdAt: now, updatedAt: now, deletedAt: nil, routineID: nil,
                startedAt: s.start, endedAt: s.end, pausedSeconds: max(0, span - (s.duration ?? span)),
                source: SessionSource.import.rawValue, activeCalories: s.calories, avgHeartRate: nil,
                healthKitWorkoutID: nil, importKey: s.importKey, note: s.note))
            plan.sessionsByType[s.type, default: 0] += 1

            var sortOrder = 0
            if isCardio {
                let (name, activity) = cardioExercise(type: s.type, location: s.location)
                let entryID = UUID()
                plan.sessionExercises.append(SessionExerciseDTO(
                    id: entryID, userID: nil, createdAt: now, updatedAt: now, deletedAt: nil, sessionID: sessionID,
                    exerciseID: exerciseID(named: name, cardio: activity), sortOrder: 0, note: nil))
                if !existing.importKeys.contains(cardioKey) {
                    plan.sets.append(SetEntryDTO(
                        id: UUID(), userID: nil, createdAt: now, updatedAt: now, deletedAt: nil, sessionExerciseID: entryID,
                        sortOrder: 0, weightKg: nil, reps: nil, distanceMeters: s.distance, durationSeconds: s.duration ?? span,
                        restSeconds: nil, completedAt: s.end, importKey: cardioKey))
                }
                sortOrder = 1
            }

            // Strength sets (rules 3–5), already in time order.
            var entries: [UUID: (id: UUID, count: Int, notes: [String])] = [:]
            var entryOrder: [UUID] = []
            for (j, set) in members.enumerated() {
                let gap = j + 1 < members.count ? members[j + 1].date.timeIntervalSince(set.date) : 0
                let exID = strengthExerciseID(raw: set.rawName)
                if entries[exID] == nil {
                    entries[exID] = (UUID(), 0, [])
                    entryOrder.append(exID)
                }
                if let note = set.note, !entries[exID]!.notes.contains(note) { entries[exID]!.notes.append(note) }
                guard !existing.importKeys.contains(set.importKey) else { continue }
                plan.sets.append(SetEntryDTO(
                    id: UUID(), userID: nil, createdAt: now, updatedAt: now, deletedAt: nil,
                    sessionExerciseID: entries[exID]!.id, sortOrder: entries[exID]!.count, weightKg: set.weightKg,
                    reps: set.reps, distanceMeters: nil, durationSeconds: set.duration,
                    restSeconds: gap > 0 && gap <= 600 ? gap : nil, completedAt: set.date, importKey: set.importKey))
                entries[exID]!.count += 1
            }
            for exID in entryOrder {
                let e = entries[exID]!
                plan.sessionExercises.append(SessionExerciseDTO(
                    id: e.id, userID: nil, createdAt: now, updatedAt: now, deletedAt: nil, sessionID: sessionID,
                    exerciseID: exID, sortOrder: sortOrder, note: e.notes.isEmpty ? nil : e.notes.joined(separator: "; ")))
                sortOrder += 1
            }
        }

        plan.exercisesMatched = matched.count
        plan.aliasMerges = merges.map { AliasMerge(from: $0.key, to: $0.value.to, rows: $0.value.rows) }
            .sorted { ($0.to, $0.from) < ($1.to, $1.from) }
        plan.errors.sort { ($0.file.rawValue, $0.line) < ($1.file.rawValue, $1.line) }
        return plan
    }
}

/// Everything an import would add, with counts for the preview. Insert with `commit(into:)`.
public struct ImportPlan: Sendable {
    public var sessions: [WorkoutSessionDTO] = []
    public var sessionExercises: [SessionExerciseDTO] = []
    public var sets: [SetEntryDTO] = []
    public var exercisesCreated: [ExerciseDTO] = []
    /// New sessions per SetGraph Activity Type; "Synthetic" for sets outside any session.
    public var sessionsByType: [String: Int] = [:]
    /// Distinct existing exercises the file maps to.
    public var exercisesMatched = 0
    public var aliasMerges: [SetGraphImport.AliasMerge] = []
    public var duplicates: [SetGraphImport.Issue] = []
    /// Sessions and sets whose import key is already in the store.
    public var alreadyImported = 0
    public var errors: [SetGraphImport.Issue] = []

    public var syntheticSessions: Int { sessionsByType[SetGraphImport.syntheticType] ?? 0 }
    public var strengthSessions: Int {
        sessionsByType.filter { SetGraphImport.strengthTypes.contains($0.key) }.values.reduce(0, +)
    }
    public var cardioSessions: Int { sessions.count - strengthSessions - syntheticSessions }
    public var isEmpty: Bool { sessions.isEmpty && sets.isEmpty && exercisesCreated.isEmpty }

    /// Inserts every row (all `needsPush = true`) with one save.
    public func commit(into context: ModelContext) throws {
        for d in exercisesCreated { context.insert(d.makeModel()) }
        for d in sessions { context.insert(d.makeModel()) }
        for d in sessionExercises { context.insert(d.makeModel()) }
        for d in sets { context.insert(d.makeModel()) }
        try context.save()
    }
}
