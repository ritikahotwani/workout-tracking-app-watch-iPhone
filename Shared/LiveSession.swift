import Foundation
import SwiftData
import SwiftUI
import WorkoutCore
#if os(watchOS)
import WatchKit
#else
import UIKit
#endif

/// State and logic of one live workout. Every change is saved immediately so a crash loses nothing.
@Observable @MainActor
final class LiveSession {
    struct Item {
        let entry: SessionExercise
        let exercise: Exercise
        let target: RoutineExercise?
        var sets: [SetEntry] = []
        /// Sets from the last session with this exercise.
        let last: [SetEntry]
        /// PRs from prior sessions (this session's sets are added at check time).
        let baseline: PRBaseline

        var restSeconds: Int { target?.restSeconds ?? exercise.defaultRestSeconds }
        var isCardio: Bool { exercise.kind == .cardio }
    }

    let context: ModelContext
    let workout: WorkoutSession
    let manager = WorkoutManager()
    /// Phone history the watch merges into last time and PR baselines (empty on iPhone).
    private let snapshots: [UUID: ExerciseSnapshot]
    private(set) var items: [Item] = []
    private(set) var index = 0

    // Values being edited, canonical units.
    var weightKg = 0.0
    var reps = 10
    var distanceMeters = 0.0

    /// PRs hit by the last logged set of the current exercise.
    private(set) var prHits: Set<PRType> = []

    /// Rest overlay is visible while `restEnd` is set.
    private(set) var restEnd: Date?
    private(set) var restTotal: TimeInterval = 0
    private var restStart: Date?
    private var restSet: SetEntry?
    private var restTask: Task<Void, Never>?

    /// Running cardio activity: which item, and workout elapsed time when it began.
    private var cardio: (index: Int, startElapsed: TimeInterval)?

    var current: Item? { items.indices.contains(index) ? items[index] : nil }
    var isCardioRunning: Bool { cardio != nil }

    init(routine: Routine?, context: ModelContext, snapshots: [UUID: ExerciseSnapshot] = [:]) {
        self.context = context
        self.snapshots = snapshots
        workout = WorkoutSession(routineID: routine?.id, source: Self.source)
        context.insert(workout)
        if let routine {
            for (item, exercise) in (try? Queries.routineExercises(routineID: routine.id, in: context)) ?? [] {
                append(exercise, target: item)
            }
        }
        save()
        prefill()
        manager.setStart(workout.startedAt)
    }

    func start() async {
        do {
            try await manager.requestAuthorization()
            try await manager.start(at: workout.startedAt)
        } catch {
            print("Health workout unavailable, logging without it: \(error)")
        }
    }

    // MARK: Exercises

    func add(_ exercise: Exercise) {
        append(exercise, target: nil)
        save()
        go(to: items.count - 1)
    }

    func go(to i: Int) {
        guard items.indices.contains(i) else { return }
        if cardio != nil, i != index { logCardio() }
        index = i
        prHits = []
        prefill()
    }

    func setNote(_ text: String) {
        guard let entry = current?.entry else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        entry.note = trimmed.isEmpty ? nil : trimmed
        entry.touch()
        save()
    }

    private func append(_ exercise: Exercise, target: RoutineExercise?) {
        let entry = SessionExercise(sessionID: workout.id, exerciseID: exercise.id, sortOrder: items.count)
        context.insert(entry)
        let last = (try? Queries.lastPerformance(exerciseID: exercise.id, excludingSession: workout.id, in: context)) ?? []
        let baseline = (try? Queries.prBaseline(exerciseID: exercise.id, excludingSession: workout.id, in: context))
            ?? PRBaseline()
        let snapshot = snapshots[exercise.id]
        items.append(Item(entry: entry, exercise: exercise, target: target,
                          last: snapshot?.lastPerformance(local: last) ?? last,
                          baseline: snapshot.map { baseline.merged(with: $0.baseline) } ?? baseline))
    }

    /// Last session's set at the same index, else its last set, else today's previous set, else target reps.
    private func prefill() {
        guard let item = current else { return }
        let n = item.sets.count
        let source = item.last.indices.contains(n) ? item.last[n] : item.last.last ?? item.sets.last
        weightKg = source?.weightKg ?? 0
        reps = source?.reps ?? item.target?.targetReps ?? 10
        distanceMeters = 0
    }

    // MARK: Strength

    func stepWeight(_ steps: Int, unit: WeightUnit) {
        let display = (unit.fromKg(weightKg) / unit.step).rounded() * unit.step + Double(steps) * unit.step
        weightKg = unit.toKg(max(0, display))
    }

    func stepReps(_ steps: Int) { reps = max(0, reps + steps) }

    func logSet() {
        guard let item = current, !item.isCardio else { return }
        let now = Date.now
        endRest(at: now)
        let set = SetEntry(sessionExerciseID: item.entry.id, sortOrder: item.sets.count,
                           weightKg: weightKg, reps: reps, completedAt: now)
        context.insert(set)
        let new = SetRecord(sessionID: workout.id, exerciseID: item.exercise.id, date: now, weightKg: weightKg, reps: reps)
        prHits = PRDetector.check(new: new, baseline: item.baseline, sessionSoFar: sessionRecords(item.exercise.id))
        items[index].sets.append(set)
        save()
        startRest(after: set, seconds: item.restSeconds, at: now)

        var message = "Set \(item.sets.count + 1) logged. Rest \(spokenDuration(TimeInterval(item.restSeconds)))."
        if !prHits.isEmpty {
            Self.haptic(success: true)
            let unit = WeightUnit(rawValue: UserDefaults.standard.string(forKey: "weightUnit") ?? "") ?? .kg
            message += " New personal record: \(prHits.spokenList), \(unit.spoken(weightKg)), \(reps) reps."
        }
        announce(message)
        prefill()
    }

