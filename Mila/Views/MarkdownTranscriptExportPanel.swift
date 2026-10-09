import AppKit
import UniformTypeIdentifiers

/// The "Export Transcript (.md)…" save panel, shared by the history context
/// menu and the recording detail toolbar so each of those views only carries
/// the button itself. Same shape as their "Export Subtitles (.srt)…" panels:
/// NSSavePanel, title as the suggested filename, NSAlert on failure.
@MainActor
enum MarkdownTranscriptExportPanel {

    static func present(for recording: Recording) {
        let panel = NSSavePanel()
        panel.title = "Export Transcript"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = suggestedFileName(for: recording)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try MarkdownTranscriptExporter.write(for: recording, to: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// Sanitized title + `.md`; `Untitled recording.md` when the title has
    /// nothing usable left after sanitizing.
    static func suggestedFileName(for recording: Recording) -> String {
        let safe = ObsidianPathSanitizer.nameFragment(recording.title)
        return (safe.isEmpty ? MarkdownTranscriptExporter.untitledTitle : safe) + ".md"
    }
}
