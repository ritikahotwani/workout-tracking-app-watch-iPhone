import SwiftData
import SwiftUI
import WorkoutCore

@main
struct WorkoutTrackerApp: App {
    let container: ModelContainer

    init() {
        do { container = try makeModelContainer() } catch { fatalError("ModelContainer: \(error)") }
        do { try ExerciseLibrary.seedIfNeeded(container.mainContext) } catch { print("Exercise seeding failed: \(error)") }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
        }
        .modelContainer(container)
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            Tab("Workout", systemImage: "figure.strengthtraining.traditional") { Placeholder(title: "Workout") }
            Tab("Progress", systemImage: "chart.line.uptrend.xyaxis") { Placeholder(title: "Progress") }
            Tab("Body", systemImage: "scalemass") { Placeholder(title: "Body") }
            Tab("Library", systemImage: "books.vertical") { LibraryView() }
            Tab("Settings", systemImage: "gearshape") { Placeholder(title: "Settings") }
        }
    }
}

private struct Placeholder: View {
    let title: String

    var body: some View {
        NavigationStack {
            ContentUnavailableView(title, systemImage: "hammer", description: Text("Coming soon"))
                .navigationTitle(title)
        }
    }
}

#Preview {
    RootView().preferredColorScheme(.dark).modelContainer(try! makeModelContainer(inMemory: true))
}
