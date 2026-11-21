import SwiftData
import SwiftUI
import WorkoutCore

/// Body tab: quick entry, trend chart, history (PLAN §6). Canonical kg; display unit only on screen.
struct BodyWeightView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("weightUnit") private var unit: WeightUnit = .kg
    @Query(filter: #Predicate<BodyWeightEntry> { $0.deletedAt == nil }, sort: \BodyWeightEntry.date, order: .reverse)
    private var entries: [BodyWeightEntry]
    @State private var input: Double?
    @FocusState private var inputFocused: Bool

    /// Accepted entry range in kg; anything outside is a typo.
    private static let validKg = 20.0...400.0

    private var inputKg: Double? {
        input.map(unit.toKg).flatMap { Self.validKg.contains($0) ? $0 : nil }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("Weight", value: $input, format: .number.precision(.fractionLength(0...1)))
                            .keyboardType(.decimalPad)
                            .focused($inputFocused)
                            .font(.title2.monospacedDigit())
                            .accessibilityLabel("Body weight in \(unit == .kg ? "kilograms" : "pounds")")
                        Text(unit.rawValue).foregroundStyle(.secondary).accessibilityHidden(true)
                        Button("Save", action: save)
                            .buttonStyle(.borderedProminent)
                            .disabled(inputKg == nil)
                    }
                }

                if !entries.isEmpty {
                    Section { WeightChart(entries: entries, unit: unit) }
                    Section("History") {
                        ForEach(entries) { entry in
                            HStack {
                                Text(entry.date, format: .dateTime.day().month().year())
                                if entry.source == .health {
                                    Image(systemName: "heart.fill").font(.caption).foregroundStyle(.secondary)
                                        .accessibilityLabel("from Health")
                                }
                                Spacer()
                                Text("\(display(entry.weightKg)) \(unit.rawValue)").monospacedDigit()
                                    .accessibilityLabel(unit.spoken(entry.weightKg))
                            }
                            .accessibilityElement(children: .combine)
                        }
                        .onDelete(perform: delete)
                    }
                }
            }
            .navigationTitle("Body")
            .scrollDismissesKeyboard(.immediately)
            .task { await importFromHealth() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await importFromHealth() } }
            }
            .onChange(of: entries.first?.id, initial: true) { if input == nil { prefill() } }
            .onChange(of: unit) { prefill() }
        }
    }

    private func display(_ kg: Double) -> String {
        unit.fromKg(kg).formatted(.number.precision(.fractionLength(1)))
    }

    private func prefill() {
        input = entries.first.map { (unit.fromKg($0.weightKg) * 10).rounded() / 10 }
    }

    private func save() {
        guard let kg = inputKg else { return }
        inputFocused = false
        let entry = BodyWeightEntry(weightKg: kg, source: .app)
        entry.touch()
        context.insert(entry)
        do { try context.save() } catch { print("Saving weight failed: \(error)"); return }
        AccessibilityNotification.Announcement("Weight saved").post()
        Task {
            do { try await BodyMassSync.shared.save(entry) } catch { print("Health write failed: \(error)") }
        }
    }

    private func delete(at offsets: IndexSet) {
        let doomed = offsets.map { entries[$0] }
        for entry in doomed { entry.markDeleted() }
        do { try context.save() } catch { print("Deleting weight failed: \(error)") }
        Task {
            for entry in doomed {
                do { try await BodyMassSync.shared.delete(entry) } catch { print("Health delete failed: \(error)") }
            }
        }
    }

    private func importFromHealth() async {
        do { try await BodyMassSync.shared.importChanges(into: context) } catch { print("Health import failed: \(error)") }
    }
}


#Preview {
    BodyWeightView().preferredColorScheme(.dark).modelContainer(try! makeModelContainer(inMemory: true))
}
