import SwiftData
import SwiftUI
import WorkoutCore

/// Exercises grouped by muscle group, searchable. With `onPick`, it becomes a picker (no add, edit or delete).
struct ExerciseListView: View {
    var onPick: ((Exercise) -> Void)?

    @Query(filter: #Predicate<Exercise> { $0.deletedAt == nil }, sort: \Exercise.name) private var exercises: [Exercise]
    @State private var search = ""
    @State private var editing: Exercise?
    @State private var adding = false

    private var groups: [(MuscleGroup, [Exercise])] {
        let matches = search.isEmpty ? exercises : exercises.filter { $0.name.localizedStandardContains(search) }
        let byGroup = Dictionary(grouping: matches, by: \.muscleGroup)
        return MuscleGroup.allCases.compactMap { g in byGroup[g].map { (g, $0) } }
    }

    var body: some View {
        List {
            ForEach(groups, id: \.0) { group, items in
                Section(group.title) {
                    ForEach(items) { e in
                        Button {
                            if let onPick { onPick(e) } else { editing = e }
                        } label: {
                            row(e)
                        }
                        .tint(.primary)
                        .swipeActions {
                            if onPick == nil && !e.isBuiltIn {
                                Button("Delete", systemImage: "trash", role: .destructive) { e.markDeleted() }
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "Search exercises")
        .overlay {
            if groups.isEmpty && !search.isEmpty { ContentUnavailableView.search(text: search) }
        }
        .toolbar {
            if onPick == nil {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Exercise", systemImage: "plus") { adding = true }
                }
            }
        }
        .sheet(item: $editing) { ExerciseEditor(exercise: $0) }
        .sheet(isPresented: $adding) { ExerciseEditor(exercise: nil) }
    }

    private func row(_ e: Exercise) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(e.name)
                if !e.isBuiltIn {
                    Text("Custom").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text("\(e.defaultRestSeconds) s rest")
                .font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(e.name + (e.isBuiltIn ? "" : ", custom"))
        .accessibilityValue("Rest \(e.defaultRestSeconds) seconds")
    }
}

extension CardioActivity {
    var title: String { self == .stairs ? "Stair Climbing" : rawValue.capitalized }
}
