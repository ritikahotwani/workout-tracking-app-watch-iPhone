import SwiftData
import SwiftUI
import WorkoutCore

/// Workout tab: start from a routine or empty, then history below.
struct WorkoutTab: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<Routine> { $0.deletedAt == nil }, sort: \Routine.sortOrder) private var routines: [Routine]
    @State private var live: LiveSession?

    var body: some View {
        NavigationStack {
            List {
                Section("Start") {
                    ForEach(routines) { routine in
                        Button(routine.name, systemImage: "play.fill") { begin(routine) }
                    }
                    Button("Empty Workout", systemImage: "plus") { begin(nil) }
                }
                HistorySection()
            }
            .navigationTitle("Workout")
            .navigationDestination(for: WorkoutSession.self) { SessionDetailView(session: $0) }
        }
        .fullScreenCover(item: $live) { PhoneSessionView(live: $0) { live = nil } }
    }

    private func begin(_ routine: Routine?) {
        let session = LiveSession(routine: routine, context: context)
        live = session
        // UI tests skip Health so no permission sheet blocks them.
        if !DemoData.isUITesting { Task { await session.start() } }
    }
}

extension LiveSession: Identifiable {
    nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }
}
