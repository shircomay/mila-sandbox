import Foundation

/// Renders a transcript as speaker paragraphs with one timestamp per paragraph,
/// for knowledge bases that ingest the Markdown raw (RAG, search, notes).
///
/// Pure and dependency-free like `TranscriptFormatter`: it only needs the
/// `SpeakerTextSegment` shape plus closures for the things MilaKit cannot know
/// (display label for a raw speaker ID, segment start/end times).
///
/// Output shape: `**[MM:SS] Label:** paragraph text`, paragraphs separated by
/// one blank line. Spoken text is emitted verbatim (whitespace collapsed to
/// single spaces) — no backslash escaping and no HTML entities, because the
/// result is meant to be read as plain text by tools, where `e\-mail` and
/// `Q&amp;A` are corruption. Only labels (which sit inside `**…**`) and
/// line-start block syntax in label-less lines are guarded.
public enum ParagraphTranscriptFormatter {

    public struct Options: Equatable, Sendable {
        /// Prefix each paragraph with `[MM:SS]` (or `[H:MM:SS]` past one hour).
        public var includeTimestamps: Bool
        /// Soft cap on words per paragraph, applied only at segment
        /// boundaries (a single long segment is never split). 0 = no cap.
        public var maxWordsPerParagraph: Int
        /// Start a new paragraph when the silence between two adjacent
        /// segments of the same speaker is at least this many seconds.
        /// 0 = never break on pauses.
        public var pauseBreakSeconds: Double

        public init(includeTimestamps: Bool = true,
                    maxWordsPerParagraph: Int = 180,
                    pauseBreakSeconds: Double = 4.0) {
            self.includeTimestamps = includeTimestamps
            self.maxWordsPerParagraph = maxWordsPerParagraph
            self.pauseBreakSeconds = pauseBreakSeconds
        }
    }

    public struct Paragraph: Equatable, Sendable {
        /// Display label; nil when the transcript has no speaker labels at all.
        public var label: String?
        /// Start of the paragraph's FIRST non-empty segment. Nil when that
        /// segment had no usable start — never borrowed from a later segment.
        public var startSeconds: Double?
        public var text: String

        public init(label: String?, startSeconds: Double?, text: String) {
            self.label = label
            self.startSeconds = startSeconds
            self.text = text
        }
    }

    /// Label given to a segment with no speaker in a transcript where other
    /// segments do have one. Never guessed from neighbours.
    public static let unidentifiedLabel = "Unidentified speaker"

    // MARK: - Grouping

    /// Group `segments` into paragraphs. Only ADJACENT segments group, and the
    /// input order is preserved exactly (no sorting by time).
    public static func paragraphs<S: SpeakerTextSegment>(
        segments: [S],
        label: (String) -> String,
        start: (S) -> Double?,
        end: (S) -> Double?,
        options: Options = Options()
    ) -> [Paragraph] {
        // A segment whose speaker is empty counts as unlabelled, matching
        // how the app treats an empty ID elsewhere.
        func rawSpeaker(_ segment: S) -> String? {
            guard let raw = segment.speaker,
                  !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return raw
        }

        var items: [(segment: S, text: String)] = []
        for segment in segments {
            let text = oneLine(segment.text)
            if !text.isEmpty { items.append((segment, text)) }
        }
        guard !items.isEmpty else { return [] }

        let anyLabelled = items.contains { rawSpeaker($0.segment) != nil }
        let needStart = options.includeTimestamps || options.pauseBreakSeconds > 0
        let needEnd = options.pauseBreakSeconds > 0

        var result: [Paragraph] = []
        var active = false
        var currentLabel: String?
        var currentStart: Double?
        var currentParts: [String] = []
        var currentWords = 0
        var previousEnd: Double?

        func flush() {
            guard active else { return }
            result.append(Paragraph(label: currentLabel,
                                    startSeconds: currentStart,
                                    text: currentParts.joined(separator: " ")))
            currentParts.removeAll(keepingCapacity: true)
            currentWords = 0
            currentStart = nil
            active = false
        }

        for item in items {
            let segment = item.segment
            let resolved: String?
            if let raw = rawSpeaker(segment) {
                let shown = oneLine(label(raw))
                resolved = shown.isEmpty ? raw : shown
            } else {
                resolved = anyLabelled ? unidentifiedLabel : nil
            }
            let words = item.text.split(whereSeparator: { $0.isWhitespace }).count
            let segStart: Double? = needStart ? start(segment) : nil
            let segEnd: Double? = needEnd ? end(segment) : nil

            if active {
                var breakHere = resolved != currentLabel
                if !breakHere, options.maxWordsPerParagraph > 0,
                   currentWords + words > options.maxWordsPerParagraph {
                    breakHere = true
                }
                if !breakHere, options.pauseBreakSeconds > 0,
                   let s = segStart, let e = previousEnd,
                   s.isFinite, e.isFinite,
                   s - e >= options.pauseBreakSeconds {
                    breakHere = true
                }
                if breakHere { flush() }
            }

            if !active {
                active = true
                currentLabel = resolved
                // Captured once, even when absent or invalid: a later
                // segment's time must never stand in for this paragraph's.
                currentStart = options.includeTimestamps ? segStart : nil
            }
            currentParts.append(item.text)
            currentWords += words
            previousEnd = segEnd
        }
        flush()
        return result
    }

