import XCTest
import TranscriptionCore
@testable import Mila

/// The three vault-note content modes through
/// `ObsidianExporter.markdown(for:content:)`. All content is synthetic and
/// every `UserDefaults` is a private suite.
@MainActor
final class ObsidianNoteContentModeTests: XCTestCase {

    private var tempRoot: URL!
    private var vault: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MilaObsidianNoteContentModeTests-\(UUID())", isDirectory: true)
        vault = tempRoot.appendingPathComponent("Vault", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        suiteName = "ObsidianNoteContentModeTests.\(UUID())"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        if let suiteName { defaults?.removePersistentDomain(forName: suiteName) }
        try await super.tearDown()
    }

    private func action(_ text: String) -> ActionItem {
        ActionItem(id: UUID().uuidString, text: text, speaker: nil,
                   timestampSeconds: 0, source: .llmInferred, addedAt: Date())
    }

    private func makeRecording(summary: String? = "We decided to ship next week.",
                               actionItems: [ActionItem]? = nil,
                               segments: [TranscriptSegment]? = nil,
                               fullText: String = "Alpha beta. Gamma delta.") -> Recording {
        Recording(
            title: "Team Sync",
            createdAt: Date(timeIntervalSince1970: 1_767_355_200),
            duration: 90,
            source: .microphone,
            audioFileName: "a.wav",
            status: .completed,
            language: "en",
            segments: segments ?? [
                TranscriptSegment(start: 0, end: 4, text: "Alpha beta.", speaker: "SPEAKER_00"),
                TranscriptSegment(start: 4, end: 8, text: "Gamma delta.", speaker: "SPEAKER_01"),
            ],
            fullText: fullText,
            summary: summary,
            actionItems: actionItems
        )
    }

    // MARK: - Default == upstream

    func test_default_argument_is_byte_identical_to_the_upstream_summary_else_transcript_output() {
        let withSummary = makeRecording(actionItems: [action("Ship it")])
        XCTAssertEqual(ObsidianExporter.markdown(for: withSummary),
                       ObsidianExporter.markdown(for: withSummary, content: .summaryElseTranscript))
        XCTAssertEqual(ObsidianExporter.markdown(for: withSummary),
                       "# Team Sync\n\nWe decided to ship next week.\n\n## Action items\n\n- [ ] Ship it\n")

        let noSummary = makeRecording(summary: nil)
        XCTAssertEqual(ObsidianExporter.markdown(for: noSummary),
                       ObsidianExporter.markdown(for: noSummary, content: .summaryElseTranscript))
        XCTAssertEqual(ObsidianExporter.markdown(for: noSummary),
                       "# Team Sync\n\n## Transcript\n\nSPEAKER_00: Alpha beta.\nSPEAKER_01: Gamma delta.\n")
    }

    func test_summary_else_transcript_ignores_the_timestamp_argument() {
        let rec = makeRecording()
        XCTAssertEqual(ObsidianExporter.markdown(for: rec, content: .summaryElseTranscript, timestamps: false),
                       ObsidianExporter.markdown(for: rec))
    }

    // MARK: - transcript

    func test_transcript_mode_has_the_paragraph_transcript_and_no_summary() {
        let rec = makeRecording(actionItems: [action("Ship it")])
        let md = ObsidianExporter.markdown(for: rec, content: .transcript)
        XCTAssertTrue(md.contains("\n# Team Sync\n"))
        XCTAssertTrue(md.contains("## Transcript"))
        XCTAssertTrue(md.contains("**[00:00] Speaker A:** Alpha beta."), md)
        XCTAssertTrue(md.contains("**[00:04] Speaker B:** Gamma delta."), md)
        XCTAssertFalse(md.contains("We decided to ship next week."))
        XCTAssertFalse(md.contains("## Summary"))
    }

    func test_transcript_mode_carries_front_matter() {
        let md = ObsidianExporter.markdown(for: makeRecording(), content: .transcript)
        XCTAssertTrue(md.hasPrefix("---\ntitle: \"Team Sync\"\n"), md)
        XCTAssertTrue(md.contains("recording_id: \""))
    }

    func test_transcript_mode_honours_the_timestamp_argument() {
        let on = ObsidianExporter.markdown(for: makeRecording(), content: .transcript, timestamps: true)
        let off = ObsidianExporter.markdown(for: makeRecording(), content: .transcript, timestamps: false)
        XCTAssertTrue(on.contains("[00:00]"))
        XCTAssertFalse(off.contains("[00:"))
        XCTAssertTrue(off.contains("**Speaker A:** Alpha beta."))
    }

