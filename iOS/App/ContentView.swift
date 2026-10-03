import ShoeboxCore
import SwiftUI

enum Route: Hashable {
    case settings, help
}

/// Main screen: what the backup is doing now, and what it did before.
/// Settings are one tap away in the navigation bar; the main action sits in
/// thumb reach at the bottom.
struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var path: [Route] = ContentView.initialPath

    /// Demo scenarios can open a deeper screen for the gallery.
    private static var initialPath: [Route] {
        switch AppEnvironment.demoScenario {
        case "settings": return [.settings]
        case "help": return [.settings, .help]
        default: return []
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                StatusCard()
                HistorySection()
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Shoebox")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: Route.settings) {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .refreshable { model.refreshState() }
            .safeAreaInset(edge: .bottom) { BackUpButton() }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .settings: SettingsView()
                case .help: HelpView()
                }
            }
        }
        .sensoryFeedback(trigger: model.haptic) { _, event in
            event.kind == .success ? .success : .warning
        }
    }
}

// MARK: Status

private struct StatusCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Section {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: symbol)
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tint)
                    .frame(width: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                    if let active = model.state.active {
                        ProgressBlock(active: active).padding(.top, 6)
                    }
                }
            }
            .padding(.vertical, 6)
            .accessibilityElement(children: .combine)

            if model.isConfigured && !model.backgroundEnabled {
                Button {
                    Task { await model.setBackgroundBackup(true) }
                } label: {
                    Label("Turn on background backup", systemImage: "moon.zzz")
                }
            }
            if !model.isConfigured {
                NavigationLink(value: Route.settings) {
                    Label("Add storage", systemImage: "externaldrive.badge.plus")
                }
            }
            if model.state.active == nil, model.isConfigured, let next = model.nextDue {
                LabeledContent("Next backup", value: next.formatted(date: .abbreviated, time: .omitted))
            }
        }
    }

    private enum Kind { case notSetUp, off, running, attention, upToDate, waiting }

    private var kind: Kind {
        if !model.isConfigured { return .notSetUp }
        if model.state.active != nil { return .running }
        if model.state.lastError != nil { return .attention }
        if !model.backgroundEnabled { return .off }
        return model.state.lastCompleted == nil ? .waiting : .upToDate
    }

    private var symbol: String {
        switch kind {
        case .notSetUp: return "externaldrive.badge.questionmark"
        case .off: return "pause.circle"
        case .running: return "arrow.triangle.2.circlepath.circle"
        case .attention: return "exclamationmark.triangle"
        case .upToDate: return "checkmark.circle"
        case .waiting: return "clock"
        }
    }

    private var tint: Color {
        switch kind {
        case .running: return .accentColor
        case .attention: return .orange
        case .upToDate: return .green
        default: return .secondary
        }
    }

    private var title: LocalizedStringKey {
        switch kind {
        case .notSetUp: return "Not set up"
        case .off: return "Background backup is off"
        case .running: return "Backing up"
        case .attention: return "Needs attention"
        case .upToDate: return "Up to date"
        case .waiting: return "Waiting for the first backup"
        }
    }

    private var detail: String {
        switch kind {
        case .notSetUp:
            return String(localized: "Add your S3 or R2 storage to start.")
        case .off:
            return String(localized: "Turn it on to back up while Shoebox is closed.")
        case .running:
            let started = model.state.active!.startedAt.formatted(date: .abbreviated, time: .shortened)
            return String(localized: "Started \(started). Continues in the background.")
        case .attention:
            return model.state.lastError ?? ""
        case .upToDate:
            let last = model.state.lastCompleted!.completedAt.formatted(date: .abbreviated, time: .shortened)
            return String(localized: "Last backup \(last).")
        case .waiting:
            return String(localized: "iOS starts it soon, usually while charging on Wi-Fi.")
        }
    }
}

private struct ProgressBlock: View {
    let active: ActiveSnapshot

    private var fraction: Double {
        Double(min(active.cursor.asset, active.totalAssets)) / Double(max(active.totalAssets, 1))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: fraction)
                .accessibilityLabel("Backup progress")
                .accessibilityValue(fraction.formatted(.percent.precision(.fractionLength(0))))
            HStack {
                Text("\(active.uploadedCount.formatted()) files uploaded")
                Spacer()
                Text(fraction.formatted(.percent.precision(.fractionLength(0))))
            }
            .font(.footnote)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            if !active.failed.isEmpty {
                Label("\(active.failed.count.formatted()) failed", systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }
}

// MARK: History

private struct HistorySection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Section {
            if model.state.history.isEmpty {
                Text("Each finished backup shows here.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.state.history, id: \.id) { item in
                HStack(spacing: 12) {
                    Image(systemName: item.failedFiles == 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(item.failedFiles == 0 ? .green : .orange)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.startedAt.formatted(date: .abbreviated, time: .shortened))
                        Text(summary(item))
                            .font(.footnote)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("History")
        } footer: {
            if !model.state.history.isEmpty {
                Text("Shoebox keeps the latest \(model.keepLatest.formatted()) backups and deletes older ones.")
            }
        }
    }

    private func summary(_ item: SnapshotSummary) -> String {
        var parts = [String(localized: "\(item.uploadedFiles.formatted()) files")]
        if item.failedFiles > 0 { parts.append(String(localized: "\(item.failedFiles.formatted()) failed")) }
        if item.skippedAssets > 0 { parts.append(String(localized: "\(item.skippedAssets.formatted()) skipped")) }
        return parts.joined(separator: " · ")
    }
}

// MARK: Primary action

private struct BackUpButton: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Button {
            Task { await model.backUpNow() }
        } label: {
            Group {
                if model.busy {
                    ProgressView()
                } else if model.state.active != nil {
                    Text("Backing up…")
                } else {
                    Label("Back up now", systemImage: "arrow.up.circle")
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!model.isConfigured || model.state.active != nil || model.busy)
        .padding(.horizontal)
        .padding(.bottom, 8)
        .background(.bar)
    }
}
