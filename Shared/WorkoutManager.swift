import Foundation
import HealthKit
import Observation
import WorkoutCore

/// Thin wrapper around one HKWorkoutSession + HKLiveWorkoutBuilder (PLAN §4).
/// Shared by the watch and iPhone apps (HKWorkoutSession runs on iOS 26).
/// Every call is best effort: logging must keep working when Health is unavailable or denied.
@Observable @MainActor
final class WorkoutManager: NSObject {
    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var startDate: Date?

    private(set) var isPaused = false
    private(set) var heartRate: Double?
    private(set) var activeCalories: Double?

    struct Summary {
        var workoutID: UUID?
        var averageHeartRate: Double?
        var activeCalories: Double?
        var elapsed: TimeInterval
    }

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let share: Set<HKSampleType> = [.workoutType()]
        let read: Set<HKObjectType> = [
            .workoutType(), HKQuantityType(.heartRate), HKQuantityType(.activeEnergyBurned),
        ]
        try await store.requestAuthorization(toShare: share, read: read)
    }

    /// Starts a strength session. Cardio exercises become activities inside it (`beginCardio`).
    func start(at date: Date) async throws {
        let config = HKWorkoutConfiguration()
        config.activityType = .traditionalStrengthTraining
        config.locationType = .indoor
        let session = try HKWorkoutSession(healthStore: store, configuration: config)
        let builder = session.associatedWorkoutBuilder()
        builder.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: config)
        session.delegate = self
        builder.delegate = self
        session.startActivity(with: date)
        do {
            try await builder.beginCollection(at: date)
        } catch {
            session.end()
            throw error
        }
        // Only keep a session that is collecting, so `elapsed` never reads a dead builder.
        self.session = session
        self.builder = builder
    }

    /// Wall-clock origin for `elapsed` until (or unless) Health collection starts.
    func setStart(_ date: Date) { startDate = date }

    func pause() {
        isPaused = true
        session?.pause()
    }

    func resume() {
        isPaused = false
        session?.resume()
    }

    /// Active (unpaused) time. Falls back to wall clock without a Health session.
    func elapsed(at date: Date) -> TimeInterval {
        if let builder { return builder.elapsedTime(at: date) }
        return startDate.map { date.timeIntervalSince($0) } ?? 0
    }

    func beginCardio(_ activity: CardioActivity, at date: Date) {
        let config = HKWorkoutConfiguration()
        config.activityType = activity.hkType
        config.locationType = .indoor  // ponytail: outdoor + GPS route arrive in Phase 8
        session?.beginNewActivity(configuration: config, date: date, metadata: nil)
    }

    func endCardio(at date: Date) {
        session?.endCurrentActivity(on: date)
    }

    /// Ends and saves the workout to Health.
    func end(at date: Date) async -> Summary {
        let elapsed = elapsed(at: date)
        guard let session, let builder else { return Summary(elapsed: elapsed) }
        session.end()
        var workout: HKWorkout?
        do {
            try await builder.endCollection(at: date)
            workout = try await builder.finishWorkout()
        } catch {
            print("WorkoutManager.end: \(error)")
        }
        let summary = Summary(
            workoutID: workout?.uuid,
            averageHeartRate: builder.statistics(for: HKQuantityType(.heartRate))?
                .averageQuantity()?.doubleValue(for: Self.bpm),
            activeCalories: builder.statistics(for: HKQuantityType(.activeEnergyBurned))?
                .sumQuantity()?.doubleValue(for: .kilocalorie()),
            elapsed: elapsed)
        self.session = nil
        self.builder = nil
        return summary
    }

    nonisolated private static let bpm = HKUnit.count().unitDivided(by: .minute())
}

extension WorkoutManager: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState, date: Date) {
        let paused = toState == .paused
        Task { @MainActor in self.isPaused = paused }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: any Error) {
        print("HKWorkoutSession failed: \(error)")
    }
}

extension WorkoutManager: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        let hr = workoutBuilder.statistics(for: HKQuantityType(.heartRate))?
            .mostRecentQuantity()?.doubleValue(for: Self.bpm)
        let kcal = workoutBuilder.statistics(for: HKQuantityType(.activeEnergyBurned))?
            .sumQuantity()?.doubleValue(for: .kilocalorie())
        Task { @MainActor in
            if let hr { self.heartRate = hr }
            if let kcal { self.activeCalories = kcal }
        }
    }
}

extension CardioActivity {
    var hkType: HKWorkoutActivityType {
        switch self {
        case .running: .running
        case .walking: .walking
        case .cycling: .cycling
        case .rowing: .rowing
        case .elliptical: .elliptical
        case .stairs: .stairClimbing
        case .other: .mixedCardio
        }
    }
}