    // MARK: - summary + transcript

    func test_summary_and_transcript_mode_has_both_and_the_action_items() {
        let rec = makeRecording(actionItems: [action("Ship it")])
        let md = ObsidianExporter.markdown(for: rec, content: .summaryAndTranscript)
        XCTAssertTrue(md.contains("## Summary\n\nWe decided to ship next week."), md)
        XCTAssertTrue(md.contains("## Transcript"))
        XCTAssertTrue(md.contains("**[00:00] Speaker A:** Alpha beta."))
        XCTAssertTrue(md.contains("- [ ] Ship it"))
        if let summaryAt = md.range(of: "## Summary"), let transcriptAt = md.range(of: "## Transcript"),
           let itemsAt = md.range(of: "## Action items") {
            XCTAssertLessThan(summaryAt.lowerBound, transcriptAt.lowerBound)
            XCTAssertLessThan(transcriptAt.lowerBound, itemsAt.lowerBound)
        } else {
            XCTFail("expected Summary, Transcript and Action items headings in order:\n\(md)")
        }
    }

    func test_summary_and_transcript_without_a_summary_is_just_the_transcript() {
        let md = ObsidianExporter.markdown(for: makeRecording(summary: nil), content: .summaryAndTranscript)
        XCTAssertFalse(md.contains("## Summary"))
        XCTAssertTrue(md.contains("## Transcript"))
    }

    // MARK: - No transcript falls back to upstream

    func test_transcript_modes_fall_back_to_the_upstream_note_when_there_is_no_transcript() {
        let summaryOnly = makeRecording(segments: [], fullText: "")
        let upstream = ObsidianExporter.markdown(for: summaryOnly)
        XCTAssertEqual(ObsidianExporter.markdown(for: summaryOnly, content: .transcript), upstream)
        XCTAssertEqual(ObsidianExporter.markdown(for: summaryOnly, content: .summaryAndTranscript), upstream)
        XCTAssertTrue(upstream.contains("We decided to ship next week."))
    }

    // MARK: - hasContent

    func test_has_content_counts_segments_in_the_transcript_modes_only() {
        let segmentsOnly = makeRecording(summary: nil, segments: nil, fullText: "")
        XCTAssertFalse(ObsidianExporter.hasContent(segmentsOnly),
                       "upstream behaviour is unchanged for the default mode")
        XCTAssertFalse(ObsidianExporter.hasContent(segmentsOnly, content: .summaryElseTranscript))
        XCTAssertTrue(ObsidianExporter.hasContent(segmentsOnly, content: .transcript))
        XCTAssertTrue(ObsidianExporter.hasContent(segmentsOnly, content: .summaryAndTranscript))

        let blank = makeRecording(summary: nil,
                                  segments: [TranscriptSegment(start: 0, end: 1, text: "  ")],
                                  fullText: "")
        XCTAssertFalse(ObsidianExporter.hasContent(blank, content: .transcript))
    }

    // MARK: - writeNote uses the exporter's injected defaults

    func test_export_writes_the_mode_chosen_in_the_injected_defaults() throws {
        let settings = ObsidianVaultSettings(defaults: defaults)
        settings.enabled = true
        settings.subfolder = ""
        XCTAssertTrue(settings.setVault(vault))
        let exporter = ObsidianExporter(settings: settings, defaults: defaults)

        let rec = makeRecording()
        // Default (unset) mode: upstream summary note.
        var url = try XCTUnwrap(exporter.export(rec))
        var text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("We decided to ship next week."))
        XCTAssertFalse(text.contains("## Transcript"))

        defaults.set(MarkdownExportSettings.NoteContent.summaryAndTranscript.rawValue,
                     forKey: MarkdownExportSettings.noteContentKey)
        url = try XCTUnwrap(exporter.export(rec))
        text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("## Summary"))
        XCTAssertTrue(text.contains("## Transcript"))

        defaults.set(MarkdownExportSettings.NoteContent.transcript.rawValue,
                     forKey: MarkdownExportSettings.noteContentKey)
        url = try XCTUnwrap(exporter.export(rec))
        text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("We decided to ship next week."))
        XCTAssertTrue(text.contains("## Transcript"))
    }
}
