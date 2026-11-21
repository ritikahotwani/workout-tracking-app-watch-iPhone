import Foundation
import Testing
@testable import WorkoutCore

private let s1 = UUID(), s2 = UUID(), bench = UUID(), squat = UUID()
private var utc: Calendar {
    var c = Calendar(identifier: .iso8601)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}
private func day(_ s: String) -> Date { try! Date(s + "T12:00:00Z", strategy: .iso8601) }
private func set(_ w: Double, _ r: Int, session: UUID = s1, exercise: UUID = bench, date: String = "2026-11-17") -> SetRecord {
    SetRecord(sessionID: session, exerciseID: exercise, date: day(date), weightKg: w, reps: r)
}

@Suite struct VolumeTests {
    @Test func setVolume() {
        #expect(Volume.of(weightKg: 100, reps: 5) == 500)
        #expect(Volume.of(weightKg: nil, reps: 5) == 0)
        #expect(Volume.of(weightKg: 100, reps: nil) == 0)
        #expect(Volume.of(weightKg: 0, reps: 10) == 0)
        #expect(Volume.of(weightKg: -5, reps: 10) == 0)
    }

    @Test func aggregates() {
        let sets = [set(100, 5), set(60, 10, exercise: squat), set(100, 5, session: s2, date: "2026-11-24")]
        #expect(Volume.total(sets) == 1600)
        #expect(Volume.bySession(sets) == [s1: 1100, s2: 500])
        #expect(Volume.byExercise(sets) == [bench: 1000, squat: 600])
    }

    @Test func weeksStartMonday() {
        // Sun 22 Nov belongs to the week of Mon 16 Nov; Mon 23 Nov starts a new week.
        let sets = [set(100, 1, date: "2026-11-16"), set(100, 1, date: "2026-11-22"), set(100, 1, date: "2026-11-23")]
        let weeks = Volume.byWeek(sets, calendar: utc)
        #expect(weeks == [try! Date("2026-11-16T00:00:00Z", strategy: .iso8601): 200,
                          try! Date("2026-11-23T00:00:00Z", strategy: .iso8601): 100])
    }
}

@Suite struct OneRepMaxTests {
    @Test func epley() {
        #expect(OneRepMax.epley(weight: 100, reps: 1) == 100)
        #expect(OneRepMax.epley(weight: 100, reps: 10) == 100 * (1 + 10.0 / 30))
        #expect(OneRepMax.epley(weight: 100, reps: 0) == nil)
        #expect(OneRepMax.epley(weight: 100, reps: -1) == nil)
        #expect(OneRepMax.epley(weight: 0, reps: 5) == nil)
        #expect(OneRepMax.epley(weight: -10, reps: 5) == nil)
    }
}

@Suite struct PersonalRecordTests {
    let history = [set(100, 5), set(110, 1), set(100, 8, session: s2), set(80, 12, session: s2)]

    @Test func heaviest() { #expect(PersonalRecords.baseline(for: history).heaviestKg == 110) }

    @Test func bestE1RM() {
        // 100×8 → 126.67 beats 80×12 → 112, 100×5 → 116.67, 110×1 → 110.
        #expect(PersonalRecords.baseline(for: history).bestE1RM == 100 * (1 + 8.0 / 30))
    }

    @Test func bestRepsPerWeight() {
        let b = PersonalRecords.baseline(for: history + [set(80.000001, 3)])
        #expect(b.bestRepsByWeight == [100: 8, 110: 1, 80: 12])
    }

    @Test func bestSessionVolume() {
        // s1: 500 + 110 = 610; s2: 800 + 960 = 1760.
        #expect(PersonalRecords.baseline(for: history).bestSessionVolume == 1760)
    }

    @Test func emptyAndZeroReps() {
        #expect(PersonalRecords.baseline(for: [set(200, 0)]) == PRBaseline())
    }

    @Test func baselinesPerExercise() {
        let all = PersonalRecords.baselines(history + [set(140, 3, exercise: squat)])
        #expect(all[squat]?.heaviestKg == 140)
        #expect(all[bench]?.heaviestKg == 110)
    }
}

@Suite struct PRDetectorTests {
    let baseline = PRBaseline(heaviestKg: 100, bestE1RM: 120, bestRepsByWeight: [80: 10, 100: 3], bestSessionVolume: 1000)
    let today = UUID()
    func t(_ w: Double, _ r: Int) -> SetRecord { set(w, r, session: today) }

    @Test func heaviestWeight() {
        #expect(PRDetector.check(new: t(102.5, 1), baseline: baseline, sessionSoFar: []).contains(.heaviestWeight))
        #expect(!PRDetector.check(new: t(100, 1), baseline: baseline, sessionSoFar: []).contains(.heaviestWeight))
        // Already beaten earlier today → equal set is not another PR.
        #expect(!PRDetector.check(new: t(102.5, 1), baseline: baseline, sessionSoFar: [t(102.5, 1)]).contains(.heaviestWeight))
    }

    @Test func e1RM() {
        #expect(PRDetector.check(new: t(100, 7), baseline: baseline, sessionSoFar: []).contains(.bestE1RM))  // 123.3
        #expect(!PRDetector.check(new: t(100, 6), baseline: baseline, sessionSoFar: []).contains(.bestE1RM))  // 120
    }

