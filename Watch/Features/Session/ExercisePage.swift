import SwiftUI
import WorkoutCore

/// Current exercise: big values on the Digital Crown, one giant Log button, last session, PR badge.
struct ExercisePage: View {
    @Bindable var live: LiveSession
    @AppStorage("weightUnit") private var weightUnit: WeightUnit = .kg
    @AppStorage("distanceUnit") private var distanceUnit: DistanceUnit = .km
    @FocusState private var focus: Field?

    enum Field { case weight, reps, distance }

    var body: some View {
        if let item = live.current {
            let setNumber = item.sets.count + 1
            VStack(spacing: 4) {
                Text(item.exercise.name)
                    .font(.headline).lineLimit(1).minimumScaleFactor(0.6)
                if let end = live.restEnd {
                    RestIndicator(end: end, total: live.restTotal, skip: live.skipRest).font(.footnote)
                } else if let last = lastLine(item.last, weight: weightUnit, distance: distanceUnit) {
                    Text(last.short)
                        .font(.footnote).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.6)
                        .accessibilityLabel(last.spoken)
                }
                if item.isCardio { cardio } else { strength(setNumber: setNumber) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Current exercise: \(item.exercise.name), \(setLabel(item, setNumber))")
            .accessibilityAction(named: "Next exercise") { live.go(to: live.index + 1) }
            .accessibilityAction(named: "Previous exercise") { live.go(to: live.index - 1) }
        } else {
            VStack {
                Text("No exercises yet").foregroundStyle(.secondary)
                NavigationLink("Add Exercise") { ExercisePicker { live.add($0) } }
            }
        }
    }

    private func setLabel(_ item: LiveSession.Item, _ n: Int) -> String {
        if item.isCardio { return live.isCardioRunning ? "in progress" : "ready" }
        return item.target.map { "set \(n) of \($0.targetSets)" } ?? "set \(n)"
    }

    private func strength(setNumber: Int) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                ValueBox(value: weightUnit.short(live.weightKg), unit: weightUnit.rawValue, isFocused: focus == .weight)
                    .focusable()
                    .focused($focus, equals: .weight)
                    .digitalCrownRotation(
                        Binding(get: { weightUnit.fromKg(live.weightKg) },
                                set: { live.weightKg = weightUnit.toKg(max(0, $0)) }),
                        from: 0, through: weightUnit.fromKg(500), by: weightUnit.step,
                        sensitivity: .medium, isContinuous: false, isHapticFeedbackEnabled: true)
                    .onTapGesture { focus = .weight }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Weight")
                    .accessibilityValue(weightUnit.spoken(live.weightKg))
                    .accessibilityAdjustableAction { live.stepWeight($0 == .increment ? 1 : -1, unit: weightUnit) }

                ValueBox(value: "\(live.reps)", unit: "reps", isFocused: focus == .reps)
                    .focusable()
                    .focused($focus, equals: .reps)
                    .digitalCrownRotation(
                        Binding(get: { Double(live.reps) }, set: { live.reps = max(0, Int($0.rounded())) }),
                        from: 0, through: 100, by: 1,
                        sensitivity: .low, isContinuous: false, isHapticFeedbackEnabled: true)
                    .onTapGesture { focus = .reps }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Reps")
                    .accessibilityValue("\(live.reps) reps")
                    .accessibilityAdjustableAction { live.stepReps($0 == .increment ? 1 : -1) }
            }
            .defaultFocus($focus, .weight)

