import SwiftData
import SwiftUI
import WorkoutCore

/// Add (`exercise == nil`) or edit an exercise. Built-ins only allow changing the default rest.
struct ExerciseEditor: View {
    let exercise: Exercise?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var muscleGroup: MuscleGroup
    @State private var kind: ExerciseKind
    @State private var activity: CardioActivity
    @State private var rest: Int
    @State private var error: String?

    init(exercise: Exercise?) {
        self.exercise = exercise
        _name = State(initialValue: exercise?.name ?? "")
        _muscleGroup = State(initialValue: exercise?.muscleGroup ?? .chest)
        _kind = State(initialValue: exercise?.kind ?? .strength)
        _activity = State(initialValue: exercise?.cardioActivity ?? .running)
        _rest = State(initialValue: exercise?.defaultRestSeconds ?? 90)
    }

    private var isBuiltIn: Bool { exercise?.isBuiltIn ?? false }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if isBuiltIn {
                        LabeledContent("Name", value: name)
                        LabeledContent("Muscle group", value: muscleGroup.title)
                        LabeledContent("Type", value: kind.rawValue.capitalized)
                        if kind == .cardio { LabeledContent("Activity", value: activity.title) }
                    } else {
                        TextField("Name", text: $name)
                            .textInputAutocapitalization(.words)
                            .onChange(of: name) { error = nil }
                        if let error {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote).foregroundStyle(.red)
                        }
                        Picker("Type", selection: $kind) {
                            ForEach(ExerciseKind.allCases, id: \.self) { Text($0.rawValue.capitalized) }
                        }
                        .onChange(of: kind) { if kind == .cardio { muscleGroup = .cardio } }
                        Picker("Muscle group", selection: $muscleGroup) {
                            ForEach(MuscleGroup.allCases, id: \.self) { Text($0.title) }
                        }
                        if kind == .cardio {
                            Picker("Activity", selection: $activity) {
                                ForEach(CardioActivity.allCases, id: \.self) { Text($0.title) }
                            }
                        }
                    }
                }
                Section {
                    ValueStepper.rest("Default rest", value: $rest)
                }
            }
            .navigationTitle(exercise == nil ? "New Exercise" : (isBuiltIn ? name : "Edit Exercise"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(trimmedName.isEmpty)
                }
            }
        }
    }

    private func save() {
        let newName = trimmedName
        let key = Exercise.nameKey(for: newName)
        let selfID = exercise?.id
        let sameName = (try? context.fetch(FetchDescriptor<Exercise>(
            predicate: #Predicate { $0.nameKey == key && $0.deletedAt == nil }))) ?? []
        if sameName.contains(where: { $0.id != selfID }) {
            let message = "An exercise named \u{201C}\(newName)\u{201D} already exists."
            error = message
            AccessibilityNotification.Announcement(message).post()
            return
        }

        let cardio = kind == .cardio ? activity : nil
        if let e = exercise {
            let changed = e.name != newName || e.muscleGroup != muscleGroup || e.kind != kind
                || e.cardioActivity != cardio || e.defaultRestSeconds != rest
            if changed {
                if e.name != newName { e.rename(newName) }
                e.muscleGroup = muscleGroup
                e.kind = kind
                e.cardioActivity = cardio
                e.defaultRestSeconds = rest
                e.touch()
            }
        } else {
            context.insert(Exercise(name: newName, muscleGroup: muscleGroup, kind: kind,
                                    cardioActivity: cardio, defaultRestSeconds: rest))
        }
        dismiss()
    }
}