    @Test func repsAtWeight() {
        #expect(PRDetector.check(new: t(80, 11), baseline: baseline, sessionSoFar: []).contains(.bestRepsAtWeight))
        #expect(!PRDetector.check(new: t(80, 10), baseline: baseline, sessionSoFar: []).contains(.bestRepsAtWeight))
        // Never lifted 90 before → no prior value → no PR.
        #expect(!PRDetector.check(new: t(90, 5), baseline: baseline, sessionSoFar: []).contains(.bestRepsAtWeight))
    }

    @Test func sessionVolumeFiresOnceWhenCrossed() {
        let earlier = [t(80, 10), t(80, 1)]  // 880
        #expect(PRDetector.check(new: t(80, 2), baseline: baseline, sessionSoFar: earlier).contains(.bestSessionVolume))  // 1040
        #expect(!PRDetector.check(new: t(80, 1), baseline: baseline, sessionSoFar: earlier).contains(.bestSessionVolume))  // 960
        #expect(!PRDetector.check(new: t(80, 1), baseline: baseline, sessionSoFar: earlier + [t(80, 2)]).contains(.bestSessionVolume))
    }

    @Test func ignoresOtherExercisesAndEmptyBaseline() {
        let other = set(500, 10, session: today, exercise: squat)
        #expect(PRDetector.check(new: t(102.5, 1), baseline: baseline, sessionSoFar: [other]).contains(.heaviestWeight))
        #expect(PRDetector.check(new: t(100, 5), baseline: PRBaseline(), sessionSoFar: []).isEmpty)
    }
}

@Suite struct UnitTests {
    @Test func weight() {
        #expect(WeightUnit.lb.toKg(1) == 0.45359237)
        #expect(abs(WeightUnit.lb.fromKg(100) - 220.462262) < 1e-6)
        #expect(WeightUnit.kg.fromKg(80) == 80)
        #expect(abs(WeightUnit.lb.toKg(WeightUnit.lb.fromKg(72.5)) - 72.5) < 1e-9)
    }

    @Test func distance() {
        #expect(DistanceUnit.km.fromMeters(5000) == 5)
        #expect(DistanceUnit.mi.toMeters(1) == 1609.344)
        #expect(DistanceUnit.km.toMeters(1.5) == 1500)
    }

    @Test func paceAndSpeed() {
        #expect(DistanceUnit.km.pace(distanceMeters: 5000, durationSeconds: 1500) == 300)
        #expect(DistanceUnit.mi.pace(distanceMeters: 1609.344, durationSeconds: 480) == 480)
        #expect(DistanceUnit.km.speed(distanceMeters: 10000, durationSeconds: 3600) == 10)
        #expect(abs(DistanceUnit.mi.speed(distanceMeters: 16093.44, durationSeconds: 3600)! - 10) < 1e-9)
        #expect(DistanceUnit.km.pace(distanceMeters: 0, durationSeconds: 60) == nil)
        #expect(DistanceUnit.km.speed(distanceMeters: 100, durationSeconds: 0) == nil)
    }
}

@Suite struct StatsTests {
    @Test func compareSessions() {
        let c = Compare.compare(current: [set(100, 5), set(100, 6), set(90, 10)], previous: [set(95, 8)])
        #expect(c.current.topSet?.reps == 6)  // tie on weight → more reps
        #expect(c.volumeDelta == 2000 - 760)
        #expect(c.topSetWeightDelta == 5)
        #expect(c.topSetRepsDelta == -2)
        #expect(c.e1RMDelta == 120 - 95 * (1 + 8.0 / 30))
        #expect(Compare.compare(current: [], previous: [set(95, 8)]).e1RMDelta == nil)
    }

    @Test func counts() {
        let dates = ["2026-11-17", "2026-11-23", "2026-11-24", "2026-12-01"].map(day)
        #expect(WorkoutCounts.total(dates) == 4)
        #expect(WorkoutCounts.perWeek(dates, calendar: utc).values.sorted() == [1, 1, 2])
        #expect(WorkoutCounts.perMonth(dates, calendar: utc) == [
            try! Date("2026-11-01T00:00:00Z", strategy: .iso8601): 3,
            try! Date("2026-12-01T00:00:00Z", strategy: .iso8601): 1,
        ])
    }

    @Test func movingAverageWithGaps() {
        typealias P = MovingAverage.Point
        let entries = [P(date: day("2026-11-01"), value: 80), P(date: day("2026-11-01"), value: 82),  // daily mean 81
                       P(date: day("2026-11-03"), value: 79),
                       P(date: day("2026-11-07"), value: 78),  // window 1–7: 81, 79, 78
                       P(date: day("2026-11-08"), value: 77),  // window 2–8: 79, 78, 77 (1 Nov drops out)
                       P(date: day("2026-11-20"), value: 75)]  // alone after a long gap
        let ma = MovingAverage.sevenDay(entries: entries.shuffled(), calendar: utc)
        #expect(ma.map(\.value) == [81, 80, (81 + 79 + 78) / 3.0, 78, 75])
        #expect(ma.first?.date == utc.startOfDay(for: day("2026-11-01")))
    }
}
