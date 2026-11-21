import SwiftUI

/// Library tab: exercises and routines behind a segmented picker.
struct LibraryView: View {
    private enum Section: String, CaseIterable { case exercises = "Exercises", routines = "Routines" }
    @State private var section = Section.exercises

    var body: some View {
        NavigationStack {
            Group {
                switch section {
                case .exercises: ExerciseListView()
                case .routines: RoutineListView()
                }
            }
            .navigationTitle(section.rawValue)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Section", selection: $section) {
                        ForEach(Section.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }
        }
    }
}
