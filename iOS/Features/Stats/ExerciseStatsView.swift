import Charts
import SwiftUI
import WorkoutCore

/// One exercise: e1RM over time, per-session volume, and the four PR types with dates.
struct ExerciseStatsView: View {
    let exercise: Exercise
    /// This exercise's strength sets, oldest first.
    let records: [SetRecord]
    @AppStorage("weightUnit") private var weightUnit: WeightUnit = .kg

    private struct SessionPoint {
        let date: Date
        let bestE1RM: Double?
        let volume: Double
    }

    var body: some View {
        let unit = weightUnit
        let sessions = Dictionary(grouping: records, by: \.sessionID).values
            .map { sets in
                SessionPoint(date: sets.map(\.date).min()!, bestE1RM: sets.compactMap(\.e1RM).max(), volume: Volume.total(sets))
            }
            .sorted { $0.date < $1.date }
        let e1rm = sessions.compactMap { s in s.bestE1RM.map { DatedPoint(date: s.date, value: unit.fromKg($0)) } }
        let volume = sessions.map { DatedPoint(date: $0.date, value: unit.fromKg($0.volume)) }
        List {
            Section("Estimated 1RM (\(unit.rawValue))") {
                Chart(e1rm) {
                    LineMark(x: .value("Date", $0.date), y: .value("e1RM", $0.value))
                    PointMark(x: .value("Date", $0.date), y: .value("e1RM", $0.value))
                }
                .foregroundStyle(Color.accentColor)
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 200)
                .accessibilityChartDescriptor(DatedChartDescriptor(
                    title: "Estimated 1RM", valueName: "Estimated 1RM", points: e1rm, isLine: true
                ) { unit.spoken(unit.toKg($0)) })
            }
            Section("Volume per session (\(unit.rawValue))") {
                Chart(volume) {
                    BarMark(x: .value("Date", $0.date), y: .value("Volume", $0.value), width: .fixed(8))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(height: 180)
                .accessibilityChartDescriptor(DatedChartDescriptor(
                    title: "Volume per session", valueName: "Volume", points: volume
                ) { unit.spokenVolume(unit.toKg($0)) })
            }
            prSections(sessions: sessions)
        }
        .navigationTitle(exercise.name)
    }

    @ViewBuilder
    private func prSections(sessions: [SessionPoint]) -> some View {
        let b = PersonalRecords.baseline(for: records)
        Section("Personal records") {
            if let kg = b.heaviestKg {
                pr("Heaviest weight", unit(kg), spoken: weightUnit.spoken(kg), date: records.first { $0.weightKg == kg }?.date)
            }
            if let e = b.bestE1RM {
                pr("Best estimated 1RM", unit(e), spoken: weightUnit.spoken(e), date: records.first { $0.e1RM == e }?.date)
            }
            if let v = b.bestSessionVolume {
                pr("Best session volume", weightUnit.volume(v), spoken: weightUnit.spokenVolume(v),
                   date: sessions.first { $0.volume == v }?.date)
            }
        }
        Section("Best reps at each weight") {
            ForEach(b.bestRepsByWeight.sorted { $0.key > $1.key }, id: \.key) { kg, reps in
                let date = records.first { PersonalRecords.weightKey($0.weightKg) == kg && $0.reps == reps }?.date
                let weight = kg > 0 ? unit(kg) : "Bodyweight"
                HStack {
                    Text(weight).frame(maxWidth: .infinity, alignment: .leading)
                    Text(plural(reps, "rep")).frame(maxWidth: .infinity, alignment: .leading)
                    Text(date?.formatted(date: .abbreviated, time: .omitted) ?? "")
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
                }
                .monospacedDigit()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(kg > 0 ? weightUnit.spoken(kg) : "Bodyweight"): \(plural(reps, "rep"))"
                    + (date.map { ", \($0.formatted(date: .long, time: .omitted))" } ?? ""))
            }
        }
    }

    private func unit(_ kg: Double) -> String { "\(weightUnit.short(kg)) \(weightUnit.rawValue)" }

    private func pr(_ title: String, _ value: String, spoken: String, date: Date?) -> some View {
        LabeledContent {
            VStack(alignment: .trailing) {
                Text(value).monospacedDigit()
                if let date { Text(date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary) }
            }
        } label: {
            Label(title, systemImage: "trophy")
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(spoken)" + (date.map { ", \($0.formatted(date: .long, time: .omitted))" } ?? ""))
    }
}
