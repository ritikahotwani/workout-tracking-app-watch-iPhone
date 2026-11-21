import SwiftData
import SwiftUI
import WorkoutCore

/// Full session: summary, exercises with sets/rest/notes/PRs, and a comparison with the previous session.
struct SessionDetailView: View {
    let session: WorkoutSession
    @Environment(\.modelContext) private var context
    @Query private var routines: [Routine]
    @Query private var exercises: [Exercise]
    @AppStorage("weightUnit") private var weightUnit: WeightUnit = .kg
    @AppStorage("distanceUnit") private var distanceUnit: DistanceUnit = .km

    private struct Block: Identifiable {
        let entry: SessionExercise
        let name: String
        let sets: [SetEntry]
        var id: UUID { entry.id }
    }

    var body: some View {
        let blocks = loadBlocks()
        let logged = (try? Queries.loggedSets(in: context)) ?? []
        let records = logged.compactMap(\.record)
        let mine = records.filter { $0.sessionID == session.id }
        let prs = prMarkers(blocks, history: records)
        List {
            summary(sets: blocks.reduce(0) { $0 + $1.sets.count }, volume: Volume.total(mine))
            ForEach(blocks) { block in
                Section {
                    Text(block.name).font(.headline).accessibilityAddTraits(.isHeader)
                    ForEach(Array(block.sets.enumerated()), id: \.element.id) { i, set in
                        SetRow(number: i + 1, set: set, weightUnit: weightUnit, distanceUnit: distanceUnit,
                               prs: prs[set.id] ?? [])
                    }
                    let v = Volume.total(mine.filter { $0.exerciseID == block.entry.exerciseID })
                    if v > 0 {
                        LabeledContent("Volume") {
                            Text(weightUnit.volume(v)).accessibilityLabel(weightUnit.spokenVolume(v))
                        }
                    }
                    if let note = block.entry.note {
                        Label(note, systemImage: "note.text").foregroundStyle(.secondary)
                            .accessibilityLabel("Note: \(note)")
                    }
                }
            }
            compareSection(blocks, records: records)
        }
        .navigationTitle(sessionTitle(session, routines: routines))
    }

    private func summary(sets: Int, volume: Double) -> some View {
        Section {
            LabeledContent("Date", value: session.startedAt.formatted(.dateTime.weekday(.wide).day().month(.wide).year().hour().minute()))
            LabeledContent("Duration") {
                Text(shortDuration(activeDuration(session))).accessibilityLabel(spokenMinutes(activeDuration(session)))
            }
            LabeledContent("Sets", value: "\(sets)")
            if volume > 0 {
                LabeledContent("Volume") {
                    Text(weightUnit.volume(volume)).accessibilityLabel(weightUnit.spokenVolume(volume))
                }
            }
            if let hr = session.avgHeartRate {
                LabeledContent("Average heart rate", value: "\(Int(hr.rounded())) bpm")
            }
            if let kcal = session.activeCalories {
                LabeledContent("Active calories", value: "\(Int(kcal.rounded())) kcal")
            }
        }
    }

    // MARK: Compare

    @ViewBuilder
    private func compareSection(_ blocks: [Block], records: [SetRecord]) -> some View {
        let before = records.filter { $0.sessionID != session.id && $0.date < session.startedAt }
        let mine = records.filter { $0.sessionID == session.id }
        let routinePrev = previousRoutineSession()
        let perExercise: [(String, Compare.Comparison)] = uniqueExercises(blocks).compactMap { exerciseID, name in
            let prior = before.filter { $0.exerciseID == exerciseID }
            guard let prevID = prior.last?.sessionID else { return nil }
            let current = mine.filter { $0.exerciseID == exerciseID }
            guard !current.isEmpty else { return nil }
            return (name, Compare.compare(current: current, previous: prior.filter { $0.sessionID == prevID }))
        }
        if routinePrev != nil || !perExercise.isEmpty {
            Section("Compared with last time") {
                if let prev = routinePrev {
                    CompareRow(title: "Whole session vs \(prev.startedAt.formatted(.dateTime.day().month(.abbreviated)))",
                               comparison: Compare.compare(current: mine, previous: records.filter { $0.sessionID == prev.id }),
                               unit: weightUnit)
                }
                ForEach(perExercise, id: \.0) { name, comparison in
                    CompareRow(title: name, comparison: comparison, unit: weightUnit)
                }
            }
        }
    }

