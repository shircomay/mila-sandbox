import XCTest
import TranscriptionCore
@testable import Mila

/// All content here is synthetic. Every `UserDefaults` is a private suite, so
/// nothing reads or writes `.standard` (the personal build registers the
/// sidecar ON there).
@MainActor
final class MarkdownTranscriptExporterTests: XCTestCase {

    private var tempRoot: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    /// 2026-01-02T12:00:00Z.
    private static let fixtureDate = Date(timeIntervalSince1970: 1_767_355_200)
    private static let fixtureID = UUID(uuidString: "6F1C0000-0000-0000-0000-000000000001")!
    private static let plus3 = TimeZone(secondsFromGMT: 3 * 3600)!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = TestSupport.makeTempRoot(label: "MarkdownTranscriptExporterTests")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        suiteName = "MarkdownTranscriptExporterTests.\(UUID())"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        if let suiteName { defaults?.removePersistentDomain(forName: suiteName) }
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    private func diarized(title: String = "Weekly sync",
                          language: String = "he",
                          names: [String: String] = ["SPEAKER_00": "Shir"],
                          summary: String? = nil,
                          actionItems: [ActionItem]? = nil,
                          appName: String? = "Zoom") -> Recording {
        Recording(
            id: Self.fixtureID,
            title: title,
            createdAt: Self.fixtureDate,
            duration: 2537,
            source: .meeting,
            audioFileName: "Weekly sync.m4a",
            status: .completed,
            language: language,
            segments: [
                TranscriptSegment(start: 0, end: 5, text: " First sentence.", speaker: "SPEAKER_00"),
                TranscriptSegment(start: 5, end: 10, text: "Second sentence.", speaker: "SPEAKER_00"),
                TranscriptSegment(start: 12, end: 20, text: "Reply from the other person.", speaker: "SPEAKER_01"),
            ],
            fullText: "First sentence. Second sentence. Reply from the other person.",
            appName: appName,
            summary: summary,
            actionItems: actionItems,
            speakerNames: names
        )
    }

    private func undiarized(fullText: String = "plain words",
                            segments: [TranscriptSegment]? = nil) -> Recording {
        Recording(
            id: Self.fixtureID,
            title: "Memo",
            createdAt: Self.fixtureDate,
            duration: 12,
            source: .microphone,
            audioFileName: "Memo.wav",
            status: .completed,
            language: "en",
            segments: segments ?? [
                TranscriptSegment(start: 3, end: 6, text: "Hello there."),
                TranscriptSegment(start: 6, end: 9, text: "Second thought."),
            ],
            fullText: fullText
        )
    }

    private func action(_ text: String) -> ActionItem {
        ActionItem(id: UUID().uuidString, text: text, speaker: nil,
                   timestampSeconds: 0, source: .llmInferred, addedAt: Date())
    }

    private func document(_ recording: Recording,
                          includeSummary: Bool = false,
                          timestamps: Bool = true) -> String {
        MarkdownTranscriptExporter.document(for: recording,
                                            includeSummary: includeSummary,
                                            timestamps: timestamps,
                                            timeZone: Self.plus3)
    }

    private var hebrewB: String {
        "SPEAKER_01".displaySpeakerName(names: [:], language: "he")
    }

    // MARK: - Document shape

    func test_document_full_shape() {
        let expected = """
            ---
            title: "Weekly sync"
            date: "2026-01-02T15:00:00+03:00"
            duration: "00:42:17"
            language: "he"
            source: "meeting"
            app: "Zoom"
            speakers: ["Shir", "\(hebrewB)"]
            recording_id: "6F1C0000-0000-0000-0000-000000000001"
            generator: "mila-fork paragraph-transcript v1"
            ---

            # Weekly sync

            ## Transcript

            **[00:00] Shir:** First sentence. Second sentence.

            **[00:12] \(hebrewB):** Reply from the other person.

            """
        XCTAssertEqual(document(diarized()), expected)
    }

    func test_document_ends_with_exactly_one_newline() {
        let doc = document(diarized())
        XCTAssertTrue(doc.hasSuffix("\n"))
        XCTAssertFalse(doc.hasSuffix("\n\n"))
    }

