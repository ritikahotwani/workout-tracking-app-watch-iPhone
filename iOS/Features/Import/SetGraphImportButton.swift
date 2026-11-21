import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import WorkoutCore

/// Settings row: pick the SetGraph CSV export(s), preview the plan, then commit and back up.
struct SetGraphImportButton: View {
    @Environment(\.modelContext) private var context
    @Environment(BackupController.self) private var backup
    @State private var showPicker = false
    @State private var isPlanning = false
    @State private var preview: Preview?
    @State private var message: Message?

    private struct Preview: Identifiable {
        let id = UUID()
        let plan: ImportPlan
    }

    private struct Message: Identifiable {
        let id = UUID()
        let title: String
        let body: String
    }

    var body: some View {
        Button {
            showPicker = true
        } label: {
            HStack {
                Label("Import SetGraph CSV", systemImage: "square.and.arrow.down")
                Spacer()
                if isPlanning { ProgressView() }
            }
        }
        .disabled(isPlanning)
        .accessibilityHint("Choose the SetGraph sets export, and optionally the sessions export.")
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.commaSeparatedText],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): plan(urls)
            case .failure(let error): message = Message(title: "Couldn't open files", body: error.localizedDescription)
            }
        }
        .sheet(item: $preview) { item in
            ImportPreviewView(plan: item.plan, onImport: { commit(item.plan) }, onCancel: { preview = nil })
        }
        .alert(message?.title ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } }),
               presenting: message) { _ in
            Button("OK") {}
        } message: { Text($0.body) }
    }

    private func plan(_ urls: [URL]) {
        let existing: SetGraphImport.Existing
        do { existing = try SetGraphImport.Existing(context: context) } catch {
            message = Message(title: "Import failed", body: error.localizedDescription)
            return
        }
        isPlanning = true
        Task {
            let result = await Task.detached { try Self.makePlan(urls: urls, existing: existing) }.result
            isPlanning = false
            switch result {
            case .success(let plan): preview = Preview(plan: plan)
            case .failure(let error): message = Message(title: "Can't import", body: error.localizedDescription)
            }
        }
    }

    private struct PickError: LocalizedError {
        let errorDescription: String?
    }

    /// Reads the picked files (security-scoped), tells sets from sessions by header, and plans the import.
    nonisolated private static func makePlan(urls: [URL], existing: SetGraphImport.Existing) throws -> ImportPlan {
        var files: [SetGraphImport.File: String] = [:]
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let text = try String(contentsOf: url, encoding: .utf8)
            guard let kind = SetGraphImport.detect(text) else {
                throw PickError(errorDescription: "\(url.lastPathComponent) isn't a SetGraph sets or sessions export.")
            }
            guard files[kind] == nil else {
                throw PickError(errorDescription: "Pick only one SetGraph \(kind.rawValue) file.")
            }
            files[kind] = text
        }
        guard let sets = files[.sets] else {
            throw PickError(errorDescription: "Include the SetGraph sets export (Setgraph_Set_Export…csv). The sessions export is optional.")
        }
        return SetGraphImport.plan(setsCSV: sets, sessionsCSV: files[.sessions], existing: existing)
    }

    private func commit(_ plan: ImportPlan) {
        preview = nil
        do {
            try plan.commit(into: context)
            message = Message(title: "Import complete", body: "Added \(plan.sessions.count.formatted()) workouts, \(plan.sets.count.formatted()) sets and \(plan.exercisesCreated.count) new exercises.")
            backup.syncSoon()
        } catch {
            context.rollback()
            message = Message(title: "Import failed", body: "Nothing was imported. \(error.localizedDescription)")
        }
    }
}

/// What the import will add, skip and couldn't read, before anything is written.
struct ImportPreviewView: View {
    let plan: ImportPlan
    let onImport: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    count("Strength workouts", plan.strengthSessions)
                    count("Cardio workouts", plan.cardioSessions)
                    count("Workouts from sets outside a session", plan.syntheticSessions)
                    count("Sets", plan.sets.count)
                    count("Exercises matched", plan.exercisesMatched)
                    count("New exercises", plan.exercisesCreated.count)
                } header: {
                    Text("Will add")
                } footer: {
                    if plan.isEmpty { Text("Nothing new to import.") }
                }

                if !plan.sessionsByType.isEmpty {
                    Section("Workouts by type") {
                        ForEach(plan.sessionsByType.sorted { $0.key < $1.key }, id: \.key) { type, n in
                            count(type == "Synthetic" ? "Grouped loose sets" : type, n)
                        }
                    }
                }

                Section("Skipped") {
                    count("Already imported", plan.alreadyImported)
                    count("Duplicate rows", plan.duplicates.count)
                    if !plan.duplicates.isEmpty { issues("Show duplicate rows", plan.duplicates) }
                }

                if !plan.errors.isEmpty {
                    Section {
                        issues("Show \(plan.errors.count) rows", plan.errors)
                    } header: {
                        Text("Couldn't read")
                    } footer: {
                        Text("These rows won't be imported. Everything else will.")
                    }
                }

                if !plan.exercisesCreated.isEmpty {
                    Section("New exercises") {
                        ForEach(plan.exercisesCreated, id: \.id) { e in
                            LabeledContent(e.name, value: MuscleGroup(rawValue: e.muscleGroup)?.title ?? e.muscleGroup)
                        }
                    }
                }

                if !plan.aliasMerges.isEmpty {
                    Section("Merged spellings") {
                        ForEach(plan.aliasMerges, id: \.from) { m in
                            LabeledContent("\(m.from) → \(m.to)", value: "\(m.rows) sets")
                                .accessibilityLabel("\(m.from) merged into \(m.to), \(m.rows) sets")
                        }
                    }
                }
            }
            .navigationTitle("Import Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import", action: onImport).disabled(plan.isEmpty)
                }
            }
        }
    }

    private func count(_ title: String, _ n: Int) -> some View {
        LabeledContent(title, value: n.formatted())
    }

    private func issues(_ title: String, _ list: [SetGraphImport.Issue]) -> some View {
        DisclosureGroup(title) {
            ForEach(Array(list.enumerated()), id: \.offset) { _, issue in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(issue.file.rawValue).csv, line \(issue.line)").font(.subheadline.monospacedDigit())
                    Text(issue.reason).font(.footnote).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}