    private func previousRoutineSession() -> WorkoutSession? {
        guard let rid = session.routineID else { return nil }
        let start = session.startedAt
        var d = FetchDescriptor<WorkoutSession>(
            predicate: #Predicate { $0.routineID == rid && $0.deletedAt == nil && $0.endedAt != nil && $0.startedAt < start },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first
    }

    private func uniqueExercises(_ blocks: [Block]) -> [(UUID, String)] {
        var seen = Set<UUID>()
        return blocks.compactMap { seen.insert($0.entry.exerciseID).inserted ? ($0.entry.exerciseID, $0.name) : nil }
    }

    // MARK: Data

    private func loadBlocks() -> [Block] {
        let sid = session.id
        let entries = (try? context.fetch(FetchDescriptor<SessionExercise>(
            predicate: #Predicate { $0.sessionID == sid && $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.sortOrder)]))) ?? []
        return entries.map { e in
            Block(entry: e, name: exercises.first { $0.id == e.exerciseID }?.name ?? "Exercise",
                  sets: (try? Queries.sets(sessionExerciseID: e.id, in: context)) ?? [])
        }
    }

    /// PRs each set hit when it was logged, replayed with `PRDetector` against earlier sessions.
    private func prMarkers(_ blocks: [Block], history: [SetRecord]) -> [UUID: Set<PRType>] {
        var result: [UUID: Set<PRType>] = [:]
        var soFar: [SetRecord] = []
        var baselines: [UUID: PRBaseline] = [:]
        for block in blocks {
            let ex = block.entry.exerciseID
            let baseline = baselines[ex] ?? PersonalRecords.baseline(for: history.filter {
                $0.exerciseID == ex && $0.sessionID != session.id && $0.date < session.startedAt
            })
            baselines[ex] = baseline
            for set in block.sets {
                guard let reps = set.reps else { continue }
                let r = SetRecord(sessionID: session.id, exerciseID: ex, date: set.completedAt,
                                  weightKg: set.weightKg ?? 0, reps: reps)
                let hits = PRDetector.check(new: r, baseline: baseline, sessionSoFar: soFar)
                if !hits.isEmpty { result[set.id] = hits }
                soFar.append(r)
            }
        }
        return result
    }
}

/// Volume, top set and e1RM deltas with ▲/▼ and words, never colour alone.
private struct CompareRow: View {
    let title: String
    let comparison: Compare.Comparison
    let unit: WeightUnit

    var body: some View {
        let c = comparison
        let volume = delta(c.volumeDelta, whole: true)
        let top = c.topSetWeightDelta.map { delta($0) }
        let e1rm = c.e1RMDelta.map { delta($0) }
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text("Volume \(unit.volume(c.current.volume))  \(volume.short)")
            if let set = c.current.topSet, let top {
                Text("Top set \(unit.short(set.weightKg)) \(unit.rawValue) × \(set.reps)  \(top.short)\(repsShort)")
            }
            if let e = c.current.bestE1RM, let e1rm {
                Text("Est. 1RM \(unit.short(e)) \(unit.rawValue)  \(e1rm.short)")
            }
        }
        .font(.subheadline.monospacedDigit())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([
            title,
            "volume \(unit.spokenVolume(c.current.volume)), \(volume.spoken)",
            c.current.topSet.flatMap { set in top.map { "top set \(unit.spoken(set.weightKg)) for \(set.reps) reps, \($0.spoken)\(repsSpoken)" } },
            c.current.bestE1RM.flatMap { e in e1rm.map { "estimated one-rep max \(unit.spoken(e)), \($0.spoken)" } },
        ].compactMap { $0 }.joined(separator: ". "))
    }

    private var repsShort: String {
        guard let d = comparison.topSetRepsDelta, d != 0 else { return "" }
        return d > 0 ? ", ▲ \(d) reps" : ", ▼ \(-d) reps"
    }

    private var repsSpoken: String {
        guard let d = comparison.topSetRepsDelta, d != 0 else { return "" }
        return d > 0 ? ", \(d) more reps" : ", \(-d) fewer reps"
    }

    private func delta(_ kg: Double, whole: Bool = false) -> (short: String, spoken: String) {
        let shown = whole ? unit.volume(abs(kg)) : "\(unit.short(abs(kg))) \(unit.rawValue)"
        let spoken = whole ? unit.spokenVolume(abs(kg)) : unit.spoken(abs(kg))
        if (whole ? unit.fromKg(abs(kg)).rounded() : (unit.fromKg(abs(kg)) * 10).rounded()) == 0 {
            return ("= same", "same as last time")
        }
        return kg > 0 ? ("▲ \(shown)", "up \(spoken)") : ("▼ \(shown)", "down \(spoken)")
    }
}
