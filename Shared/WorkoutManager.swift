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
    /// Fallback for `elapsed` without a Health session; tracks pauses itself.
    private var wallClock: PauseClock?
    /// Outdoor activity's Health distance type and the workout total when it began.
    private var cardioDistanceType: HKQuantityType?
    private var cardioDistanceStart = 0.0

    private(set) var isPaused = false
    private(set) var heartRate: Double?
    private(set) var activeCalories: Double?
    /// Meters Health measured during the running outdoor activity; nil until it reports any.
    private(set) var cardioDistance: Double?

    struct Summary {
        var workoutID: UUID?
        var averageHeartRate: Double?
        var activeCalories: Double?
        var elapsed: TimeInterval
    }

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let distances: Set<HKSampleType> = Set(CardioActivity.allCases.compactMap(\.distanceType).map { HKQuantityType($0) })
        let share: Set<HKSampleType> = distances.union([.workoutType(), HKSeriesType.workoutRoute()])
        let read: Set<HKObjectType> = Set(distances).union([
            .workoutType(), HKQuantityType(.heartRate), HKQuantityType(.activeEnergyBurned),
        ])
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
    func setStart(_ date: Date) { wallClock = PauseClock(start: date) }

    func pause() {
        isPaused = true
        session?.pause()
        wallClock?.pause(at: .now)
    }

    func resume() {
        isPaused = false
        session?.resume()
        wallClock?.resume(at: .now)
    }

    /// Active (unpaused) time. Falls back to wall clock minus pauses without a Health session.
    func elapsed(at date: Date) -> TimeInterval {
        if let builder { return builder.elapsedTime(at: date) }
        return wallClock?.elapsed(at: date) ?? 0
    }

    /// Re-attaches the Health workout left running by a crash, with its builder and delegates.
    /// False when there is none to recover.
    func recover() async throws -> Bool {
        guard HKHealthStore.isHealthDataAvailable(), let session = try await store.recoverActiveWorkoutSession() else {
            return false
        }
        let builder = session.associatedWorkoutBuilder()
        builder.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: session.workoutConfiguration)
        session.delegate = self
        builder.delegate = self
        // A cardio activity running at the crash isn't restored in the UI; end it so the next one can begin.
        if session.currentActivity.workoutConfiguration.activityType != session.workoutConfiguration.activityType {
            session.endCurrentActivity(on: .now)
        }
        self.session = session
        self.builder = builder
        isPaused = session.state == .paused
        return true
    }

    /// Starts a cardio activity inside the session. Outdoors Health measures distance live;
    /// indoors its estimate is switched off so the manual distance (`addDistance`) is the only one.
    func beginCardio(_ activity: CardioActivity, outdoor: Bool, at date: Date) {
        let config = HKWorkoutConfiguration()
        config.activityType = activity.hkType
        config.locationType = outdoor ? .outdoor : .indoor
        session?.beginNewActivity(configuration: config, date: date, metadata: nil)
        cardioDistance = nil
        cardioDistanceType = nil
        guard let id = activity.distanceType, let source = builder?.dataSource else { return }
        let type = HKQuantityType(id)
        if outdoor {
            source.enableCollection(for: type, predicate: nil)
            cardioDistanceType = type
            cardioDistanceStart = distanceTotal(type) ?? 0
        } else {
            source.disableCollection(for: type)
        }
    }

    func endCardio(at date: Date) {
        session?.endCurrentActivity(on: date)
        cardioDistanceType = nil
        cardioDistance = nil
    }

    /// Manual (indoor) distance as a Health sample over the activity's time range.
    func addDistance(_ meters: Double, activity: CardioActivity, from start: Date, to end: Date) {
        guard let builder, meters > 0, let id = activity.distanceType, end > start else { return }
        let sample = HKQuantitySample(type: HKQuantityType(id), quantity: HKQuantity(unit: .meter(), doubleValue: meters),
                                      start: start, end: end)
        builder.add([sample]) { _, error in
            if let error { print("WorkoutManager.addDistance: \(error)") }
        }
    }

    /// The workout's GPS route; Health attaches it to the workout when the builder finishes.
    var routeBuilder: HKWorkoutRouteBuilder? {
        builder?.seriesBuilder(for: .workoutRoute()) as? HKWorkoutRouteBuilder
    }

    private func distanceTotal(_ type: HKQuantityType) -> Double? {
        builder?.statistics(for: type)?.sumQuantity()?.doubleValue(for: .meter())
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
            if let type = self.cardioDistanceType, let total = self.distanceTotal(type) {
                self.cardioDistance = max(0, total - self.cardioDistanceStart)
            }
        }
    }
}
