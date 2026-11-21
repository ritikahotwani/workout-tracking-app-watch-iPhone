import SwiftData
import SwiftUI
import WorkoutCore

/// Ended sessions, newest first, as a List section. Swipe to soft-delete (cascades to exercises and sets).
struct HistorySection: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<WorkoutSession> { $0.deletedAt == nil && $0.endedAt != nil },
           sort: \WorkoutSession.startedAt, order: .reverse) private var sessions: [WorkoutSession]
    @Query private var routines: [Routine]  // deleted ones too, so old sessions keep their name
    @Query private var exercises: [Exercise]
    @AppStorage("weightUnit") private var weightUnit: WeightUnit = .kg

    var body: some View {
        // ponytail: re-joins all history on each render; cache by session updatedAt if it gets slow.
        let bySession = Dictionary(grouping: (try? Queries.loggedSets(in: context)) ?? [], by: \.sessionID)
        Section("History") {
            if sessions.isEmpty {
                Text("Finished workouts appear here.").foregroundStyle(.secondary)
            }
            ForEach(sessions) { session in
                let sets = bySession[session.id] ?? []
                NavigationLink(value: session) {
                    row(session, title: sessionTitle(session, routines: routines, exercises: exercises, sets: sets),
                        sets: sets.count, volume: Volume.total(sets.compactMap(\.record)))
                }
            }
            .onDelete { offsets in
                for s in offsets.map({ sessions[$0] }) {
                    do { try Queries.deleteSession(s, in: context) } catch { print("Delete failed: \(error)") }
                }
            }
        }
    }

    private func row(_ s: WorkoutSession, title: String, sets: Int, volume: Double) -> some View {
        let minutes = activeDuration(s)
        return VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            Text([
                s.startedAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)),
                shortDuration(minutes),
                plural(sets, "set"),
                volume > 0 ? weightUnit.volume(volume) : nil,
            ].compactMap { $0 }.joined(separator: " · "))
            .font(.subheadline).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([
            title,
            s.startedAt.formatted(.dateTime.weekday(.wide).day().month(.wide)),
            spokenMinutes(minutes),
            plural(sets, "set"),
            volume > 0 ? "volume \(weightUnit.spokenVolume(volume))" : nil,
        ].compactMap { $0 }.joined(separator: ", "))
    }
}

// MARK: Shared display helpers (history and stats)

/// Routine name, else the cardio exercise or top muscle groups of `sets` (the session's logged sets), else "Workout".
func sessionTitle(_ s: WorkoutSession, routines: [Routine], exercises: [Exercise], sets: [Queries.LoggedSet]) -> String {
    let byID = Dictionary(exercises.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    return SessionTitle.make(routine: s.routineID.flatMap { id in routines.first { $0.id == id }?.name },
                             setExercises: sets.compactMap { byID[$0.exerciseID] })
}

/// Active time: wall clock minus paused time.
func activeDuration(_ s: WorkoutSession) -> TimeInterval {
    max(0, (s.endedAt ?? s.startedAt).timeIntervalSince(s.startedAt) - s.pausedSeconds)
}

/// "52 min" / "1 hr, 5 min".
func shortDuration(_ seconds: TimeInterval) -> String {
    Duration.seconds(Int(seconds / 60) * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
}

/// "52 minutes".
func spokenMinutes(_ seconds: TimeInterval) -> String {
    Duration.seconds(Int(seconds / 60) * 60).formatted(.units(allowed: [.hours, .minutes], width: .wide))
}

extension WeightUnit {
    /// Whole-number total, e.g. "6,200 kg".
    func volume(_ kg: Double) -> String {
        fromKg(kg).formatted(.number.precision(.fractionLength(0))) + " " + rawValue
    }

    /// "6,200 kilograms".
    func spokenVolume(_ kg: Double) -> String {
        Measurement(value: fromKg(kg).rounded(), unit: unitMass)
            .formatted(.measurement(width: .wide, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0))))
    }
}

/// One logged set: "1   80 kg × 8   rest 1:30", with a trophy when it set a PR.
struct SetRow: View {
    let number: Int
    let set: SetEntry
    let weightUnit: WeightUnit
    let distanceUnit: DistanceUnit
    var prs: Set<PRType> = []

    var body: some View {
        HStack(spacing: 12) {
            Text("\(number)").foregroundStyle(.secondary).frame(minWidth: 20, alignment: .leading)
            Text(text.short)
            if !prs.isEmpty {
                Image(systemName: "trophy.fill").foregroundStyle(.tint).accessibilityHidden(true)
            }
            Spacer()
            if let rest = set.restSeconds {
                Text("rest " + clock(rest)).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .monospacedDigit()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([
            "Set \(number): \(text.spoken)",
            set.restSeconds.map { "rest \(spokenDuration($0))" },
            prs.isEmpty ? nil : "personal record: \(prs.spokenList)",
        ].compactMap { $0 }.joined(separator: ", "))
    }

    private var text: (short: String, spoken: String) {
        if let reps = set.reps {
            let kg = set.weightKg ?? 0
            return ("\(weightUnit.short(kg)) \(weightUnit.rawValue) × \(reps)", "\(weightUnit.spoken(kg)), \(plural(reps, "rep"))")
        }
        let d = set.distanceMeters
        let t = set.durationSeconds ?? 0
        return ([d.map { distanceUnit.short($0) + " " + distanceUnit.rawValue }, clock(t)].compactMap { $0 }.joined(separator: " in "),
                [d.map(distanceUnit.spoken), spokenDuration(t)].compactMap { $0 }.joined(separator: " in "))
    }
}
