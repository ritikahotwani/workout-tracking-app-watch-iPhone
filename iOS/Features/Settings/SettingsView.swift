import SwiftUI
import WorkoutCore

/// Settings tab (PLAN §6): units, account, backup, and CSV (Phase 7).
struct SettingsView: View {
    @Environment(BackupController.self) private var backup
    @AppStorage("weightUnit") private var weightUnit: WeightUnit = .kg
    @AppStorage("distanceUnit") private var distanceUnit: DistanceUnit = .km
    @State private var confirmSignOut = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Units") {
                    Picker("Weight", selection: $weightUnit) {
                        Text("Kilograms (kg)").tag(WeightUnit.kg)
                        Text("Pounds (lb)").tag(WeightUnit.lb)
                    }
                    Picker("Distance", selection: $distanceUnit) {
                        Text("Kilometers (km)").tag(DistanceUnit.km)
                        Text("Miles (mi)").tag(DistanceUnit.mi)
                    }
                }

                if backup.isConfigured {
                    account
                    backupSection
                } else {
                    Section("Backup") {
                        Text("Backup isn't set up yet. Add your Supabase URL and key to Secrets.xcconfig.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Group {
                        Button("Import SetGraph CSV", systemImage: "square.and.arrow.down") {}
                        Button("Export CSV", systemImage: "square.and.arrow.up") {}
                    }
                    .disabled(true)
                    .foregroundStyle(.secondary)
                    .tint(.secondary)
                } header: {
                    Text("Data")
                } footer: {
                    Text("Coming soon.")
                }
            }
            .navigationTitle("Settings")
        }
    }

    @ViewBuilder private var account: some View {
        Section("Account") {
            if backup.userID != nil {
                Label("Signed in with Apple", systemImage: "person.crop.circle.badge.checkmark")
                Button("Sign Out", role: .destructive) { confirmSignOut = true }
                    .confirmationDialog("Sign out?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                        Button("Sign Out", role: .destructive) { Task { await backup.signOut() } }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Your data stays on this iPhone but stops backing up.")
                    }
            } else {
                AppleSignInButton(backup: backup)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
        }
    }

    @ViewBuilder private var backupSection: some View {
        Section {
            Button {
                backup.syncNow()
            } label: {
                HStack {
                    Label(backup.isRestoring ? "Restoring…" : backup.isSyncing ? "Backing Up…" : "Back Up Now",
                          systemImage: "arrow.clockwise.icloud")
                    Spacer()
                    if backup.isSyncing { ProgressView() }
                }
            }
            .disabled(backup.userID == nil || backup.isSyncing)
            .accessibilityHint(backup.userID == nil ? "Sign in first." : "")

            if let date = backup.lastBackupAt {
                TimelineView(.periodic(from: .now, by: 60)) { _ in
                    LabeledContent("Last backup", value: date.formatted(.relative(presentation: .named, unitsStyle: .wide)))
                }
            }
            if let message = backup.lastErrorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Backup problem: \(message)")
            }
        } header: {
            Text("Backup")
        } footer: {
            Text("Backs up automatically when you open the app, finish a workout, or get back online.")
        }
    }
}
