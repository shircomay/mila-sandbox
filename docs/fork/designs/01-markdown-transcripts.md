# Spec 01 — Paragraph Markdown transcripts for a knowledge base

**Agent:** Claude Sonnet · **effort: high** · read `00-overview.md` first.

## Goal

The owner feeds Mila transcripts into a knowledge base. Today Mila writes an
`.srt` (subtitle cues, one per sentence) next to each recording, and the
Obsidian-vault exporter writes the AI summary *instead of* the transcript
whenever a summary exists. We want:

1. A `.md` transcript written next to each recording's `.srt`, grouped into
   speaker paragraphs with one timestamp per paragraph.
2. A content choice for the existing vault/notes exporter: summary-else-transcript
   (upstream behaviour), full transcript, or summary + full transcript.
3. An "Export Transcript (.md)…" command next to "Export Subtitles (.srt)…".
4. A way to backfill `.md` files for existing recordings.

## Output contract

Synthetic example (English + Hebrew, diarized, one speaker named):

```markdown
---
title: "Weekly sync"
date: "2026-10-09T13:01:00+03:00"
duration: "00:42:17"
language: "he"
source: "meeting"
app: "Zoom"
speakers: ["Shir", "דובר ב׳"]
recording_id: "6F1C…"
generator: "mila-fork paragraph-transcript v1"
---

# Weekly sync

## Transcript

**[00:00] Shir:** First sentence. Second sentence stays in the same paragraph because the same person keeps talking.

**[00:12] דובר ב׳:** תשובה של הדובר השני. Mixed English stays in its original order.

**[01:02:03] Shir:** After an hour the timestamp gains an hours field.
```

