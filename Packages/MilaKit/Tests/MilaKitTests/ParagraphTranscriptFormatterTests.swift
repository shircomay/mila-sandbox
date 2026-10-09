import XCTest
@testable import MilaKit

private struct TSeg: SpeakerTextSegment {
    var text: String
    var speaker: String?
    var start: Double?
    var end: Double?

    init(_ text: String, _ speaker: String? = nil, start: Double? = nil, end: Double? = nil) {
        self.text = text
        self.speaker = speaker
        self.start = start
        self.end = end
    }
}

final class ParagraphTranscriptFormatterTests: XCTestCase {

    /// Resolves a raw ID through `names`, falling back to the raw ID.
    private func render(_ segments: [TSeg],
                        names: [String: String] = [:],
                        limit: Int = 180,
                        fallback: String = "",
                        timestamps: Bool = false,
                        pause: Double = 0) -> String {
        ParagraphTranscriptFormatter.markdown(
            segments: segments,
            fallback: fallback,
            label: { id in names[id] ?? id },
            start: { $0.start },
            end: { $0.end },
            options: ParagraphTranscriptFormatter.Options(includeTimestamps: timestamps,
                                                          maxWordsPerParagraph: limit,
                                                          pauseBreakSeconds: pause)
        )
    }

    private let timed = [
        TSeg("First sentence.", "a", start: 222.8),
        TSeg("Second sentence.", "a", start: 230.1),
        TSeg("תודה רבה.", "b", start: 248.4),
        TSeg("You're welcome.", "a", start: 253.2),
    ]

    // MARK: grouping and labels (ported from the kit)

    func test_adjacent_grouping_hebrew_and_returning_speaker() {
        let conversation = [TSeg(" First sentence.", "a"), TSeg("Second sentence.", "a"),
                            TSeg("תודה רבה.", "b"), TSeg("You're welcome.", "a")]
        let output = render(conversation, names: ["a": "Shir", "b": "מילה"])
        XCTAssertEqual(output, "**Shir:** First sentence. Second sentence.\n\n**מילה:** תודה רבה.\n\n**Shir:** You're welcome.")
        XCTAssertEqual(output.components(separatedBy: "\n\n").count, 3,
                       "a returning speaker gets a new paragraph")
    }

    func test_no_deduplication() {
        XCTAssertEqual(render([TSeg("Yes.", "a"), TSeg("Yes.", "a")]), "**a:** Yes. Yes.")
    }

    func test_identically_named_speakers_group_together() {
        XCTAssertEqual(render([TSeg("Hi", "a"), TSeg("there", "b")], names: ["a": "Shir", "b": "Shir"]),
                       "**Shir:** Hi there")
    }

    func test_blank_segments_use_fallback() {
        XCTAssertEqual(render([TSeg(" "), TSeg("\n")], fallback: "Fallback text"), "Fallback text")
    }

    func test_unlabelled_segments_have_no_label() {
        XCTAssertEqual(render([TSeg("Hello"), TSeg("world")]), "Hello world")
    }

    func test_unlabelled_segment_in_labelled_transcript_is_unidentified() {
        let out = render([TSeg("Hello", "a"), TSeg("unknown"), TSeg("again", "a")])
        XCTAssertEqual(out, "**a:** Hello\n\n**Unidentified speaker:** unknown\n\n**a:** again")
    }

    func test_length_cap_splits_at_segment_boundary() {
        let out = render([TSeg("one two", "a"), TSeg("three four", "a")], limit: 3)
        XCTAssertEqual(out, "**a:** one two\n\n**a:** three four")
    }

    func test_single_long_segment_is_never_split() {
        let out = render([TSeg("one two three four five six", "a")], limit: 3)
        XCTAssertEqual(out, "**a:** one two three four five six")
    }

    func test_whitespace_runs_collapse() {
        XCTAssertEqual(render([TSeg("a\nb\tc", "a")]), "**a:** a b c")
    }

    func test_blank_label_falls_back_to_raw_id() {
        let out = ParagraphTranscriptFormatter.markdown(
            segments: [TSeg("test", "a")],
            fallback: "",
            label: { _ in " \n " },
            start: { $0.start },
            end: { $0.end },
            options: ParagraphTranscriptFormatter.Options(includeTimestamps: false)
        )
        XCTAssertEqual(out, "**a:** test")
    }

    func test_empty_transcript_is_empty() {
        XCTAssertEqual(render([]), "")
    }

