import Foundation
import Combine

/// Settings for the paragraph Markdown transcript (`.md` sidecar next to each
/// recording, the content mode of vault notes, the "Export Transcript (.md)…"
/// command). See `MarkdownTranscriptExporter`.
///
/// Deliberately NOT `@MainActor`, unlike most settings objects: the static
/// readers below are called from nonisolated exporter code
/// (`TranscriptExporter.writeSRT(for:in:)`, `ObsidianExporter.markdown`), and
/// a main-actor-isolated static would not be callable from there. Every
/// mutation of the `@Published` properties comes from SwiftUI on the main
/// thread.
///
/// The code defaults are the upstream behaviour (sidecar OFF, summary else
/// transcript). The personal build flips them with
/// `UserDefaults.register(defaults:)`, which the readers here honour because
/// they read with `object(forKey:)` / `string(forKey:)` rather than assuming
/// "absent means false".
final class MarkdownExportSettings: ObservableObject {
    static let sidecarEnabledKey = "markdownExport.sidecarEnabled"
    static let paragraphTimestampsKey = "markdownExport.paragraphTimestamps"
    static let noteContentKey = "markdownExport.noteContent"

    /// What a vault note (Obsidian export) contains.
    enum NoteContent: String, CaseIterable {
        /// Upstream behaviour: the AI summary when one exists, otherwise the transcript.
        case summaryElseTranscript
        /// The full paragraph transcript, never the summary.
        case transcript
        /// The AI summary followed by the full paragraph transcript.
        case summaryAndTranscript

        var displayName: String {
            switch self {
            case .summaryElseTranscript: return "Summary (or transcript if no summary)"
            case .transcript: return "Full transcript"
            case .summaryAndTranscript: return "Summary + full transcript"
            }
        }
    }

    /// The three values as plain data, for call sites that have no settings
    /// object to hand (static exporters, background work).
    struct Snapshot: Equatable {
        var sidecarEnabled: Bool
        var paragraphTimestamps: Bool
        var noteContent: NoteContent
    }

    static let defaultSidecarEnabled = false
    static let defaultParagraphTimestamps = true
    static let defaultNoteContent = NoteContent.summaryElseTranscript

    /// Write a `.md` transcript next to each recording's `.srt`.
    @Published var sidecarEnabled: Bool {
        didSet {
            guard sidecarEnabled != oldValue else { return }
            defaults.set(sidecarEnabled, forKey: Self.sidecarEnabledKey)
        }
    }

    /// Put a `[MM:SS]` timestamp on each paragraph.
    @Published var paragraphTimestamps: Bool {
        didSet {
            guard paragraphTimestamps != oldValue else { return }
            defaults.set(paragraphTimestamps, forKey: Self.paragraphTimestampsKey)
        }
    }

    /// What Obsidian vault notes contain.
    @Published var noteContent: NoteContent {
        didSet {
            guard noteContent != oldValue else { return }
            defaults.set(noteContent.rawValue, forKey: Self.noteContentKey)
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let snapshot = Self.current(defaults)
        self.sidecarEnabled = snapshot.sidecarEnabled
        self.paragraphTimestamps = snapshot.paragraphTimestamps
        self.noteContent = snapshot.noteContent
    }

    /// Read the persisted values (or the registered / code defaults). An
    /// unrecognised `noteContent` string falls back to the default rather
    /// than failing.
    static func current(_ defaults: UserDefaults = .standard) -> Snapshot {
        let sidecar = defaults.object(forKey: sidecarEnabledKey) as? Bool ?? defaultSidecarEnabled
        let timestamps = defaults.object(forKey: paragraphTimestampsKey) as? Bool ?? defaultParagraphTimestamps
        let content = defaults.string(forKey: noteContentKey).flatMap(NoteContent.init(rawValue:))
            ?? defaultNoteContent
        return Snapshot(sidecarEnabled: sidecar,
                        paragraphTimestamps: timestamps,
                        noteContent: content)
    }
}
