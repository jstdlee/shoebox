import SwiftUI

/// The few concepts a new user meets, in the order they meet them.
struct HelpView: View {
    private struct Concept: Identifiable {
        let id = UUID()
        let symbol: String
        let title: LocalizedStringKey
        let text: LocalizedStringKey
    }

    private let concepts: [Concept] = [
        Concept(symbol: "externaldrive.connected.to.line.below", title: "Storage",
                text: "Your own S3-compatible bucket, for example Cloudflare R2. Shoebox needs a key that can read, write and delete."),
        Concept(symbol: "square.stack.3d.up", title: "Backup",
                text: "A full copy of your photo library in one folder. Each backup is complete on its own."),
        Concept(symbol: "calendar", title: "Schedule",
                text: "Shoebox starts a new backup after the number of days you set. iOS picks the exact time."),
        Concept(symbol: "moon.zzz", title: "Background backup",
                text: "iOS uploads the photos for Shoebox, also when the app is closed or the phone is locked."),
        Concept(symbol: "trash", title: "Keep",
                text: "When a new backup is complete, Shoebox deletes the oldest backups above this number."),
        Concept(symbol: "doc.text", title: "Manifest",
                text: "The last file of each backup. A backup without it is not complete, and Shoebox never counts it."),
    ]

    var body: some View {
        List(concepts) { concept in
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: concept.symbol)
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(concept.title).font(.headline)
                    Text(concept.text).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
        }
        .listStyle(.insetGrouped)
        .navigationTitle("How Shoebox works")
        .navigationBarTitleDisplayMode(.inline)
    }
}
