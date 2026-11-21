import SwiftData
import SwiftUI
import WorkoutCore

/// Log body weight with the Digital Crown, prefilled from the last entry.
struct LogWeightView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(WatchSync.self) private var sync
    @AppStorage("weightUnit") private var unit: WeightUnit = .kg
    @Query(filter: #Predicate<BodyWeightEntry> { $0.deletedAt == nil }, sort: \BodyWeightEntry.date, order: .reverse)
    private var entries: [BodyWeightEntry]
    /// Value in the display unit, so Crown steps stay clean.
    @State private var value: Double?

    private var step: Double { unit == .kg ? 0.1 : 0.2 }
    private var current: Double { value ?? defaultValue }
    private var currentKg: Double { unit.toKg(current) }

    private var defaultValue: Double {
        let v = unit.fromKg(entries.first?.weightKg ?? 70)
        return (v / step).rounded() * step
    }

    var body: some View {
        VStack(spacing: 8) {
            VStack(spacing: 0) {
                Text(current.formatted(.number.precision(.fractionLength(1))))
                    .font(.system(.largeTitle, design: .rounded).bold().monospacedDigit())
                    .lineLimit(1).minimumScaleFactor(0.5)
                Text(unit.rawValue).font(.headline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .focusable()
            .digitalCrownRotation(
                Binding(get: { current }, set: { value = ($0 / step).rounded() * step }),
                from: unit.fromKg(20), through: unit.fromKg(400), by: step,
                sensitivity: .medium, isContinuous: false, isHapticFeedbackEnabled: true)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Body weight")
            .accessibilityValue(unit.spoken(currentKg))
            .accessibilityAdjustableAction { direction in
                value = max(unit.fromKg(20), current + (direction == .increment ? step : -step))
            }

            Button(action: save) {
                Text("Save").font(.title3.bold()).frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
        }
        .navigationTitle("Weight")
        .onChange(of: unit) { value = nil }
    }

    private func save() {
        let entry = BodyWeightEntry(weightKg: currentKg, source: .app)
        entry.touch()
        context.insert(entry)
        do { try context.save() } catch { print("Saving weight failed: \(error)"); return }
        AccessibilityNotification.Announcement("Weight saved").post()
        Task {
            do { try await BodyMassSync.shared.save(entry) } catch { print("Health write failed: \(error)") }
            sync.flush()  // after the Health write, so the phone gets the sample ID to dedupe on
        }
        dismiss()
    }
}
