import SwiftData
import SwiftUI
import WorkoutCore

struct StartView: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<Routine> { $0.deletedAt == nil }, sort: \Routine.sortOrder)
    private var routines: [Routine]
    @State private var live: LiveSession?

    var body: some View {
        if let live {
            SessionView(live: live) { self.live = nil }
        } else {
            NavigationStack {
                List {
                    ForEach(routines) { routine in
                        Button(routine.name) { begin(routine) }
                    }
                    Button("Empty Workout", systemImage: "plus") { begin(nil) }
                    NavigationLink {
                        Text("Coming soon").foregroundStyle(.secondary)  // Phase 5
                    } label: {
                        Label("Log Weight", systemImage: "scalemass")
                    }
                }
                .navigationTitle("Workout")
            }
        }
    }

    private func begin(_ routine: Routine?) {
        let session = LiveSession(routine: routine, context: context)
        live = session
        Task { await session.start() }
    }
}
