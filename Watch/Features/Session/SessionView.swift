import SwiftData
import SwiftUI
import WorkoutCore

/// Live session as vertical pages: current exercise · metrics · controls (PLAN §6).
struct SessionView: View {
    @Bindable var live: LiveSession
    let onEnd: () -> Void
    @State private var page = 0

    var body: some View {
        NavigationStack {
            TabView(selection: $page) {
                ExercisePage(live: live).tag(0)
                MetricsPage(live: live)
                    .accessibilityElement(children: .contain).accessibilityLabel("Metrics").tag(1)
                ControlsPage(live: live, page: $page, onEnd: onEnd)
                    .accessibilityElement(children: .contain).accessibilityLabel("Controls").tag(2)
            }
            .tabViewStyle(.verticalPage)
        }
    }
}

private struct MetricsPage: View {
    let live: LiveSession

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = live.manager.elapsed(at: context.date)
            let hr = live.manager.heartRate.map { Int($0.rounded()) }
            let kcal = Int((live.manager.activeCalories ?? 0).rounded())
            VStack(alignment: .leading, spacing: 6) {
                Text(clock(elapsed))
                    .font(.system(.largeTitle, design: .rounded, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(.tint)
                Label(hr.map { "\($0) bpm" } ?? "-- bpm", systemImage: "heart.fill")
                Label("\(kcal) kcal", systemImage: "flame.fill")
                if live.manager.isPaused { Text("Paused").foregroundStyle(.secondary) }
            }
            .font(.title3.monospacedDigit())
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([
                "Elapsed \(spokenDuration(elapsed))",
                hr.map { "heart rate \($0)" } ?? "heart rate unavailable",
                "\(kcal) calories",
                live.manager.isPaused ? "paused" : nil,
            ].compactMap { $0 }.joined(separator: ", "))
        }
    }
}

private struct ControlsPage: View {
    @Bindable var live: LiveSession
    @Binding var page: Int
    let onEnd: () -> Void
    @State private var confirmEnd = false
    @State private var ending = false

    var body: some View {
        List {
            Button(live.manager.isPaused ? "Resume" : "Pause",
                   systemImage: live.manager.isPaused ? "play.fill" : "pause.fill") { live.togglePause() }
            Button("End Workout", systemImage: "xmark", role: .destructive) { confirmEnd = true }
                .disabled(ending)
            NavigationLink { ExercisePicker { live.add($0); page = 0 } } label: {
                Label("Add Exercise", systemImage: "plus")
            }
            if let entry = live.current?.entry {
                TextField("Note", text: Binding(get: { entry.note ?? "" }, set: { live.setNote($0) }))
                    .accessibilityLabel("Note for \(live.current?.exercise.name ?? "exercise")")
            }
            HStack {
                Button("Previous", systemImage: "chevron.up") { live.go(to: live.index - 1); page = 0 }
                    .disabled(live.index == 0)
                Button("Next", systemImage: "chevron.down") { live.go(to: live.index + 1); page = 0 }
                    .disabled(live.index >= live.items.count - 1)
            }
            .labelStyle(.iconOnly)
            Section("Exercises") {
                ForEach(Array(live.items.enumerated()), id: \.offset) { i, item in
                    Button { live.go(to: i); page = 0 } label: {
                        HStack {
                            Text(item.exercise.name).lineLimit(1)
                            Spacer()
                            Text("\(item.sets.count)").foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityLabel("Exercise \(i + 1) of \(live.items.count): \(item.exercise.name), \(item.sets.count) sets logged")
                    .accessibilityAddTraits(i == live.index ? .isSelected : [])
                }
            }
        }
        .confirmationDialog("End workout?", isPresented: $confirmEnd) {
            Button("End Workout", role: .destructive) {
                ending = true
                Task {
                    await live.end()
                    onEnd()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves this workout to Health.")
        }
    }
}

struct ExercisePicker: View {
    @Query(filter: #Predicate<Exercise> { $0.deletedAt == nil }, sort: \Exercise.name) private var exercises: [Exercise]
    @Environment(\.dismiss) private var dismiss
    let pick: (Exercise) -> Void

    var body: some View {
        List {
            ForEach(MuscleGroup.allCases, id: \.self) { group in
                let matches = exercises.filter { $0.muscleGroup == group }
                if !matches.isEmpty {
                    Section(group.rawValue.capitalized) {
                        ForEach(matches) { e in
                            Button(e.name) {
                                pick(e)
                                dismiss()
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Add Exercise")
    }
}
