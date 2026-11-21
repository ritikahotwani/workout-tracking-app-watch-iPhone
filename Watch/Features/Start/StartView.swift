import SwiftData
import SwiftUI
import WorkoutCore

struct StartView: View {
    @Environment(\.modelContext) private var context
    @Environment(WatchSync.self) private var sync
    @Environment(WatchAppDelegate.self) private var delegate
    @Query(filter: #Predicate<Routine> { $0.deletedAt == nil }, sort: \Routine.sortOrder)
    private var routines: [Routine]
    @State private var live: LiveSession?
    @State private var recovering = false

    var body: some View {
        content
            // At launch, and again if watchOS asks after a crash mid-workout.
            .task(id: delegate.recoveryRequests) {
                guard live == nil, !recovering else { return }
                recovering = true
                if let session = await LiveSession.recover(in: context, snapshots: sync.snapshots) { live = session }
                recovering = false
            }
    }

    @ViewBuilder private var content: some View {
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
                .disabled(recovering)
            }
        }
    }

    private func begin(_ routine: Routine?) {
        let session = LiveSession(routine: routine, context: context, snapshots: sync.snapshots)
        live = session
        Task { await session.start() }
    }
}
