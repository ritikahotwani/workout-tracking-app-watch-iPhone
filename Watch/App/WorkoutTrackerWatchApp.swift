import SwiftData
import SwiftUI
import WorkoutCore

@main
struct WorkoutTrackerWatchApp: App {
    let container: ModelContainer

    init() {
        do { container = try makeModelContainer() } catch { fatalError("ModelContainer: \(error)") }
        let context = container.mainContext
        do { try ExerciseLibrary.seedIfNeeded(context) } catch { print("Seeding exercises failed: \(error)") }
        LiveSession.closeAbandoned(in: context)
    }

    var body: some Scene {
        WindowGroup {
            StartView()
        }
        .modelContainer(container)
    }
}