    func test_mixed_languages_keep_order() {
        XCTAssertEqual(render([TSeg("שלום English שלום", "a")]), "**a:** שלום English שלום")
        XCTAssertEqual(render([TSeg("Hello", "a"), TSeg("שלום", "a"), TSeg("again", "a")]),
                       "**a:** Hello שלום again")
    }

    func test_segment_order_is_preserved_not_sorted_by_time() {
        let out = render([TSeg("first", "a", start: 20), TSeg("reply", "b", start: 19)], timestamps: true)
        XCTAssertEqual(out, "**[00:20] a:** first\n\n**[00:19] b:** reply")
    }

    // MARK: verbatim text, label escaping, block guard

    func test_spoken_text_is_verbatim() {
        let text = "e-mail Q&A *laughs* [Music] <b>x</b> # 1. a_b | c"
        XCTAssertEqual(render([TSeg(text, "a")]), "**a:** \(text)")
        XCTAssertEqual(render([TSeg(text, "a", start: 5)], timestamps: true), "**[00:05] a:** \(text)")
    }

    func test_label_is_escaped_for_bold_context() {
        XCTAssertEqual(render([TSeg("hi", "x")], names: ["x": "A*B"]), "**A\\*B:** hi")
        XCTAssertEqual(render([TSeg("hi", "x")], names: ["x": "a_b [c] `d` \\e"]),
                       "**a\\_b \\[c\\] \\`d\\` \\\\e:** hi")
    }

    func test_block_guard_on_unlabelled_untimed_text() {
        XCTAssertEqual(render([TSeg("# not a heading")]), "\\# not a heading")
        XCTAssertEqual(render([TSeg("1. item")]), "1\\. item")
        XCTAssertEqual(render([TSeg("12) item")]), "12\\) item")
        XCTAssertEqual(render([TSeg("> quote")]), "\\> quote")
        XCTAssertEqual(render([TSeg("- dash")]), "\\- dash")
        XCTAssertEqual(render([TSeg("+ plus")]), "\\+ plus")
        XCTAssertEqual(render([TSeg("* star")]), "\\* star")
        XCTAssertEqual(render([TSeg("=== rule")]), "\\=== rule")
        XCTAssertEqual(render([TSeg("| cell")]), "\\| cell")
        XCTAssertEqual(render([TSeg("```code")]), "\\```code")
        XCTAssertEqual(render([TSeg("~~~code")]), "\\~~~code")
    }

    func test_block_guard_leaves_plain_text_alone() {
        XCTAssertEqual(render([TSeg("2024 was a year")]), "2024 was a year")
        XCTAssertEqual(render([TSeg("3.5 percent")]), "3.5 percent")
        XCTAssertEqual(render([TSeg("1.")]), "1.")
    }

    func test_block_guard_not_applied_when_a_label_or_timestamp_leads_the_line() {
        XCTAssertEqual(render([TSeg("# heading", "a")]), "**a:** # heading")
        XCTAssertEqual(render([TSeg("# heading", start: 1)], timestamps: true), "**[00:01]** # heading")
    }

    // MARK: timestamps (ported from the kit)

    func test_exact_paragraph_timestamps() {
        let stamped = render(timed, names: ["a": "Shir", "b": "מילה"], timestamps: true)
        XCTAssertEqual(stamped, "**[03:42] Shir:** First sentence. Second sentence.\n\n**[04:08] מילה:** תודה רבה.\n\n**[04:13] Shir:** You're welcome.")
        XCTAssertFalse(stamped.contains("[03:50]"), "no timestamp on the second sentence")
        XCTAssertFalse(stamped.contains("-->"), "no SRT ranges")
    }

    func test_long_turn_split_receives_its_own_actual_start() {
        let segs = [TSeg("one two", "a", start: 3), TSeg("three four", "a", start: 8)]
        XCTAssertEqual(render(segs, limit: 3, timestamps: true),
                       "**[00:03] a:** one two\n\n**[00:08] a:** three four")
        XCTAssertEqual(render(segs, limit: 0, timestamps: true),
                       "**[00:03] a:** one two three four")
    }

    func test_unlabelled_timed_paragraph() {
        XCTAssertEqual(render([TSeg("Hello", start: 62), TSeg("world", start: 65)], timestamps: true),
                       "**[01:02]** Hello world")
    }

