import SwiftData
import SwiftUI
import WorkoutCore

@main
struct WorkoutTrackerWatchApp: App {
    let container: ModelContainer

    init() {
        do { container = try makeModelContainer() } catch { fatalError("ModelContainer: \(error)") }
    }

    var body: some Scene {
        WindowGroup {
            StartView()
        }
        .modelContainer(container)
    }
}

struct StartView: View {
    var body: some View {
        NavigationStack {
            List {
                Button("Empty Workout", systemImage: "plus") {}
                Button("Log Weight", systemImage: "scalemass") {}
            }
            .navigationTitle("Workout")
        }
    }
}

#Preview {
    StartView()
}
