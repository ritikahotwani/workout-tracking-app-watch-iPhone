import SwiftData
import SwiftUI
import WorkoutCore

@main
struct WorkoutTrackerWatchApp: App {
    let container: ModelContainer
    let sync: WatchSync
    @Environment(\.scenePhase) private var scenePhase

    init() {
        do { container = try makeModelContainer() } catch { fatalError("ModelContainer: \(error)") }
        let context = container.mainContext
        do { try ExerciseLibrary.seedIfNeeded(context) } catch { print("Seeding exercises failed: \(error)") }
        LiveSession.closeAbandoned(in: context)
        sync = WatchSync(container: container)
        sync.activate()
    }

    var body: some Scene {
        WindowGroup {
            StartView()
        }
        .modelContainer(container)
        .environment(sync)
        .onChange(of: scenePhase) { if scenePhase == .active { sync.flush() } }
    }
}
