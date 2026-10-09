import SwiftUI

/// Markdown transcript section, embedded in the Storage settings tab next to
/// the Obsidian section. Controls the `.md` sidecar written beside each
/// recording, whether paragraphs carry timestamps, what Obsidian vault notes
/// contain, and a one-shot backfill for recordings that already exist.
struct MarkdownExportSettingsSection: View {
    @EnvironmentObject private var settings: MarkdownExportSettings
    @EnvironmentObject private var store: RecordingStore

    @State private var isBackfilling = false
    @State private var backfillResult: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "doc.plaintext")
                    .foregroundStyle(.tint)
                Text("Markdown transcripts")
                    .font(.callout.weight(.semibold))
                Spacer()
            }
            Toggle("Save a Markdown transcript (.md) next to each recording",
                   isOn: $settings.sidecarEnabled)
                .accessibilityIdentifier("markdownExport.sidecar.toggle")
            Toggle("Timestamp each paragraph", isOn: $settings.paragraphTimestamps)
                .accessibilityIdentifier("markdownExport.timestamps.toggle")
            Picker("Notes in your vault contain", selection: $settings.noteContent) {
                ForEach(MarkdownExportSettings.NoteContent.allCases, id: \.self) { content in
                    Text(content.displayName).tag(content)
                }
            }
            .accessibilityIdentifier("markdownExport.noteContent.picker")
            HStack(spacing: 8) {
                Button("Write Markdown for existing recordings") { backfill() }
                    .disabled(isBackfilling)
                    .accessibilityIdentifier("markdownExport.backfill.button")
                if let backfillResult {
                    Text(backfillResult)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text("The .srt subtitle file is still written next to each recording, because Mila's subtitle-video feature uses it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    /// Write a `.md` for every completed, non-trashed recording, whether or not
    /// the sidecar toggle is on. The file I/O runs off the main thread; the
    /// snapshot of recordings and the directory are taken first so nothing
    /// main-actor-isolated is touched from the background task.
    private func backfill() {
        guard !isBackfilling else { return }
        let recordings = store.recordings.filter { !$0.isTrashed && $0.status == .completed }
        let directory = store.recordingsDirectory
        isBackfilling = true
        backfillResult = nil
        Task { @MainActor in
            let written = await Task.detached(priority: .utility) { () -> Int in
                var count = 0
                for recording in recordings {
                    if MarkdownTranscriptExporter.writeSidecar(for: recording, in: directory, force: true) {
                        count += 1
                    }
                }
                return count
            }.value
            backfillResult = written == 0
                ? "Nothing to write."
                : "Wrote \(written) file\(written == 1 ? "" : "s")."
            isBackfilling = false
        }
    }
}