    private func sessionRecords(_ exerciseID: UUID) -> [SetRecord] {
        items.filter { $0.exercise.id == exerciseID }.flatMap(\.sets).compactMap { set in
            set.reps.map {
                SetRecord(sessionID: workout.id, exerciseID: exerciseID, date: set.completedAt,
                          weightKg: set.weightKg ?? 0, reps: $0)
            }
        }
    }

    // MARK: Rest (date-based)

    private func startRest(after set: SetEntry, seconds: Int, at now: Date) {
        let end = now + TimeInterval(seconds)
        restSet = set
        restStart = now
        restEnd = end
        restTotal = TimeInterval(seconds)
        restTask = Task { [weak self] in
            if seconds > 10 {
                try? await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow - 10)))
                guard !Task.isCancelled else { return }
                self?.announce("10 seconds of rest left")
            }
            try? await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            Self.haptic(success: false)
            self?.announce("Rest over")
            self?.restEnd = nil  // actual rest keeps counting until the next set or skip
        }
    }

    func skipRest() { endRest(at: .now) }

    /// Records actual rest into the set that started it and hides the overlay.
    private func endRest(at now: Date) {
        if let set = restSet, let start = restStart {
            set.restSeconds = now.timeIntervalSince(start)
            set.touch()
            save()
        }
        cancelRest()
    }

    private func cancelRest() {
        restTask?.cancel()
        restTask = nil
        restSet = nil
        restStart = nil
        restEnd = nil
    }

    // MARK: Cardio (manual distance; GPS is Phase 8)

    func startCardio() {
        guard let item = current, item.isCardio, cardio == nil else { return }
        let now = Date.now
        endRest(at: now)
        manager.beginCardio(item.exercise.cardioActivity ?? .other, at: now)
        cardio = (index, manager.elapsed(at: now))
        announce("\(item.exercise.name) started")
    }

    func cardioDuration(at date: Date) -> TimeInterval {
        cardio.map { max(0, manager.elapsed(at: date) - $0.startElapsed) } ?? 0
    }

    func logCardio() {
        guard let running = cardio else { return }
        let now = Date.now
        let duration = cardioDuration(at: now)
        let item = items[running.index]
        manager.endCardio(at: now)
        cardio = nil
        let set = SetEntry(sessionExerciseID: item.entry.id, sortOrder: item.sets.count,
                           distanceMeters: distanceMeters > 0 ? distanceMeters : nil,
                           durationSeconds: duration, completedAt: now)
        context.insert(set)
        items[running.index].sets.append(set)
        save()
        let unit = DistanceUnit(rawValue: UserDefaults.standard.string(forKey: "distanceUnit") ?? "") ?? .km
        announce("\(item.exercise.name) logged: \(spokenDuration(duration)), \(unit.spoken(distanceMeters)).")
        distanceMeters = 0
    }

    // MARK: Session

    func togglePause() {
        if manager.isPaused { manager.resume() } else { manager.pause() }
        announce(manager.isPaused ? "Workout paused" : "Workout resumed")
    }

    func end() async {
        if cardio != nil { logCardio() }
        cancelRest()  // no rest after the final set
        let now = Date.now
        let summary = await manager.end(at: now)
        workout.endedAt = now
        workout.healthKitWorkoutID = summary.workoutID
        workout.avgHeartRate = summary.averageHeartRate
        workout.activeCalories = summary.activeCalories
        workout.pausedSeconds = max(0, now.timeIntervalSince(workout.startedAt) - summary.elapsed)
        workout.touch()
        for item in items where item.sets.isEmpty && item.entry.note == nil { item.entry.markDeleted() }
        save()
    }

    /// Ends this device's sessions left open by a crash, at their last logged set, so history and "last time" see them.
    static func closeAbandoned(in context: ModelContext) {
        let source = Self.source.rawValue
        guard let open = try? context.fetch(FetchDescriptor<WorkoutSession>(predicate: #Predicate {
            $0.endedAt == nil && $0.deletedAt == nil && $0.sourceRaw == source
        })) else { return }
        for session in open {
            let sid = session.id
            let entries = (try? context.fetch(FetchDescriptor<SessionExercise>(predicate: #Predicate { $0.sessionID == sid }))) ?? []
            let last = entries.flatMap { (try? Queries.sets(sessionExerciseID: $0.id, in: context)) ?? [] }
                .map(\.completedAt).max()
            session.endedAt = last ?? session.startedAt
            session.touch()
        }
        try? context.save()
    }

    #if os(watchOS)
    static let source = SessionSource.watch
    /// PR hit (`success`) or rest over.
    private static func haptic(success: Bool) { WKInterfaceDevice.current().play(success ? .success : .notification) }
    #else
    static let source = SessionSource.phone
    private static func haptic(success: Bool) {
        UINotificationFeedbackGenerator().notificationOccurred(success ? .success : .warning)
    }
    #endif

    private func save() {
        do { try context.save() } catch { print("Save failed: \(error)") }
    }

    private func announce(_ message: String) {
        AccessibilityNotification.Announcement(message).post()
    }
}

extension Set<PRType> {
    var spokenList: String {
        PRType.allCases.filter(contains).map(\.title).formatted(.list(type: .and))
    }
}

extension PRType {
    var title: String {
        switch self {
        case .heaviestWeight: "heaviest weight"
        case .bestE1RM: "best estimated one-rep max"
        case .bestRepsAtWeight: "most reps at this weight"
        case .bestSessionVolume: "best session volume"
        }
    }
}