Rules:
- Front matter values are JSON-encoded strings (valid YAML, Hebrew-safe — reuse
  the kit's `JSONEncoder` trick). `app` only when `recording.appName` is
  non-empty. `speakers` = display labels in order of first appearance; omit the
  key when there are no speaker labels. `duration` formatted `HH:MM:SS` from
  `recording.duration`.
- `# <title>` = single-line title, `Untitled recording` when empty.
- When the summary is included and non-empty: `## Summary` + summary text
  verbatim, then `## Transcript`. When action items exist and the summary is
  included: `## Action items` checklist after the transcript, same format as
  `ObsidianExporter.markdown(for:)` (`- [ ] text`).
- Paragraph line: `**[MM:SS] Label:** text`. Unlabelled transcript (no segment has
  a speaker): `**[MM:SS]** text`. Timestamps off: `**Label:** text` / `text`.
  Paragraphs separated by one blank line. File ends with a single `\n`.
- Empty transcript (no non-empty segments and empty `fullText`) → no file is
  written / export reports "No transcript to export."

## Component A — MilaKit formatter (pure, dependency-free)

New file `Packages/MilaKit/Sources/MilaKit/ParagraphTranscriptFormatter.swift`.
Start from the kit's `KnowledgeBaseTranscript.swift`
(`/tmp/claude-0/-home-user-mila-sandbox/941088dd-746a-56b6-a96c-fa0440056ae3/scratchpad/kit/mila-customisation-kit-v3/swift/MilaKit/KnowledgeBaseTranscript.swift`)
and its tests (`.../tests/main.swift`), with these changes:

```swift
public enum ParagraphTranscriptFormatter {
    public struct Options: Equatable, Sendable {
        public var includeTimestamps: Bool = true
        public var maxWordsPerParagraph: Int = 180   // 0 = no cap
        public var pauseBreakSeconds: Double = 4.0  // 0 = never break on pauses
        public init(...)                              // memberwise with defaults
    }
    public struct Paragraph: Equatable, Sendable {
        public var label: String?        // nil when the transcript has no speaker labels
        public var startSeconds: Double? // first non-empty segment's start
        public var text: String
    }
    public static func paragraphs<S: SpeakerTextSegment>(
        segments: [S],
        label: (String) -> String,            // raw speaker ID -> display label
        start: (S) -> Double?,
        end: (S) -> Double?,
        options: Options = .init()
    ) -> [Paragraph]
    public static func markdown<S: SpeakerTextSegment>(
        segments: [S],
        fallback: @autoclosure () -> String,  // evaluated ONLY when no non-empty segment exists
        label: (String) -> String,
        start: (S) -> Double?,
        end: (S) -> Double?,
        options: Options = .init()
    ) -> String
    public static func timestamp(_ seconds: Double?) -> String?  // kit semantics, unchanged
}
```

Paragraph rules (in order, evaluated per non-empty segment):
1. Text = segment text with all whitespace runs collapsed to one space, trimmed.
   Skip empty results.
2. Resolved label = `segment.speaker.map(label)`; if the transcript has ANY
   labelled segment, an unlabelled segment's label is `"Unidentified speaker"`;
   if it has none, labels are nil throughout. Empty/whitespace label → raw ID.
3. Start a new paragraph when: the resolved label differs from the current
   paragraph's; OR `maxWordsPerParagraph > 0` and adding this segment would exceed
   it (split only at segment boundaries; a single long segment is never split);
   OR `pauseBreakSeconds > 0` and `start(current) - end(previous) >= pauseBreakSeconds`
   (only when both values are finite).
4. Paragraph start = `start()` of its FIRST non-empty segment, captured even when
   nil/invalid — never borrowed from a later segment (kit test "never borrow").
5. Only adjacent segments group; a returning speaker gets a new paragraph.
   Segment order is preserved exactly (no sorting by time).

Rendering:
- Spoken text is emitted **verbatim** (after whitespace collapse) — no
  backslash escaping, no HTML entities. This is the deliberate change from the
  kit (see overview).
- Labels are escaped for bold context: backslash-escape `\`, `*`, `_`, `[`, `]`,
  `` ` `` in the label only.
- Block-syntax guard: only when a paragraph line would START with spoken text
  (no label and no timestamp), and that text begins with `#`, `>`, `-`, `+`, `*`,
  `=`, `|`, `` ``` ``, `~~~`, or `\d+[.)] `, insert a single backslash before the
  first character (for the ordered-list case, before the `.`/`)`).
- Invalid timestamps render `[time unavailable]` (kit behaviour).
- No-segment fallback: `fallback()` collapsed; empty → `""`; otherwise one
  paragraph `**[time unavailable]** text` (timestamps on) or the block-guarded
  text (timestamps off).

Tests: new file in the existing MilaKit test target (find its name under
`Packages/MilaKit/Tests/`), `ParagraphTranscriptFormatterTests.swift`. Port every
kit assertion as XCTest, updating the expectations that change because of
verbatim text / label escaping, and add: pause break on/off; pause break ignored
when times are non-finite; label escaping (`"A*B"` → `**A\*B:**`); verbatim text
(`"e-mail Q&A *laughs* [Music]"` unchanged); block guard on unlabelled untimed
`"# not a heading"` and `"1. item"`; fallback not evaluated when segments exist
(count calls with a closure side effect); Hebrew + English order preserved.

MilaKit must stay dependency-free and must not import TranscriptionCore.

## Component B — app exporter

New file `Mila/Transcription/MarkdownTranscriptExporter.swift`:

```swift
enum MarkdownTranscriptExporter {
    static func document(for recording: Recording,
                         includeSummary: Bool,
                         timestamps: Bool = true) -> String      // "" when no transcript
    static func sidecarURL(for recording: Recording, in directory: URL) -> URL
        // (audioFileName minus extension) + ".md", same derivation as the .srt
    static func writeSidecar(for recording: Recording, in directory: URL,
                             defaults: UserDefaults = .standard)
        // no-op unless MarkdownExportSettings says sidecarEnabled; never throws;
        // mirrors TranscriptExporter.writeSRT(for:in:) error handling + log privacy
    static func removeSidecar(for recording: Recording, in directory: URL,
                              fileManager: FileManager = .default)
    static func write(for recording: Recording, to url: URL, defaults: UserDefaults = .standard) throws
        // Export… command; includes summary per the noteContent setting
        // (summaryElseTranscript and summaryAndTranscript both include it; transcript excludes)
}
```

- Use `recording.segments` with `label: { $0.displaySpeakerName(names: recording.speakerNames, language: recording.language) }`,
  `start: { $0.start }`, `end: { $0.end }`. Read `Mila/Transcription/SpeakerLabel.swift`
  and `TranscriptExporter.srtBody` first: if the SRT path normalizes segments
  (e.g. `normalized(in:)`) or treats speakers specially, do the same so the `.md`
  and `.srt` agree on labels.
- Fallback text = `recording.fullText` (an autoclosure; do not hoist).
- Write atomically, UTF-8.

## Component C — settings

New file `Mila/Models/MarkdownExportSettings.swift`: an `ObservableObject`
following the pattern of an existing small settings class (read
`ObsidianVaultSettings.swift` and `RecordingStorageSettings.swift`).

- `@Published var sidecarEnabled: Bool` ↔ `markdownExport.sidecarEnabled` (code default false)
- `@Published var paragraphTimestamps: Bool` ↔ `markdownExport.paragraphTimestamps` (default true)
- `@Published var noteContent: NoteContent` ↔ `markdownExport.noteContent`
  (`enum NoteContent: String, CaseIterable { case summaryElseTranscript, transcript, summaryAndTranscript }`, default `.summaryElseTranscript`)
- Static readers for non-UI call sites: `static func current(_ defaults: UserDefaults = .standard) -> Snapshot`
  returning the three values, so static exporters need no object plumbing.
- `init(defaults: UserDefaults = .standard)`. Keys exactly as in the overview table.

Create it in `MilaApp.init()` as a `@StateObject` and inject it on the main window
and the Settings scene (follow how `obsidianVaultSettings` is done).

## Component D — hooks in upstream files (keep each tiny, mark `// FORK:`)

