import Foundation
import Testing
@testable import WorkoutCore

@Suite struct PauseClockAndTitleTests {
    @Test func pauseClockExcludesPauses() {
        let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var clock = PauseClock(start: t0)
        clock.pause(at: t0 + 60)
        clock.pause(at: t0 + 70)  // second pause ignored
        #expect(clock.elapsed(at: t0 + 90) == 60)  // still paused
        #expect(clock.pausedSeconds(at: t0 + 90) == 30)
        clock.resume(at: t0 + 120)
        clock.resume(at: t0 + 130)  // second resume ignored
        #expect(clock.elapsed(at: t0 + 180) == 120)
        #expect(clock.pausedSeconds(at: t0 + 180) == 60)
    }

    @Test func titles() {
        let row = Exercise(name: "Row", muscleGroup: .back)
        let pulldown = Exercise(name: "Pulldown", muscleGroup: .back)
        let curl = Exercise(name: "Curl", muscleGroup: .biceps)
        let press = Exercise(name: "Press", muscleGroup: .shoulders)
        let walk = Exercise(name: "Walking", muscleGroup: .cardio, kind: .cardio)
        #expect(SessionTitle.make(routine: "Pull Day", setExercises: [row]) == "Pull Day")
        #expect(SessionTitle.make(routine: nil, setExercises: [walk, walk]) == "Walking")
        #expect(SessionTitle.make(routine: nil, setExercises: [press, curl, row, pulldown, row, curl, walk]) == "Back · Biceps")
        #expect(SessionTitle.make(routine: nil, setExercises: [curl, press]) == "Biceps · Shoulders")  // tie: first logged
        #expect(SessionTitle.make(routine: nil, setExercises: [row, walk]) == "Back")
        #expect(SessionTitle.make(routine: nil, setExercises: []) == "Workout")
    }
}
