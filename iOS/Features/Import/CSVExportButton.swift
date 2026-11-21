import SwiftData
import SwiftUI
import UIKit
import WorkoutCore

/// Settings row: writes workouts.csv + body-weight.csv to a temp folder and opens the share sheet.
struct CSVExportButton: View {
    @Environment(\.modelContext) private var context
    @State private var files: Files?
    @State private var errorMessage: String?

    private struct Files: Identifiable {
        let id = UUID()
        let urls: [URL]
    }

    var body: some View {
        Button("Export CSV", systemImage: "square.and.arrow.up", action: export)
            .accessibilityHint("Shares your workouts and body weight as two CSV files.")
            .sheet(item: $files) { ShareSheet(items: $0.urls).ignoresSafeArea() }
            .alert("Export failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") {}
            } message: { Text(errorMessage ?? "") }
    }

    private func export() {
        do {
            let dir = FileManager.default.temporaryDirectory.appending(path: "Export", directoryHint: .isDirectory)
            try? FileManager.default.removeItem(at: dir)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let day = Date.now.formatted(.iso8601.year().month().day())
            let workouts = dir.appending(path: "workouts-\(day).csv")
            let weights = dir.appending(path: "body-weight-\(day).csv")
            try CSVExport.workouts(in: context).write(to: workouts, atomically: true, encoding: .utf8)
            try CSVExport.bodyWeights(in: context).write(to: weights, atomically: true, encoding: .utf8)
            files = Files(urls: [workouts, weights])
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
