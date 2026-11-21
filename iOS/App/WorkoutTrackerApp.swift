import SwiftData
import SwiftUI
import WorkoutCore

@main
struct WorkoutTrackerApp: App {
    let container: ModelContainer
    let backup: BackupController
    let watchSync: PhoneSync
    @Environment(\.scenePhase) private var scenePhase

    init() {
        do { container = try makeModelContainer(inMemory: DemoData.isEnabled) } catch { fatalError("ModelContainer: \(error)") }
        do { try ExerciseLibrary.seedIfNeeded(container.mainContext) } catch { print("Exercise seeding failed: \(error)") }
        if DemoData.isEnabled { do { try DemoData.seed(container.mainContext) } catch { print("Demo seed failed: \(error)") } }
        LiveSession.closeAbandoned(in: container.mainContext)
        backup = BackupController(container: container)
        watchSync = PhoneSync(container: container)
        watchSync.onMerge = { [backup] in backup.syncSoon() }
        watchSync.activate()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
                .environment(backup)
        }
        .modelContainer(container)
        .onChange(of: scenePhase, initial: true) { if scenePhase == .active { backup.syncNow() } }  // launch + foreground
        .onChange(of: scenePhase) { if scenePhase != .inactive { watchSync.sendContext() } }  // after library/routine edits
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            Tab("Workout", systemImage: "figure.strengthtraining.traditional") { WorkoutTab() }
            Tab("Progress", systemImage: "chart.line.uptrend.xyaxis") { StatsView() }
            Tab("Body", systemImage: "scalemass") { BodyWeightView() }
            Tab("Library", systemImage: "books.vertical") { LibraryView() }
            Tab("Settings", systemImage: "gearshape") { SettingsView() }
        }
    }
}

#Preview {
    let container = try! makeModelContainer(inMemory: true)
    RootView().preferredColorScheme(.dark).modelContainer(container).environment(BackupController(container: container))
}