            Button { live.logSet() } label: {
                Text("Log Set").font(.title3.bold()).frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel("Log set \(setNumber): \(weightUnit.spoken(live.weightKg)), \(live.reps) reps")

            if !live.prHits.isEmpty {
                Label("PR", systemImage: "trophy.fill")
                    .font(.caption2.bold()).foregroundStyle(.tint)
                    .accessibilityLabel("Personal record: \(live.prHits.spokenList)")
            }
        }
    }

    private var cardio: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let running = live.isCardioRunning
            let duration = live.cardioDuration(at: context.date)
            let distance = live.cardioDistance
            let average = distanceUnit.pace(distanceMeters: distance, durationSeconds: duration)
            // Current pace/speed: GPS over the last ~30 s outdoors, else the average.
            let window = live.outdoor && running ? live.route.recentWindow : nil
            let pace = window.flatMap { distanceUnit.pace(distanceMeters: $0.meters, durationSeconds: $0.seconds) }
            let speed = window.map { distanceUnit.speed(distanceMeters: $0.meters, durationSeconds: $0.seconds) }
                ?? distanceUnit.speed(distanceMeters: distance, durationSeconds: duration)
            VStack(spacing: 4) {
                metrics(duration: duration, distance: distance, pace: pace, average: average, speed: speed, running: running)

                if !running, let item = live.current,
                   CardioActivity.isOutdoor(name: item.exercise.name, activity: item.exercise.cardioActivity) == nil {
                    Toggle("Outdoor", isOn: $live.outdoor)
                        .font(.footnote)
                        .accessibilityLabel("Outdoor, uses GPS for distance and route")
                }

                Button { running ? live.logCardio() : live.startCardio() } label: {
                    Text(running ? "End" : "Start").font(.title2.bold()).frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.borderedProminent)
                .tint(running ? .red : nil)
                .accessibilityLabel(running
                    ? "End and log \(spokenDuration(duration)), \(distanceUnit.spoken(distance))"
                    : "Start \(live.current?.exercise.name ?? "cardio"), \(live.outdoor ? "outdoor" : "indoor")")
            }
        }
        .onChange(of: splits) { _, n in
            guard n > 0 else { return }
            let average = distanceUnit.pace(distanceMeters: live.cardioDistance, durationSeconds: live.cardioDuration(at: .now))
            AccessibilityNotification.Announcement(
                "\(distanceUnit.spoken(distanceUnit.toMeters(Double(n))))" + (average.map { ". Average pace \(spokenPace($0))" } ?? "")
            ).post()
        }
    }

    /// Whole km/mi covered outdoors, for split announcements.
    private var splits: Int {
        live.outdoor && live.isCardioRunning ? Int(distanceUnit.fromMeters(live.cardioDistance)) : 0
    }

    /// One VoiceOver element; indoors it is adjustable (distance), like the Crown.
    @ViewBuilder
    private func metrics(duration: TimeInterval, distance: Double, pace: Double?, average: Double?, speed: Double?,
                         running: Bool) -> some View {
        let manual = !(live.outdoor && running)
        let grid = VStack(spacing: 2) {
            HStack(spacing: 6) {
                ValueBox(value: clock(duration), unit: "time", isFocused: false)
                ValueBox(value: distanceUnit.short(distance), unit: distanceUnit.rawValue, isFocused: manual && focus == .distance)
                    .focusable(manual)
                    .focused($focus, equals: .distance)
                    .digitalCrownRotation(
                        Binding(get: { distanceUnit.fromMeters(live.distanceMeters) },
                                set: { live.distanceMeters = distanceUnit.toMeters(max(0, $0)) }),
                        from: 0, through: 200, by: distanceUnit.step,
                        sensitivity: .medium, isContinuous: false, isHapticFeedbackEnabled: true)
                    .onTapGesture { if manual { focus = .distance } }
            }
            .defaultFocus($focus, .distance)
            if running {  // before Start this row would be all "--"; the Indoor/Outdoor toggle sits there instead
                HStack(spacing: 4) {
                    if live.outdoor { Metric(value: pace.map(clock), unit: "pace") }
                    Metric(value: average.map(clock), unit: "avg /\(distanceUnit.rawValue)")
                    Metric(value: speed.map { $0.formatted(.number.precision(.fractionLength(1))) },
                           unit: distanceUnit == .km ? "km/h" : "mph")
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([
            "Time \(spokenDuration(duration))",
            live.outdoor ? pace.map { "pace \(spokenPace($0))" } ?? "pace unavailable" : nil,
            average.map { "average pace \(spokenPace($0))" },
            speed.map { "speed \(distanceUnit.spokenSpeed($0))" },
        ].compactMap { $0 }.joined(separator: ", "))
        .accessibilityValue("Distance \(distanceUnit.spoken(distance))")
        if manual {
            grid.accessibilityAdjustableAction {
                let v = distanceUnit.fromMeters(live.distanceMeters) + ($0 == .increment ? 1 : -1) * distanceUnit.step
                live.distanceMeters = distanceUnit.toMeters(max(0, v))
            }
        } else {
            grid
        }
    }

    private func spokenPace(_ seconds: Double) -> String {
        "\(spokenDuration(seconds)) per \(distanceUnit == .km ? "kilometer" : "mile")"
    }
}

private struct Metric: View {
    let value: String?
    let unit: String

    var body: some View {
        VStack(spacing: 0) {
            Text(value ?? "--").font(.system(.title3, design: .rounded, weight: .semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(unit).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ValueBox: View {
    let value: String
    let unit: String
    let isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Text(value)
                .font(.system(.largeTitle, design: .rounded, weight: .semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.5)
            Text(unit).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(isFocused ? Color.accentColor : .clear, lineWidth: 2))
    }
}
