import Foundation
import OSLog
import MilaKit
import TranscriptionCore

// Same privacy rule as `TranscriptExporter`: the sidecar's name is derived from
// the recording's TITLE, so it is `.private` and the recording's UUID is the
// public correlation key. Transcript text is never logged.
private let markdownLog = Logger(subsystem: "io.island.whisper.IslandWhisper",
                                 category: "MarkdownTranscriptExporter")

/// Paragraph Markdown transcripts for a knowledge base: a `.md` sidecar next to
/// each recording's `.srt`, the "Export Transcript (.md)…" command, and the
/// vault-note content modes. The grouping/rendering itself lives in MilaKit's
/// `ParagraphTranscriptFormatter`; this type adapts a `Recording` to it and
/// owns the front matter and file I/O.
///
/// The `.srt` is still written (Mila's subtitle-video feature reads it); this
/// is an additional file, never a replacement.
enum MarkdownTranscriptExporter {

    static let generatorName = "mila-fork paragraph-transcript v1"
    static let untitledTitle = "Untitled recording"

    // MARK: - Document

    /// The full Markdown document for `recording`: front matter, `# title`,
    /// optional `## Summary`, `## Transcript`, and (only when the summary is
    /// included) `## Action items`. Returns "" when there is no transcript
    /// to render.
    ///
    /// Speaker labels go through `displaySpeakerName(names:language:)` so the
    /// `.md`, the UI and the clipboard text agree ("Speaker A" / "דובר א׳" or
    /// the name the user assigned).
    ///
    /// `timeZone` only affects the `date:` front-matter value; it is a
    /// parameter so tests do not depend on the machine's zone.
    static func document(for recording: Recording,
                         includeSummary: Bool,
                         timestamps: Bool = true,
                         timeZone: TimeZone = .current) -> String {
        let names = recording.speakerNames
        let language = recording.language
        let label: (String) -> String = { raw in
            raw.displaySpeakerName(names: names, language: language)
        }
        let options = ParagraphTranscriptFormatter.Options(includeTimestamps: timestamps)

        // `fallback` is an autoclosure in the formatter and is only read when
        // no segment has text; keep the expression inline.
        let body = ParagraphTranscriptFormatter.markdown(
            segments: recording.segments,
            fallback: recording.fullText,
            label: label,
            start: { $0.start },
            end: { $0.end },
            options: options
        )
        guard !body.isEmpty else { return "" }

        let paragraphs = ParagraphTranscriptFormatter.paragraphs(
            segments: recording.segments,
            label: label,
            start: { $0.start },
            end: { $0.end },
            options: options
        )
        var speakers: [String] = []
        for paragraph in paragraphs {
            if let name = paragraph.label, !speakers.contains(name) { speakers.append(name) }
        }

        let heading = ParagraphTranscriptFormatter.oneLine(recording.title)
        let title = heading.isEmpty ? untitledTitle : heading

        var front: [String] = ["---"]
        front.append("title: \(jsonString(title))")
        front.append("date: \(jsonString(isoDate(recording.createdAt, timeZone: timeZone)))")
        front.append("duration: \(jsonString(clock(recording.duration)))")
        front.append("language: \(jsonString(recording.language))")
        front.append("source: \(jsonString(recording.source.rawValue))")
        let app = ParagraphTranscriptFormatter.oneLine(recording.appName ?? "")
        if !app.isEmpty {
            front.append("app: \(jsonString(app))")
        }
        if !speakers.isEmpty {
            front.append("speakers: [" + speakers.map(jsonString).joined(separator: ", ") + "]")
        }
        front.append("recording_id: \(jsonString(recording.id.uuidString))")
        front.append("generator: \(jsonString(generatorName))")
        front.append("---")

        var blocks: [String] = [front.joined(separator: "\n"), "# \(title)"]

        if includeSummary {
            let summary = (recording.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !summary.isEmpty {
                blocks.append("## Summary\n\n\(summary)")
            }
        }
        blocks.append("## Transcript\n\n\(body)")
        if includeSummary, let items = recording.actionItems, !items.isEmpty {
            let lines = items.map { "- [ ] \(ParagraphTranscriptFormatter.oneLine($0.text))" }
            blocks.append("## Action items\n\n" + lines.joined(separator: "\n"))
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    /// The note body for the Obsidian exporter's transcript modes. The
    /// upstream summary-else-transcript mode never comes through here.
    static func vaultNote(for recording: Recording,
                          content: MarkdownExportSettings.NoteContent,
                          timestamps: Bool) -> String {
        document(for: recording,
                 includeSummary: content == .summaryAndTranscript,
                 timestamps: timestamps)
    }

    // MARK: - Sidecar

    /// `<audio file name minus extension>.md` in `directory` — the same
    /// derivation as the `.srt` (`Recording.subtitleFileName`).
    static func sidecarURL(for recording: Recording, in directory: URL) -> URL {
        let name = (recording.audioFileName as NSString).deletingPathExtension + ".md"
        return directory.appendingPathComponent(name)
    }

    /// Write the `.md` sidecar next to the recording's audio. A no-op unless
    /// the sidecar setting is on (or `force` is set, for the "write Markdown
    /// for existing recordings" backfill). Never throws; failures are logged
    /// and the caller carries on, exactly like `TranscriptExporter.writeSRT`.
    ///
    /// The sidecar is the transcript only: the summary is generated after the
    /// transcript sidecars are written, so including it here would leave a
    /// file that is missing it (or stale) until some later rewrite.
    ///
    /// Returns true when a file was written.
    @discardableResult
    static func writeSidecar(for recording: Recording,
                             in directory: URL,
                             defaults: UserDefaults = .standard,
                             force: Bool = false) -> Bool {
        let settings = MarkdownExportSettings.current(defaults)
        guard force || settings.sidecarEnabled else { return false }

        let url = sidecarURL(for: recording, in: directory)
        let body = document(for: recording,
                            includeSummary: false,
                            timestamps: settings.paragraphTimestamps)
        guard !body.isEmpty else {
            // Nothing to say any more (transcript cleared): do not leave a
            // stale file behind. Same as the `.srt`.
            try? FileManager.default.removeItem(at: url)
            return false
        }
        let fileName = url.lastPathComponent
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
            markdownLog.log("""
                wrote Markdown transcript for \(recording.id, privacy: .public) \
                (\(fileName, privacy: .private))
                """)
            return true
        } catch {
            let ns = error as NSError
            markdownLog.error("""
                failed to write Markdown transcript for \(recording.id, privacy: .public) \
                (\(fileName, privacy: .private)) \
                [\(ns.domain, privacy: .public) \(ns.code, privacy: .public)]: \
                \(error.localizedDescription, privacy: .private)
                """)
            return false
        }
    }

    /// Remove the `.md` sidecar, ignoring a missing file. Called wherever the
    /// `.srt` is removed.
    static func removeSidecar(for recording: Recording,
                              in directory: URL,
                              fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: sidecarURL(for: recording, in: directory))
    }

    // MARK: - Explicit export

    /// Write the document to a user-chosen URL ("Export Transcript (.md)…").
    /// The summary is included for `summaryElseTranscript` and
    /// `summaryAndTranscript`, excluded for `transcript`. Throws so the caller
    /// can show an alert; an empty transcript is an error, not an empty file.
    static func write(for recording: Recording,
                      to url: URL,
                      defaults: UserDefaults = .standard) throws {
        let settings = MarkdownExportSettings.current(defaults)
        let body = document(for: recording,
                            includeSummary: settings.noteContent != .transcript,
                            timestamps: settings.paragraphTimestamps)
        guard !body.isEmpty else {
            throw NSError(domain: "MarkdownTranscriptExporter", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No transcript to export."])
        }
        try body.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Formatting helpers

    /// A JSON string literal, which is also a valid YAML double-quoted scalar
    /// and keeps Hebrew as-is (JSONEncoder does not escape non-ASCII).
    private static func jsonString(_ text: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(text) else { return "\"\"" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func isoDate(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// `HH:MM:SS` (hours do not wrap); 00:00:00 for a missing or invalid duration.
    private static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "00:00:00" }
        let whole = Int(min(seconds, 1_000_000_000).rounded())
        return String(format: "%02d:%02d:%02d", whole / 3600, (whole % 3600) / 60, whole % 60)
    }
}
