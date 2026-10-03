import Photos
import ShoeboxCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    enum Part { case status, storage, schedule, content, history }

    /// The "settings" demo scenario starts at the lower sections so the
    /// screenshot shows them without scrolling.
    private func show(_ part: Part) -> Bool {
        guard AppEnvironment.demoScenario == "settings" else { return true }
        return [.schedule, .content, .history].contains(part)
    }

    var body: some View {
        NavigationStack {
            Form {
                if show(.status) { StatusSection() }
                if show(.storage) { StorageSection() }
                if show(.schedule) { ScheduleSection() }
                if show(.content) { ContentSection() }
                if show(.history) { HistorySection() }
            }
            .navigationTitle("Shoebox")
            .disabled(model.busy)
            .refreshable { model.refreshState() }
            .alert("Shoebox", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.message ?? "")
            }
        }
    }
}

private struct StatusSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Section("Status") {
            if model.photoAccess != .authorized || !model.backgroundEnabled {
                Button("Turn on background backup") {
                    Task { await model.enableBackgroundBackup() }
                }
            } else {
                Label("Background backup is on", systemImage: "checkmark.circle")
            }

            if let active = model.state.active {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Backing up \(active.id.date.formatted(date: .abbreviated, time: .shortened))")
                    ProgressView(value: Double(min(active.cursor.asset, active.totalAssets)),
                                 total: Double(max(active.totalAssets, 1)))
                    Text("\(active.uploadedCount) files uploaded · \(active.inFlight.count) in progress · \(active.failed.count) failed")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if let last = model.state.lastCompleted {
                LabeledContent("Last backup", value: last.completedAt.formatted(date: .abbreviated, time: .shortened))
                if let next = model.nextDue {
                    LabeledContent("Next backup", value: next.formatted(date: .abbreviated, time: .omitted))
                }
            } else {
                Text("No backups yet").foregroundStyle(.secondary)
            }

            if let error = model.state.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            Button("Back up now") {
                Task { await model.backUpNow() }
            }
            .disabled(model.state.active != nil)
        }
    }
}

private struct StorageSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Section {
            TextField("Endpoint (https://…)", text: $model.endpoint)
                .textInputAutocapitalization(.never).keyboardType(.URL).autocorrectionDisabled()
            TextField("Region (auto for R2)", text: $model.region)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("Bucket", text: $model.bucket)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("Folder prefix (optional)", text: $model.prefix)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Toggle("Path-style URLs", isOn: $model.usePathStyle)
            TextField("Access key ID", text: $model.accessKeyID)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            SecureField("Secret access key", text: $model.secretAccessKey)
            HStack {
                Button("Save") { model.save() }
                Spacer()
                Button("Test connection") { Task { await model.testConnection() } }
            }
        } header: {
            Text("Storage (S3 compatible)")
        } footer: {
            Text("This build uploads only under \(model.uploadURLBase).")
        }
    }
}

private struct ScheduleSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Section {
            Stepper("Every \(model.intervalDays) day\(model.intervalDays == 1 ? "" : "s")",
                    value: $model.intervalDays, in: BackupSchedule.dayRange)
            Stepper("Keep latest \(model.keepLatest)", value: $model.keepLatest, in: RetentionPolicy.keepRange)
        } header: {
            Text("Schedule")
        } footer: {
            Text("Each backup is a full copy of the library. Older backups beyond the limit are deleted. iOS decides the exact time, usually while charging on Wi-Fi. Tap Save after changing.")
        }
    }
}

private struct ContentSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Section("Include") {
            Toggle("Videos", isOn: $model.includeVideos)
            Toggle("Live Photo motion", isOn: $model.includeLivePhotoVideos)
            Toggle("Edited versions", isOn: $model.includeEdits)
        }
    }
}

private struct HistorySection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if !model.state.history.isEmpty {
            Section("History") {
                ForEach(model.state.history, id: \.id) { item in
                    VStack(alignment: .leading) {
                        Text(item.startedAt.formatted(date: .abbreviated, time: .shortened))
                        Text("\(item.uploadedFiles) files · \(item.failedFiles) failed · \(item.skippedAssets) skipped")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
