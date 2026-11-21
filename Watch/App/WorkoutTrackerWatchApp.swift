import SwiftData
import SwiftUI
import WatchKit
import WorkoutCore

@main
struct WorkoutTrackerWatchApp: App {
    let container: ModelContainer
    let sync: WatchSync
    @WKApplicationDelegateAdaptor private var delegate: WatchAppDelegate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        do { container = try makeModelContainer() } catch { fatalError("ModelContainer: \(error)") }
        let context = container.mainContext
        do { try ExerciseLibrary.seedIfNeeded(context) } catch { print("Seeding exercises failed: \(error)") }
        sync = WatchSync(container: container)
        sync.activate()
    }

    var body: some Scene {
        WindowGroup {
            StartView()
        }
        .modelContainer(container)
        .environment(sync)
        .environment(delegate)
        .onChange(of: scenePhase) { if scenePhase == .active { sync.flush() } }
    }
}

/// watchOS relaunches the app after a crash mid-workout and calls `handleActiveWorkoutRecovery`;
/// `StartView` then re-attaches the Health workout (`LiveSession.recover`).
@Observable
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    private(set) var recoveryRequests = 0

    func handleActiveWorkoutRecovery() { recoveryRequests += 1 }
}
