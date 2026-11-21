import SwiftUI
import WorkoutCore

/// iPhone live session: same `LiveSession` as the watch, laid out on one screen with Log Set pinned at the bottom.
struct PhoneSessionView: View {
    @Bindable var live: LiveSession
    let onEnd: () -> Void
    @Environment(BackupController.self) private var backup
    @AppStorage("weightUnit") private var weightUnit: WeightUnit = .kg
    @AppStorage("distanceUnit") private var distanceUnit: DistanceUnit = .km
    @State private var confirmEnd = false
    @State private var ending = false
    @State private var adding = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    metrics
                    if let item = live.current {
                        exercise(item)
                    } else {
                        ContentUnavailableView("No Exercises", systemImage: "dumbbell",
                                               description: Text("Add an exercise to start logging."))
                    }
                }
                .padding()
            }
            .safeAreaInset(edge: .bottom) {
                if let item = live.current { logButton(item).padding().background(.bar) }
            }
            .navigationTitle(live.manager.isPaused ? "Paused" : "Workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(live.manager.isPaused ? "Resume" : "Pause",
                           systemImage: live.manager.isPaused ? "play.fill" : "pause.fill") { live.togglePause() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Exercise", systemImage: "plus") { adding = true }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("End Workout", systemImage: "stop.fill", role: .destructive) { confirmEnd = true }.disabled(ending)
                }
            }
            .confirmationDialog("End workout?", isPresented: $confirmEnd, titleVisibility: .visible) {
                Button("End Workout", role: .destructive) {
                    ending = true
                    Task {
                        await live.end()
                        backup.syncSoon()
                        onEnd()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Saves this workout to history and Health.")
            }
            .sheet(isPresented: $adding) {
                NavigationStack {
                    ExerciseListView { live.add($0); adding = false }
                        .navigationTitle("Add Exercise")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { Button("Cancel") { adding = false } }
                }
            }
        }
    }

    // MARK: Metrics

    private var metrics: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = live.manager.elapsed(at: context.date)
            let hr = live.manager.heartRate.map { Int($0.rounded()) }
            let kcal = Int((live.manager.activeCalories ?? 0).rounded())
            HStack {
                Text(clock(elapsed)).font(.title2.weight(.semibold)).foregroundStyle(.tint)
                Spacer()
                Label(hr.map { "\($0)" } ?? "--", systemImage: "heart.fill")
                Label("\(kcal) kcal", systemImage: "flame.fill")
            }
            .font(.body.monospacedDigit())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([
                "Elapsed \(spokenDuration(elapsed))",
                hr.map { "heart rate \($0)" } ?? "heart rate unavailable",
                "\(kcal) calories",
                live.manager.isPaused ? "paused" : nil,
            ].compactMap { $0 }.joined(separator: ", "))
        }
    }

    // MARK: Exercise

    private func exercise(_ item: LiveSession.Item) -> some View {
        VStack(spacing: 16) {
            exerciseSwitcher(item)
            if let end = live.restEnd {
                RestIndicator(end: end, total: live.restTotal, skip: live.skipRest).font(.body)
            } else if let last = lastLine(item.last, weight: weightUnit, distance: distanceUnit) {
                Text(last.short).font(.subheadline).foregroundStyle(.secondary)
                    .accessibilityLabel(last.spoken)
            }
            if item.isCardio { cardio(item) } else { strength }
            if !live.prHits.isEmpty {
                Label("Personal record", systemImage: "trophy.fill")
                    .font(.subheadline.bold()).foregroundStyle(.tint)
                    .accessibilityLabel("Personal record: \(live.prHits.spokenList)")
            }
            loggedSets(item)
            TextField("Note", text: Binding(get: { item.entry.note ?? "" }, set: { live.setNote($0) }), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Note for \(item.exercise.name)")
        }
        .accessibilityAction(named: "Next exercise") { live.go(to: live.index + 1) }
        .accessibilityAction(named: "Previous exercise") { live.go(to: live.index - 1) }
    }

    private func exerciseSwitcher(_ item: LiveSession.Item) -> some View {
        HStack {
            Button("Previous exercise", systemImage: "chevron.left") { live.go(to: live.index - 1) }
                .disabled(live.index == 0)
            Spacer()
            VStack(spacing: 2) {
                Menu {
                    ForEach(Array(live.items.enumerated()), id: \.offset) { i, other in
                        Button("\(other.exercise.name) (\(other.sets.count))") { live.go(to: i) }
                            .accessibilityLabel("Exercise \(i + 1) of \(live.items.count): \(other.exercise.name), \(other.sets.count) sets logged")
                    }
                } label: {
                    Text(item.exercise.name).font(.title2.bold()).multilineTextAlignment(.center).foregroundStyle(.primary)
                }
                .accessibilityLabel("Current exercise: \(item.exercise.name), \(live.index + 1) of \(live.items.count)")
                .accessibilityHint("Choose another exercise")
                Text("Exercise \(live.index + 1) of \(live.items.count)").font(.caption).accessibilityHidden(true)
            }
            Spacer()
            Button("Next exercise", systemImage: "chevron.right") { live.go(to: live.index + 1) }
                .disabled(live.index >= live.items.count - 1)
        }
        .labelStyle(.iconOnly)
        .font(.title3)
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
    }

    private var strength: some View {
        HStack(spacing: 12) {
            BigStepper(value: weightUnit.short(live.weightKg), unit: weightUnit.rawValue,
                       label: "Weight", spokenValue: weightUnit.spoken(live.weightKg)) {
                live.stepWeight($0, unit: weightUnit)
            }
            BigStepper(value: "\(live.reps)", unit: "reps", label: "Reps", spokenValue: "\(live.reps) reps") {
                live.stepReps($0)
            }
        }
    }

    private func cardio(_ item: LiveSession.Item) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let duration = live.cardioDuration(at: context.date)
            let pace = distanceUnit.pace(distanceMeters: live.distanceMeters, durationSeconds: duration)
            VStack(spacing: 12) {
                Text(clock(duration))
                    .font(.system(.largeTitle, design: .rounded, weight: .semibold)).monospacedDigit()
                    .accessibilityLabel("Duration")
                    .accessibilityValue(spokenDuration(duration))
                LabeledContent("Distance (\(distanceUnit.rawValue))") {
                    TextField("0", value: Binding(get: { distanceUnit.fromMeters(live.distanceMeters) },
                                                  set: { live.distanceMeters = distanceUnit.toMeters(max(0, $0)) }),
                              format: .number.precision(.fractionLength(0...2)))
                        .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                        .font(.title2.monospacedDigit())
                        .accessibilityLabel("Distance in \(distanceUnit == .km ? "kilometers" : "miles")")
                }
                Text(pace.map { "Pace " + clock($0) + " /" + distanceUnit.rawValue } ?? "Pace --")
                    .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                    .accessibilityLabel(pace.map { "Pace, \(spokenDuration($0)) per \(distanceUnit == .km ? "kilometer" : "mile")" } ?? "Pace unavailable")
            }
        }
    }

    private func loggedSets(_ item: LiveSession.Item) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(item.sets.enumerated()), id: \.offset) { i, set in
                SetRow(number: i + 1, set: set, weightUnit: weightUnit, distanceUnit: distanceUnit)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Log

    @ViewBuilder
    private func logButton(_ item: LiveSession.Item) -> some View {
        if item.isCardio {
            Button { live.isCardioRunning ? live.logCardio() : live.startCardio() } label: {
                Text(live.isCardioRunning ? "Log \(item.exercise.name)" : "Start \(item.exercise.name)")
                    .font(.title3.bold()).frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
        } else {
            let n = item.sets.count + 1
            Button { live.logSet() } label: {
                Text("Log Set \(n)").font(.title3.bold()).frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel("Log set \(n): \(weightUnit.spoken(live.weightKg)), \(live.reps) reps")
        }
    }
}

/// Big value with − / + buttons. VoiceOver sees one adjustable element: "Weight, 80 kilograms, adjustable".
private struct BigStepper: View {
    let value: String
    let unit: String
    let label: String
    let spokenValue: String
    let step: (Int) -> Void
    @ScaledMetric(relativeTo: .largeTitle) private var size = 56.0

    var body: some View {
        VStack(spacing: 8) {
            Text(value)
                .font(.system(size: size, weight: .semibold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.5)
            Text(unit).font(.subheadline).foregroundStyle(.secondary)
            HStack {
                Button("Decrease \(label)", systemImage: "minus") { step(-1) }
                Button("Increase \(label)", systemImage: "plus") { step(1) }
            }
            .labelStyle(.iconOnly).font(.title2).buttonStyle(.bordered).buttonRepeatBehavior(.enabled)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(spokenValue)
        .accessibilityAdjustableAction { step($0 == .increment ? 1 : -1) }
    }
}