    // MARK: - Rendering

    /// The Markdown body: paragraphs joined by one blank line, no trailing
    /// newline. Empty string when there is nothing to render.
    ///
    /// `fallback` is an `@autoclosure` and is evaluated ONLY when no
    /// non-empty segment exists (it may read a file); do not hoist it.
    public static func markdown<S: SpeakerTextSegment>(
        segments: [S],
        fallback: @autoclosure () -> String,
        label: (String) -> String,
        start: (S) -> Double?,
        end: (S) -> Double?,
        options: Options = Options()
    ) -> String {
        let grouped = paragraphs(segments: segments, label: label,
                                 start: start, end: end, options: options)
        if grouped.isEmpty {
            let text = oneLine(fallback())
            guard !text.isEmpty else { return "" }
            return options.includeTimestamps
                ? "**[time unavailable]** \(text)"
                : guardBlockSyntax(text)
        }
        return grouped
            .map { render($0, includeTimestamps: options.includeTimestamps) }
            .joined(separator: "\n\n")
    }

    /// Recording-relative start time, floored to a whole second (never
    /// rounded up). `MM:SS` below one hour, `HH:MM:SS` thereafter; hours do
    /// not wrap. Invalid or missing values stay unknown (nil).
    public static func timestamp(_ seconds: Double?) -> String? {
        guard let seconds, seconds.isFinite, seconds >= 0,
              seconds < Double(Int.max) else { return nil }
        let whole = Int(seconds.rounded(.down))
        func two(_ value: Int) -> String {
            let text = String(value)
            return text.count < 2 ? "0" + text : text
        }
        let hours = whole / 3600
        let minutes = (whole % 3600) / 60
        let remainder = whole % 60
        if hours == 0 { return "\(two(minutes)):\(two(remainder))" }
        return "\(two(hours)):\(two(minutes)):\(two(remainder))"
    }

    /// Collapse every whitespace run (including newlines) to one space and trim.
    public static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    // MARK: - Private helpers

    private static func render(_ paragraph: Paragraph, includeTimestamps: Bool) -> String {
        let stamp: String? = includeTimestamps
            ? "[\(timestamp(paragraph.startSeconds) ?? "time unavailable")]"
            : nil
        let text = paragraph.text
        if let label = paragraph.label {
            let shown = escapeLabel(label)
            if let stamp = stamp {
                return "**\(stamp) \(shown):** \(text)"
            }
            return "**\(shown):** \(text)"
        }
        if let stamp = stamp {
            return "**\(stamp)** \(text)"
        }
        return guardBlockSyntax(text)
    }

    /// Escape the characters that would end or disturb bold emphasis. Applies
    /// to labels only; spoken text is never escaped.
    private static func escapeLabel(_ label: String) -> String {
        let special: [Character] = ["\\", "*", "_", "[", "]", "`"]
        var out = ""
        for character in label {
            if special.contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }

    /// For a line that STARTS with spoken text (no label, no timestamp): put
    /// one backslash before a leading character that would turn the line into
    /// a heading, quote, list item, rule, table row or fence. For an ordered
    /// list marker (`12. `, `3) `) the backslash goes before the `.` / `)`.
    private static func guardBlockSyntax(_ text: String) -> String {
        guard let first = text.first else { return text }
        let blockStarts: [Character] = ["#", ">", "-", "+", "*", "=", "|"]
        if blockStarts.contains(first) || text.hasPrefix("```") || text.hasPrefix("~~~") {
            return "\\" + text
        }
        var index = text.startIndex
        while index < text.endIndex, ("0"..."9").contains(text[index]) {
            index = text.index(after: index)
        }
        guard index > text.startIndex, index < text.endIndex,
              text[index] == "." || text[index] == ")" else { return text }
        let afterMarker = text.index(after: index)
        guard afterMarker < text.endIndex, text[afterMarker] == " " else { return text }
        return String(text[..<index]) + "\\" + String(text[index...])
    }
}
