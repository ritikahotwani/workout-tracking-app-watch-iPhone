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
                    RestIndicator(end: end, total: live.restTotal, skip: live.skipRest)
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
            let duration = live.cardioDuration(at: context.date)
            let pace = distanceUnit.pace(distanceMeters: live.distanceMeters, durationSeconds: duration)
            let speed = distanceUnit.speed(distanceMeters: live.distanceMeters, durationSeconds: duration)
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    ValueBox(value: clock(duration), unit: "time", isFocused: false)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Duration")
                        .accessibilityValue(spokenDuration(duration))
                    ValueBox(value: distanceUnit.short(live.distanceMeters), unit: distanceUnit.rawValue,
                             isFocused: focus == .distance)
                        .focusable()
                        .focused($focus, equals: .distance)
                        .digitalCrownRotation(
                            Binding(get: { distanceUnit.fromMeters(live.distanceMeters) },
                                    set: { live.distanceMeters = distanceUnit.toMeters(max(0, $0)) }),
                            from: 0, through: 200, by: distanceUnit.step,
                            sensitivity: .medium, isContinuous: false, isHapticFeedbackEnabled: true)
                        .onTapGesture { focus = .distance }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Distance")
                        .accessibilityValue(distanceUnit.spoken(live.distanceMeters))
                        .accessibilityAdjustableAction {
                            let v = distanceUnit.fromMeters(live.distanceMeters) + ($0 == .increment ? 1 : -1) * distanceUnit.step
                            live.distanceMeters = distanceUnit.toMeters(max(0, v))
                        }
                }
                .defaultFocus($focus, .distance)

                HStack {
                    Text(pace.map { clock($0) + " /" + distanceUnit.rawValue } ?? "--")
                        .accessibilityLabel("Pace")
                        .accessibilityValue(pace.map { "\(spokenDuration($0)) per \(distanceUnit == .km ? "kilometer" : "mile")" } ?? "none")
                    Spacer()
                    Text(speed.map { $0.formatted(.number.precision(.fractionLength(1))) + (distanceUnit == .km ? " km/h" : " mph") } ?? "--")
                        .accessibilityLabel("Speed")
                        .accessibilityValue(speed.map(distanceUnit.spokenSpeed) ?? "none")
                }
                .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)

                Button { live.isCardioRunning ? live.logCardio() : live.startCardio() } label: {
                    Text(live.isCardioRunning ? "Log" : "Start").font(.title3.bold()).frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel(live.isCardioRunning
                    ? "Log \(spokenDuration(duration)), \(distanceUnit.spoken(live.distanceMeters))"
                    : "Start \(live.current?.exercise.name ?? "cardio")")
            }
        }
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