    func test_merged_names_retain_first_timestamp() {
        let segs = [TSeg("Hi", "a", start: 1), TSeg("there", "b", start: 2)]
        XCTAssertEqual(render(segs, names: ["a": "Shir", "b": "Shir"], timestamps: true),
                       "**[00:01] Shir:** Hi there")
    }

    func test_blank_segments_do_not_supply_the_paragraph_start() {
        let segs = [TSeg(" ", "a", start: 1), TSeg("First words", "a", start: 17.5)]
        XCTAssertEqual(render(segs, timestamps: true), "**[00:17] a:** First words")
    }

    func test_never_borrow_a_later_segments_timestamp() {
        let segs = [TSeg("Missing start", "a"), TSeg("Later text", "a", start: 22)]
        XCTAssertEqual(render(segs, timestamps: true),
                       "**[time unavailable] a:** Missing start Later text")
    }

    func test_invalid_time_is_explicit_not_zero() {
        XCTAssertEqual(render([TSeg("invalid", "a", start: -.infinity)], timestamps: true),
                       "**[time unavailable] a:** invalid")
    }

    func test_unknown_speaker_is_not_invented_with_timestamps() {
        let segs = [TSeg("unknown", start: 15), TSeg("named", "a", start: 18)]
        XCTAssertEqual(render(segs, timestamps: true),
                       "**[00:15] Unidentified speaker:** unknown\n\n**[00:18] a:** named")
    }

    func test_timestamp_fallbacks() {
        XCTAssertEqual(render([], fallback: "Plain text only", timestamps: true),
                       "**[time unavailable]** Plain text only")
        XCTAssertEqual(render([], timestamps: true), "")
        XCTAssertEqual(render([], fallback: "# plain", timestamps: false), "\\# plain")
    }

    func test_timestamp_toggle_does_not_change_the_grouping() {
        let on = render(timed, timestamps: true)
        let off = render(timed, timestamps: false)
        XCTAssertEqual(on.components(separatedBy: "\n\n").count,
                       off.components(separatedBy: "\n\n").count)
    }

    func test_disabled_timestamps_and_pauses_do_not_read_timing() {
        var reads = 0
        _ = ParagraphTranscriptFormatter.markdown(
            segments: timed,
            fallback: "",
            label: { $0 },
            start: { segment in reads += 1; return segment.start },
            end: { segment in reads += 1; return segment.end },
            options: ParagraphTranscriptFormatter.Options(includeTimestamps: false,
                                                          maxWordsPerParagraph: 180,
                                                          pauseBreakSeconds: 0)
        )
        XCTAssertEqual(reads, 0)
    }

    func test_timestamp_function() {
        let f = ParagraphTranscriptFormatter.timestamp
        XCTAssertEqual(f(0), "00:00")
        XCTAssertEqual(f(59.9999), "00:59", "floors below a minute boundary")
        XCTAssertEqual(f(60), "01:00")
        XCTAssertEqual(f(3599.9999), "59:59", "floors below an hour boundary")
        XCTAssertEqual(f(3600), "01:00:00")
        XCTAssertEqual(f(3723.9), "01:02:03")
        XCTAssertEqual(f(360000), "100:00:00", "hours do not wrap")
        XCTAssertNil(f(nil))
        XCTAssertNil(f(-1))
        XCTAssertNil(f(.nan))
        XCTAssertNil(f(.infinity))
        XCTAssertNil(f(Double.greatestFiniteMagnitude))
    }

    func test_default_options_put_timestamps_on() {
        let out = ParagraphTranscriptFormatter.markdown(
            segments: timed, fallback: "",
            label: { $0 }, start: { $0.start }, end: { $0.end })
        XCTAssertTrue(out.hasPrefix("**[03:42] a:**"))
        XCTAssertEqual(ParagraphTranscriptFormatter.Options(),
                       ParagraphTranscriptFormatter.Options(includeTimestamps: true,
                                                            maxWordsPerParagraph: 180,
                                                            pauseBreakSeconds: 4.0))
    }

    func test_hour_timestamp_in_a_paragraph() {
        XCTAssertEqual(render([TSeg("late", "a", start: 3723.9)], timestamps: true),
                       "**[01:02:03] a:** late")
    }

    // MARK: pause breaks

    func test_pause_break_splits_a_same_speaker_turn() {
        let segs = [TSeg("before", "a", start: 0, end: 2), TSeg("after", "a", start: 10, end: 12)]
        XCTAssertEqual(render(segs, timestamps: true, pause: 4),
                       "**[00:00] a:** before\n\n**[00:10] a:** after")
    }

