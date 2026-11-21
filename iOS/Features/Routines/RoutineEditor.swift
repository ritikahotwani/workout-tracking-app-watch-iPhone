import SwiftData
import SwiftUI
import WorkoutCore

/// Ordered exercise list of one routine.
struct RoutineEditor: View {
    let routine: Routine

    @Environment(\.modelContext) private var context
    @Query private var items: [RoutineExercise]
    /// Includes soft-deleted exercises so existing rows keep their names.
    @Query private var exercises: [Exercise]
    @State private var picking = false

    init(routine: Routine) {
        self.routine = routine
        let id = routine.id
        _items = Query(filter: #Predicate<RoutineExercise> { $0.routineID == id && $0.deletedAt == nil },
                       sort: \.sortOrder)
    }

    private var exercisesByID: [UUID: Exercise] {
        Dictionary(exercises.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    var body: some View {
        let byID = exercisesByID
        List {
            ForEach(items) { item in
                let exercise = byID[item.exerciseID]
                NavigationLink {
                    RoutineItemEditor(item: item, exercise: exercise)
                } label: {
                    row(item, exercise)
                }
            }
            .onDelete { offsets in offsets.forEach { items[$0].markDeleted() } }
            .onMove(perform: move)
        }
        .overlay {
            if items.isEmpty {
                ContentUnavailableView("No Exercises", systemImage: "dumbbell",
                                       description: Text("Tap + to add exercises from the library."))
            }
        }
        .navigationTitle(routine.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add Exercise", systemImage: "plus") { picking = true }
            }
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
        }
        .sheet(isPresented: $picking) {
            NavigationStack {
                ExerciseListView(onPick: add)
                    .navigationTitle("Add Exercise")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { picking = false } }
                    }
            }
        }
    }

    private func row(_ item: RoutineExercise, _ exercise: Exercise?) -> some View {
        let rest = item.restSeconds ?? exercise?.defaultRestSeconds ?? 90
        return VStack(alignment: .leading, spacing: 2) {
            Text(exercise?.name ?? "Unknown exercise")
            Text("\(item.targetSets) × \(item.targetReps) · \(rest) s rest")
                .font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(exercise?.name ?? "Unknown exercise")
        .accessibilityValue("\(plural(item.targetSets, "set")) of \(plural(item.targetReps, "rep")), rest \(rest) seconds")
    }

    private func add(_ exercise: Exercise) {
        context.insert(RoutineExercise(routineID: routine.id, exerciseID: exercise.id,
                                       sortOrder: (items.last?.sortOrder ?? -1) + 1))
        picking = false
    }

    private func move(_ source: IndexSet, _ destination: Int) {
        var ordered = items
        ordered.move(fromOffsets: source, toOffset: destination)
        for (i, item) in ordered.enumerated() where item.sortOrder != i {
            item.sortOrder = i
            item.touch()
        }
    }
}

/// Targets and rest override for one routine row. Changes apply immediately.
private struct RoutineItemEditor: View {
    let item: RoutineExercise
    let exercise: Exercise?

    private var defaultRest: Int { exercise?.defaultRestSeconds ?? 90 }

    var body: some View {
        Form {
            Section("Targets") {
                ValueStepper(title: "Sets", value: bind(\.targetSets), range: 1...20)
                ValueStepper(title: "Reps", value: bind(\.targetReps), range: 1...100)
            }
            Section {
                Toggle("Custom rest", isOn: Binding(
                    get: { item.restSeconds != nil },
                    set: { item.restSeconds = $0 ? defaultRest : nil; item.touch() }))
                if item.restSeconds != nil {
                    ValueStepper.rest(value: Binding(
                        get: { item.restSeconds ?? defaultRest },
                        set: { item.restSeconds = $0; item.touch() }))
                } else {
                    LabeledContent("Rest", value: "\(defaultRest) s")
                        .accessibilityValue("\(defaultRest) seconds, exercise default")
                }
            } footer: {
                Text("Without a custom rest, the exercise's default rest is used.")
            }
        }
        .navigationTitle(exercise?.name ?? "Exercise")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func bind(_ keyPath: ReferenceWritableKeyPath<RoutineExercise, Int>) -> Binding<Int> {
        Binding(get: { item[keyPath: keyPath] }, set: { item[keyPath: keyPath] = $0; item.touch() })
    }
}
