import SwiftData
import SwiftUI
import WorkoutCore

struct StartView: View {
    @Environment(\.modelContext) private var context
    @Environment(WatchSync.self) private var sync
    @Query(filter: #Predicate<Routine> { $0.deletedAt == nil }, sort: \Routine.sortOrder)
    private var routines: [Routine]
    @State private var live: LiveSession?

    var body: some View {
        if let live {
            SessionView(live: live) {
                self.live = nil
                sync.flush()
            }
        } else {
            NavigationStack {
                List {
                    ForEach(routines) { routine in
                        Button(routine.name) { begin(routine) }
                    }
                    Button("Empty Workout", systemImage: "plus") { begin(nil) }
                    NavigationLink {
                        LogWeightView()
                    } label: {
                        Label("Log Weight", systemImage: "scalemass")
                    }
                }
                .navigationTitle("Workout")
            }
        }
    }

    private func begin(_ routine: Routine?) {
        let session = LiveSession(routine: routine, context: context, snapshots: sync.snapshots)
        live = session
        Task { await session.start() }
    }
}