    func test_pause_break_off_keeps_one_paragraph() {
        let segs = [TSeg("before", "a", start: 0, end: 2), TSeg("after", "a", start: 10, end: 12)]
        XCTAssertEqual(render(segs, timestamps: true, pause: 0),
                       "**[00:00] a:** before after")
    }

    func test_pause_shorter_than_threshold_does_not_break() {
        let segs = [TSeg("before", "a", start: 0, end: 2), TSeg("after", "a", start: 5.9, end: 7)]
        XCTAssertEqual(render(segs, timestamps: true, pause: 4), "**[00:00] a:** before after")
    }

    func test_pause_exactly_at_threshold_breaks() {
        let segs = [TSeg("before", "a", start: 0, end: 2), TSeg("after", "a", start: 6, end: 7)]
        XCTAssertEqual(render(segs, timestamps: true, pause: 4),
                       "**[00:00] a:** before\n\n**[00:06] a:** after")
    }

    func test_pause_break_works_without_timestamps() {
        let segs = [TSeg("before", "a", start: 0, end: 2), TSeg("after", "a", start: 10, end: 12)]
        XCTAssertEqual(render(segs, timestamps: false, pause: 4), "**a:** before\n\n**a:** after")
    }

    func test_pause_break_ignored_when_times_are_not_finite() {
        let nanStart = [TSeg("before", "a", start: 0, end: 2), TSeg("after", "a", start: .nan, end: 12)]
        XCTAssertEqual(render(nanStart, timestamps: false, pause: 4), "**a:** before after")
        let infEnd = [TSeg("before", "a", start: 0, end: .infinity), TSeg("after", "a", start: 100, end: 101)]
        XCTAssertEqual(render(infEnd, timestamps: false, pause: 4), "**a:** before after")
        let missing = [TSeg("before", "a"), TSeg("after", "a", start: 100)]
        XCTAssertEqual(render(missing, timestamps: false, pause: 4), "**a:** before after")
    }

    func test_pause_is_measured_from_the_previous_non_empty_segment() {
        let segs = [TSeg("before", "a", start: 0, end: 2),
                    TSeg("  ", "a", start: 50, end: 60),
                    TSeg("after", "a", start: 3, end: 4)]
        XCTAssertEqual(render(segs, timestamps: false, pause: 4), "**a:** before after")
    }

    // MARK: paragraphs() and the lazy fallback

    func test_paragraphs_expose_label_start_and_text() {
        let paras = ParagraphTranscriptFormatter.paragraphs(
            segments: timed,
            label: { $0.uppercased() },
            start: { $0.start },
            end: { $0.end },
            options: ParagraphTranscriptFormatter.Options(pauseBreakSeconds: 0)
        )
        XCTAssertEqual(paras, [
            ParagraphTranscriptFormatter.Paragraph(label: "A", startSeconds: 222.8,
                                                   text: "First sentence. Second sentence."),
            ParagraphTranscriptFormatter.Paragraph(label: "B", startSeconds: 248.4, text: "תודה רבה."),
            ParagraphTranscriptFormatter.Paragraph(label: "A", startSeconds: 253.2, text: "You're welcome."),
        ])
    }

    func test_paragraph_label_is_nil_when_nothing_is_labelled() {
        let paras = ParagraphTranscriptFormatter.paragraphs(
            segments: [TSeg("one"), TSeg("two")],
            label: { $0 }, start: { $0.start }, end: { $0.end })
        XCTAssertEqual(paras.count, 1)
        XCTAssertNil(paras[0].label)
    }

    func test_fallback_is_not_evaluated_when_segments_exist() {
        var fallbackReads = 0
        func readFallback() -> String { fallbackReads += 1; return "fallback" }
        _ = ParagraphTranscriptFormatter.markdown(
            segments: timed, fallback: readFallback(),
            label: { $0 }, start: { $0.start }, end: { $0.end })
        XCTAssertEqual(fallbackReads, 0)

        _ = ParagraphTranscriptFormatter.markdown(
            segments: [TSeg("  ")], fallback: readFallback(),
            label: { $0 }, start: { $0.start }, end: { $0.end })
        XCTAssertEqual(fallbackReads, 1, "evaluated exactly once when there is nothing else to render")
    }
}
