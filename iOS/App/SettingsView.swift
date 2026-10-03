import ShoeboxCore
import SwiftUI

/// Settings save as you change them. Problems show under the section that
/// has them; nothing pops up.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            StorageSection()
            ScheduleSection()
            IncludeSection()
            BackgroundSection()
            Section {
                NavigationLink(value: Route.help) {
                    Label("How Shoebox works", systemImage: "questionmark.circle")
                }
            } footer: {
                Text("Changes are saved as you make them.")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
    }
}

/// Title with one grey sentence under it.
struct RowLabel: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail).font(.footnote).foregroundStyle(.secondary)
        }
    }
}

/// Inline problem: icon + text, so it doesn't rely on colour.
struct ProblemText: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.circle")
            .foregroundStyle(.red)
    }
}

private struct StorageSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("Endpoint")
                TextField("https://<account>.r2.cloudflarestorage.com", text: $model.endpoint)
                    .keyboardType(.URL)
                    .foregroundStyle(.secondary)
                    .plain()
            }
            field("Region", prompt: "auto", text: $model.region)
            field("Bucket", prompt: "photos", text: $model.bucket)
            field("Folder", prompt: "Optional", text: $model.prefix)
            Toggle(isOn: $model.usePathStyle) {
                RowLabel(title: "Path-style URLs", detail: "Keep on for R2 and MinIO.")
            }
            field("Access key", prompt: "Key ID", text: $model.accessKeyID)
            LabeledContent("Secret") {
                SecureField("Secret access key", text: $model.secretAccessKey)
                    .multilineTextAlignment(.trailing)
            }
            ConnectionRow()
        } header: {
            Text("Storage")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.visibleProblems, id: \.self) { ProblemText(text: $0) }
                Text("Works with Cloudflare R2, AWS S3, MinIO and other S3-compatible storage. This build uploads only under \(model.uploadURLBase).")
            }
        }
    }

    private func field(_ title: LocalizedStringKey, prompt: LocalizedStringKey, text: Binding<String>) -> some View {
        LabeledContent(title) {
            TextField(prompt, text: text)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.secondary)
                .plain()
        }
    }
}

private struct ConnectionRow: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Button {
            Task { await model.testConnection() }
        } label: {
            HStack {
                Text("Test connection")
                Spacer()
                switch model.connection {
                case .idle:
                    EmptyView()
                case .checking:
                    ProgressView()
                case .ok:
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .failed:
                    Label("Failed", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
        .disabled(model.connection == .checking)
        if case .failed(let reason) = model.connection {
            Text(reason)
                .font(.footnote)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }
}

private struct ScheduleSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Section {
            Stepper(value: $model.intervalDays, in: BackupSchedule.dayRange) {
                LabeledContent("Back up every") {
                    Text("^[\(model.intervalDays) day](inflect: true)").monospacedDigit()
                }
            }
            Stepper(value: $model.keepLatest, in: RetentionPolicy.keepRange) {
                LabeledContent("Keep") {
                    Text("^[\(model.keepLatest) backup](inflect: true)").monospacedDigit()
                }
            }
        } header: {
            Text("Schedule")
        } footer: {
            Text("Each backup is a full copy of your library. iOS picks the exact time, usually while charging on Wi-Fi.")
        }
        .sensoryFeedback(.selection, trigger: model.intervalDays)
        .sensoryFeedback(.selection, trigger: model.keepLatest)
    }
}

private struct IncludeSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Section("Include") {
            Toggle(isOn: $model.includeVideos) {
                RowLabel(title: "Videos", detail: "Movies from the camera and other apps.")
            }
            Toggle(isOn: $model.includeLivePhotoVideos) {
                RowLabel(title: "Live Photo motion", detail: "The short video in each Live Photo.")
            }
            Toggle(isOn: $model.includeEdits) {
                RowLabel(title: "Edited versions", detail: "Your edits, next to the original.")
            }
        }
    }
}

private struct BackgroundSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { model.backgroundEnabled },
                                 set: { on in Task { await model.setBackgroundBackup(on) } })) {
                RowLabel(title: "Background backup", detail: "Uploads continue when Shoebox is closed or the phone is locked.")
            }
        } header: {
            Text("Background")
        } footer: {
            if let problem = model.backgroundProblem {
                ProblemText(text: problem)
            }
        }
    }
}

private extension View {
    /// Plain text entry for codes, keys and URLs.
    func plain() -> some View {
        textInputAutocapitalization(.never)
            .autocorrectionDisabled()
    }
}