1. `TranscriptExporter.writeSRT(for:in:)` — after the SRT write, call
   `MarkdownTranscriptExporter.writeSidecar(for: recording, in: directory)`. This
   one hook covers all `RecordingStore` call sites (completion, speaker rename,
   edits, re-transcription). Verify by reading each call site.
2. `RecordingStore` — wherever the `.srt` sidecar is removed (`subtitleURL`
   removal sites, ~lines 1015 and 1054) also call `removeSidecar`. Check
   `relocateRecordings` / any rename-on-title-change path: if `.srt`/`.txt`
   sidecars are moved or renamed there, move/rename the `.md` the same way.
3. `ObsidianExporter.markdown(for:)` — add a defaulted parameter
   `content: MarkdownExportSettings.NoteContent = .summaryElseTranscript`. For
   `.summaryElseTranscript` the upstream code path runs unchanged. For the other two,
   return the vault note built from `MarkdownTranscriptExporter` (title heading,
   optional `## Summary`, `## Transcript` paragraphs, `## Action items`). Keep the
   vault note WITHOUT YAML front matter only if existing `ObsidianExporterTests`
   would otherwise break — otherwise include it (Obsidian reads front matter). In
   `writeNote`, pass `MarkdownExportSettings.current(defaults).noteContent` using the
   exporter's injected `defaults`. Also check `hasContent(_:)`: a recording with
   segments but an empty `fullText` sidecar must still count as having content in
   the transcript modes.
4. Export command — next to every "Export Subtitles (.srt)…" button
   (`RecordingContextMenu.swift`, `RecordingDetailView.swift`; check
   `LiveAIRecordingView.swift` too) add "Export Transcript (.md)…" using the same
   `NSSavePanel` pattern, default filename = sanitized title + `.md`, calling
   `MarkdownTranscriptExporter.write(for:to:)`. Put the new panel helper in a new
   file if it can be shared, and keep the per-view hook to the button itself.
5. Settings UI — new `Mila/Views/MarkdownExportSettingsSection.swift`, inserted
   with one line into the Storage settings tab (`StorageSettingsTab.swift`, near
   the Obsidian section):
   - Toggle "Save a Markdown transcript (.md) next to each recording"
   - Toggle "Timestamp each paragraph"
   - Picker "Notes in your vault contain": Summary (or transcript if no summary) /
     Full transcript / Summary + full transcript
   - Button "Write Markdown for existing recordings" → iterates
     `store.recordings` (skip trashed and not-completed), calls `writeSidecar`
     with sidecar forced on (add an `force: Bool = false` parameter), shows a count.
     Run it off the main thread if it does file I/O for many recordings
     (follow how "Sync existing transcripts" does its work).
   - One-line footnote: the `.srt` is still written because Mila's subtitle-video
     feature uses it.

## Tests (new files only, custom `UserDefaults` suites)

- `MilaTests/MarkdownTranscriptExporterTests.swift`: document shape (front matter
  keys, title fallback, summary on/off, action items, Hebrew speaker label via
  `displaySpeakerName`, assigned name wins, unlabelled transcript, empty →
  `""`), sidecar URL derivation, `writeSidecar` no-op when disabled and writes
  when enabled (temp dir), `removeSidecar`.
- `MilaTests/MarkdownExportSettingsTests.swift`: defaults, persistence, raw values.
- `MilaTests/ObsidianNoteContentModeTests.swift`: the three modes through
  `ObsidianExporter.markdown(for:content:)`; default argument == upstream output.
- Before adding any hook, read the existing tests that touch that code
  (`TranscriptExporterTests`, `RecordingStoreTests`, `ObsidianExporterTests`,
  `ObsidianExportSequencingTests`) and make sure none of them would observe the
  hook (e.g. a test listing a directory's files would see an extra `.md` if the
  test host had the sidecar enabled). The test host is the app and the personal
  build registers `markdownExport.sidecarEnabled = true` on `.standard`; any code
  path a test drives with `.standard` defaults will therefore see it ON. If that
  would break an upstream test, thread an injected `UserDefaults` through instead.

## Deliverables

- The files above, `FORK.md` ledger rows for each upstream file touched.
- `docs/fork/examples/paragraph-transcript.md`: a synthetic example document
  generated by hand from the rules (no real meeting content).

## Acceptance

Fork CI green: MilaKit `swift test` passes including the new tests; the app
builds; full `MilaTests` passes with no upstream test edited.
