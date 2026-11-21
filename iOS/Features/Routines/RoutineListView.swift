import SwiftData
import SwiftUI
import WorkoutCore

struct RoutineListView: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<Routine> { $0.deletedAt == nil }, sort: \Routine.sortOrder) private var routines: [Routine]
    @Query(filter: #Predicate<RoutineExercise> { $0.deletedAt == nil }) private var items: [RoutineExercise]

    @State private var isNaming = false
    @State private var renaming: Routine?
    @State private var draftName = ""

    var body: some View {
        List {
            ForEach(routines) { routine in
                NavigationLink(value: routine) {
                    let count = items.count { $0.routineID == routine.id }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(routine.name)
                        Text("^[\(count) exercise](inflect: true)").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                .swipeActions(edge: .leading) {
                    Button("Rename", systemImage: "pencil") { startNaming(routine) }
                }
                .contextMenu {
                    Button("Rename", systemImage: "pencil") { startNaming(routine) }
                }
            }
            .onDelete(perform: delete)
            .onMove(perform: move)
        }
        .overlay {
            if routines.isEmpty {
                ContentUnavailableView("No Routines", systemImage: "list.bullet.rectangle",
                                       description: Text("Tap + to create one, like Chest Day."))
            }
        }
        .navigationDestination(for: Routine.self) { RoutineEditor(routine: $0) }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { EditButton() }
            ToolbarItem(placement: .primaryAction) {
                Button("New Routine", systemImage: "plus") { startNaming(nil) }
            }
        }
        .alert(renaming == nil ? "New Routine" : "Rename Routine", isPresented: $isNaming) {
            TextField("Name", text: $draftName)
            Button("Cancel", role: .cancel) {}
            Button(renaming == nil ? "Create" : "Save", action: commitName)
        }
    }

    private func startNaming(_ routine: Routine?) {
        renaming = routine
        draftName = routine?.name ?? ""
        isNaming = true
    }

    private func commitName() {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if let r = renaming {
            guard r.name != name else { return }
            r.name = name
            r.touch()
        } else {
            context.insert(Routine(name: name, sortOrder: (routines.last?.sortOrder ?? -1) + 1))
        }
    }

    private func delete(_ offsets: IndexSet) {
        for r in offsets.map({ routines[$0] }) {
            r.markDeleted()
            for item in items where item.routineID == r.id { item.markDeleted() }
        }
    }

    private func move(_ source: IndexSet, _ destination: Int) {
        var ordered = routines
        ordered.move(fromOffsets: source, toOffset: destination)
        for (i, r) in ordered.enumerated() where r.sortOrder != i {
            r.sortOrder = i
            r.touch()
        }
    }
}
