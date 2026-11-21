import Charts
import SwiftData
import SwiftUI
import WorkoutCore

/// Progress tab: workout counts, weekly volume, and per-exercise drill-down.
struct StatsView: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<WorkoutSession> { $0.deletedAt == nil && $0.endedAt != nil })
    private var sessions: [WorkoutSession]
    @Query(sort: \Exercise.name) private var exercises: [Exercise]
    @AppStorage("weightUnit") private var weightUnit: WeightUnit = .kg
    @State private var byMonth = false

    var body: some View {
        // ponytail: re-joins all history on each render; cache by session updatedAt if it gets slow.
        let records = ((try? Queries.loggedSets(in: context)) ?? []).compactMap(\.record)
        NavigationStack {
            List {
                if sessions.isEmpty {
                    ContentUnavailableView("No Workouts Yet", systemImage: "chart.bar",
                                           description: Text("Finish a workout to see your progress."))
                } else {
                    totals
                    countsChart
                    volumeChart(records)
                    exerciseList(records)
                }
            }
            .navigationTitle("Progress")
        }
    }

    private var totals: some View {
        let dates = sessions.map(\.startedAt)
        let cal = Calendar.isoWeeks
        let week = dates.count { cal.isDate($0, equalTo: .now, toGranularity: .weekOfYear) }
        let month = dates.count { cal.isDate($0, equalTo: .now, toGranularity: .month) }
        return Section {
            HStack {
                stat("\(WorkoutCounts.total(dates))", "workouts")
                stat("\(week)", "this week")
                stat("\(month)", "this month")
            }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack {
            Text(value).font(.largeTitle.bold()).monospacedDigit().foregroundStyle(.tint)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var countsChart: some View {
        let dates = sessions.map(\.startedAt)
        let counts = (byMonth ? WorkoutCounts.perMonth(dates) : WorkoutCounts.perWeek(dates)).mapValues(Double.init)
        let points = filledBuckets(counts, component: byMonth ? .month : .weekOfYear)
        let unit: Calendar.Component = byMonth ? .month : .weekOfYear
        return Section {
            Picker("Period", selection: $byMonth) {
                Text("Weekly").tag(false)
                Text("Monthly").tag(true)
            }
            .pickerStyle(.segmented)
            Chart(points) {
                BarMark(x: .value("Date", $0.date, unit: unit), y: .value("Workouts", $0.value))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(height: 180)
            .accessibilityChartDescriptor(DatedChartDescriptor(
                title: byMonth ? "Workouts per month" : "Workouts per week", valueName: "Workouts", points: points
            ) { "\(Int($0)) workouts" })
        } header: {
            Text(byMonth ? "Workouts per month" : "Workouts per week")
        }
    }

    private func volumeChart(_ records: [SetRecord]) -> some View {
        let unit = weightUnit
        let points = filledBuckets(Volume.byWeek(records).mapValues(unit.fromKg), component: .weekOfYear)
        return Section("Weekly volume (\(unit.rawValue))") {
            Chart(points) {
                BarMark(x: .value("Week", $0.date, unit: .weekOfYear), y: .value("Volume", $0.value))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(height: 180)
            .accessibilityChartDescriptor(DatedChartDescriptor(
                title: "Weekly volume", valueName: "Volume", points: points
            ) { unit.spokenVolume(unit.toKg($0)) })
        }
    }

    private func exerciseList(_ records: [SetRecord]) -> some View {
        let byExercise = Dictionary(grouping: records, by: \.exerciseID)
        return Section("Exercises") {
            ForEach(exercises.filter { byExercise[$0.id] != nil }) { e in
                NavigationLink {
                    ExerciseStatsView(exercise: e, records: byExercise[e.id] ?? [])
                } label: {
                    LabeledContent(e.name, value: "\(Set(byExercise[e.id]?.map(\.sessionID) ?? []).count) sessions")
                }
            }
        }
    }
}