    func test_front_matter_date_uses_the_given_time_zone() {
        let utc = MarkdownTranscriptExporter.document(for: diarized(), includeSummary: false,
                                                      timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertTrue(utc.contains("date: \"2026-01-02T12:00:00Z\"\n"))
        XCTAssertTrue(document(diarized()).contains("date: \"2026-01-02T15:00:00+03:00\"\n"))
    }

    func test_front_matter_values_are_json_strings_and_hebrew_is_not_escaped() {
        let doc = document(diarized(title: "Q3 \"plan\" a/b שלום"))
        XCTAssertTrue(doc.contains("title: \"Q3 \\\"plan\\\" a/b שלום\"\n"), doc)
        XCTAssertTrue(doc.contains("\n# Q3 \"plan\" a/b שלום\n"), "the heading is the plain title")
    }

    func test_title_falls_back_when_empty_and_is_single_line() {
        let blank = document(diarized(title: " \n "))
        XCTAssertTrue(blank.contains("title: \"Untitled recording\"\n"))
        XCTAssertTrue(blank.contains("\n# Untitled recording\n"))

        let multi = document(diarized(title: "Two\nlines"))
        XCTAssertTrue(multi.contains("\n# Two lines\n"))
        XCTAssertTrue(multi.contains("title: \"Two lines\"\n"))
    }

    func test_app_key_only_when_app_name_is_non_empty() {
        XCTAssertTrue(document(diarized(appName: "Zoom")).contains("app: \"Zoom\"\n"))
        XCTAssertFalse(document(diarized(appName: nil)).contains("app:"))
        XCTAssertFalse(document(diarized(appName: "  ")).contains("app:"))
    }

    func test_duration_is_hh_mm_ss_and_hours_do_not_wrap() {
        var rec = diarized()
        rec.duration = 3_725
        XCTAssertTrue(document(rec).contains("duration: \"01:02:05\"\n"))
        rec.duration = 360_000
        XCTAssertTrue(document(rec).contains("duration: \"100:00:00\"\n"))
        rec.duration = .nan
        XCTAssertTrue(document(rec).contains("duration: \"00:00:00\"\n"))
    }

    // MARK: - Summary and action items

    func test_summary_is_included_verbatim_before_the_transcript() {
        let rec = diarized(summary: "We agreed to ship.\n- first\n- second")
        let doc = document(rec, includeSummary: true)
        XCTAssertTrue(doc.contains("## Summary\n\nWe agreed to ship.\n- first\n- second\n\n## Transcript"), doc)
    }

    func test_summary_is_left_out_when_not_included_or_empty() {
        let rec = diarized(summary: "We agreed to ship.")
        XCTAssertFalse(document(rec, includeSummary: false).contains("## Summary"))
        XCTAssertFalse(document(diarized(summary: "  \n"), includeSummary: true).contains("## Summary"))
        XCTAssertFalse(document(diarized(summary: nil), includeSummary: true).contains("## Summary"))
    }

    func test_action_items_follow_the_transcript_when_the_summary_is_included() {
        let rec = diarized(summary: "S", actionItems: [action("Ship it"), action("Email\nSam")])
        let doc = document(rec, includeSummary: true)
        XCTAssertTrue(doc.hasSuffix("## Action items\n\n- [ ] Ship it\n- [ ] Email Sam\n"), doc)
        let transcriptAt = doc.range(of: "## Transcript")
        let itemsAt = doc.range(of: "## Action items")
        XCTAssertNotNil(transcriptAt)
        XCTAssertNotNil(itemsAt)
        if let transcriptAt, let itemsAt {
            XCTAssertLessThan(transcriptAt.lowerBound, itemsAt.lowerBound)
        }
    }

    func test_action_items_are_left_out_when_the_summary_is_not_included() {
        let rec = diarized(summary: "S", actionItems: [action("Ship it")])
        XCTAssertFalse(document(rec, includeSummary: false).contains("Action items"))
    }

    // MARK: - Speaker labels

    func test_hebrew_speaker_label_uses_display_speaker_name() {
        let doc = document(diarized(language: "he", names: [:]))
        let a = "SPEAKER_00".displaySpeakerName(names: [:], language: "he")
        XCTAssertTrue(doc.contains("**[00:00] \(a):** First sentence."), doc)
        XCTAssertTrue(a.hasPrefix("דובר"), "sanity: the Hebrew friendly label")
    }

    func test_english_speaker_label_and_assigned_name_wins() {
        let plain = document(diarized(language: "en", names: [:]))
        XCTAssertTrue(plain.contains("**[00:00] Speaker A:** First sentence."), plain)
        XCTAssertTrue(plain.contains("**[00:12] Speaker B:**"), plain)
        XCTAssertTrue(plain.contains("speakers: [\"Speaker A\", \"Speaker B\"]\n"))

        let named = document(diarized(language: "en", names: ["SPEAKER_00": "Dana", "SPEAKER_01": "Lee"]))
        XCTAssertTrue(named.contains("**[00:00] Dana:**"))
        XCTAssertTrue(named.contains("**[00:12] Lee:**"))
        XCTAssertFalse(named.contains("Speaker A"))
    }

    func test_speakers_are_listed_in_order_of_first_appearance_without_repeats() {
        var rec = diarized(language: "en", names: [:])
        rec.segments.append(TranscriptSegment(start: 30, end: 33, text: "And back again.", speaker: "SPEAKER_00"))
        XCTAssertTrue(document(rec).contains("speakers: [\"Speaker A\", \"Speaker B\"]\n"))
    }

    // MARK: - Unlabelled, timestamps, empty

    func test_unlabelled_transcript_has_no_label_and_no_speakers_key() {
        let doc = document(undiarized())
        XCTAssertTrue(doc.contains("**[00:03]** Hello there. Second thought.\n"), doc)
        XCTAssertFalse(doc.contains("speakers:"))
    }

    func test_timestamps_off() {
        let labelled = document(diarized(language: "en", names: [:]), timestamps: false)
        XCTAssertTrue(labelled.contains("\n**Speaker A:** First sentence. Second sentence.\n"), labelled)
        XCTAssertFalse(labelled.contains("[00:"))

        let bare = document(undiarized(), timestamps: false)
        XCTAssertTrue(bare.contains("\nHello there. Second thought.\n"), bare)
    }

    func test_text_only_recording_uses_the_full_text_fallback() {
        let rec = undiarized(fullText: "just the sidecar text", segments: [])
        let doc = document(rec)
        XCTAssertTrue(doc.contains("**[time unavailable]** just the sidecar text\n"), doc)
    }

    func test_empty_transcript_gives_an_empty_document() {
        XCTAssertEqual(document(undiarized(fullText: "", segments: [])), "")
        XCTAssertEqual(document(undiarized(fullText: "  ",
                                           segments: [TranscriptSegment(start: 0, end: 1, text: "  ")])), "")
    }

    // MARK: - Sidecar URL

    func test_sidecar_url_swaps_the_extension_like_the_srt() {
        let rec = diarized()
        let md = MarkdownTranscriptExporter.sidecarURL(for: rec, in: tempRoot)
        XCTAssertEqual(md.lastPathComponent, "Weekly sync.md")
        XCTAssertEqual(md.deletingLastPathComponent().standardizedFileURL.path, tempRoot.standardizedFileURL.path)
        XCTAssertEqual((rec.subtitleFileName as NSString).deletingPathExtension,
                       (md.lastPathComponent as NSString).deletingPathExtension,
                       "same stem as the .srt")
    }

    // MARK: - writeSidecar / removeSidecar

    func test_write_sidecar_is_a_no_op_when_disabled() {
        let rec = diarized()
        let wrote = MarkdownTranscriptExporter.writeSidecar(for: rec, in: tempRoot, defaults: defaults)
        XCTAssertFalse(wrote)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: MarkdownTranscriptExporter.sidecarURL(for: rec, in: tempRoot).path))
    }

    func test_write_sidecar_writes_the_transcript_when_enabled() throws {
        defaults.set(true, forKey: MarkdownExportSettings.sidecarEnabledKey)
        let rec = diarized(summary: "A summary that must not appear in the sidecar.")
        let wrote = MarkdownTranscriptExporter.writeSidecar(for: rec, in: tempRoot, defaults: defaults)
        XCTAssertTrue(wrote)
        let url = MarkdownTranscriptExporter.sidecarURL(for: rec, in: tempRoot)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("---\ntitle: \"Weekly sync\"\n"))
        XCTAssertTrue(text.contains("## Transcript"))
        XCTAssertTrue(text.contains("First sentence. Second sentence."))
        XCTAssertFalse(text.contains("## Summary"))
    }

    func test_write_sidecar_honours_the_timestamp_setting() throws {
        defaults.set(true, forKey: MarkdownExportSettings.sidecarEnabledKey)
        defaults.set(false, forKey: MarkdownExportSettings.paragraphTimestampsKey)
        let rec = diarized(language: "en", names: [:])
        MarkdownTranscriptExporter.writeSidecar(for: rec, in: tempRoot, defaults: defaults)
        let text = try String(contentsOf: MarkdownTranscriptExporter.sidecarURL(for: rec, in: tempRoot),
                              encoding: .utf8)
        XCTAssertTrue(text.contains("**Speaker A:** First sentence."))
        XCTAssertFalse(text.contains("[00:00]"))
    }

    func test_force_writes_even_when_the_setting_is_off() {
        let rec = diarized()
        let wrote = MarkdownTranscriptExporter.writeSidecar(for: rec, in: tempRoot,
                                                            defaults: defaults, force: true)
        XCTAssertTrue(wrote)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: MarkdownTranscriptExporter.sidecarURL(for: rec, in: tempRoot).path))
    }

    func test_write_sidecar_removes_a_stale_file_when_the_transcript_is_gone() throws {
        defaults.set(true, forKey: MarkdownExportSettings.sidecarEnabledKey)
        let rec = diarized()
        MarkdownTranscriptExporter.writeSidecar(for: rec, in: tempRoot, defaults: defaults)
        let url = MarkdownTranscriptExporter.sidecarURL(for: rec, in: tempRoot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        var emptied = rec
        emptied.segments = []
        emptied.fullText = ""
        let wrote = MarkdownTranscriptExporter.writeSidecar(for: emptied, in: tempRoot, defaults: defaults)
        XCTAssertFalse(wrote)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func test_remove_sidecar_deletes_the_file_and_tolerates_absence() throws {
        let rec = diarized()
        let url = MarkdownTranscriptExporter.sidecarURL(for: rec, in: tempRoot)
        try "x".write(to: url, atomically: true, encoding: .utf8)
        MarkdownTranscriptExporter.removeSidecar(for: rec, in: tempRoot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        MarkdownTranscriptExporter.removeSidecar(for: rec, in: tempRoot)   // second call: nothing to remove
    }

    /// Proves the one-line hook in `TranscriptExporter.writeSRT(for:in:)`. That
    /// hook reads `.standard`, which this test only READS (it never writes it):
    /// whatever the host app's value is — OFF upstream, ON in the personal
    /// build — the sidecar must exist exactly when it says so, and the `.srt`
    /// must be written either way.
    func test_write_srt_hook_follows_the_standard_setting() {
        let rec = diarized()
        TranscriptExporter.writeSRT(for: rec, in: tempRoot)
        let srt = tempRoot.appendingPathComponent(rec.subtitleFileName)
        let md = MarkdownTranscriptExporter.sidecarURL(for: rec, in: tempRoot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: srt.path), "the .srt is still written")
        XCTAssertEqual(FileManager.default.fileExists(atPath: md.path),
                       MarkdownExportSettings.current().sidecarEnabled)
    }

    // MARK: - Export command

    func test_write_to_url_includes_the_summary_by_default_mode() throws {
        let rec = diarized(summary: "Short summary.", actionItems: [action("Do it")])
        let url = tempRoot.appendingPathComponent("out.md")
        try MarkdownTranscriptExporter.write(for: rec, to: url, defaults: defaults)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("## Summary\n\nShort summary."))
        XCTAssertTrue(text.contains("- [ ] Do it"))
    }

    func test_write_to_url_excludes_the_summary_in_transcript_mode() throws {
        defaults.set(MarkdownExportSettings.NoteContent.transcript.rawValue,
                     forKey: MarkdownExportSettings.noteContentKey)
        let rec = diarized(summary: "Short summary.", actionItems: [action("Do it")])
        let url = tempRoot.appendingPathComponent("out.md")
        try MarkdownTranscriptExporter.write(for: rec, to: url, defaults: defaults)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("## Summary"))
        XCTAssertFalse(text.contains("Action items"))
        XCTAssertTrue(text.contains("## Transcript"))
    }

    func test_write_to_url_includes_the_summary_in_summary_and_transcript_mode() throws {
        defaults.set(MarkdownExportSettings.NoteContent.summaryAndTranscript.rawValue,
                     forKey: MarkdownExportSettings.noteContentKey)
        let rec = diarized(summary: "Short summary.")
        let url = tempRoot.appendingPathComponent("out.md")
        try MarkdownTranscriptExporter.write(for: rec, to: url, defaults: defaults)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("## Summary"))
    }

    func test_write_to_url_throws_for_an_empty_transcript_and_writes_nothing() {
        let url = tempRoot.appendingPathComponent("none.md")
        XCTAssertThrowsError(try MarkdownTranscriptExporter.write(
            for: undiarized(fullText: "", segments: []), to: url, defaults: defaults)) { error in
            XCTAssertEqual(error.localizedDescription, "No transcript to export.")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Save panel file name

    func test_suggested_file_name_is_the_sanitized_title() {
        var rec = diarized(title: "Q3 plan: a/b")
        XCTAssertEqual(MarkdownTranscriptExportPanel.suggestedFileName(for: rec), "Q3 plan a b.md")
        rec.title = "///"
        XCTAssertEqual(MarkdownTranscriptExportPanel.suggestedFileName(for: rec), "Untitled recording.md")
    }
}
