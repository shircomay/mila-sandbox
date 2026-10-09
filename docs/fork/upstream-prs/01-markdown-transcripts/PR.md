# feat(export): speaker-paragraph Markdown transcripts, vault note content choice, Export Transcript (.md)…

Closes #ISSUE_NUMBER

## What & why

The `.srt` Mila writes next to each recording is subtitle cues, one per
sentence, which is right for subtitling video but awkward to read or ingest as
text. And the Obsidian exporter writes the AI summary *instead of* the
transcript whenever a summary exists, so people who keep their notes in a
knowledge base never get the full transcript there. This PR adds a readable
Markdown transcript and puts the user in control of what vault notes contain.
Everything is opt-in; with the defaults, Mila behaves as it did.

**Output.** Consecutive segments from the same speaker become one paragraph
with one timestamp (the paragraph's first segment's real start). Synthetic
example, English and Hebrew:

```markdown
---
title: "Weekly sync"
date: "2026-10-09T13:01:00+03:00"
duration: "01:05:30"
language: "he"
source: "meeting"
app: "Zoom"
speakers: ["Dana", "דובר ב׳"]
recording_id: "6F1C0000-0000-0000-0000-000000000001"
generator: "mila paragraph-transcript v1"
---

# Weekly sync

## Transcript

**[00:00] Dana:** First sentence. Second sentence stays in the same paragraph because the same person keeps talking.

**[00:12] דובר ב׳:** תשובה של הדובר השני. Mixed English stays in its original order.

**[01:02:03] Dana:** After an hour the timestamp gains an hours field.
```

- Speaker labels come from `displaySpeakerName(names:language:)`, so the `.md`,
  the UI and the `.srt` agree ("Speaker A" / "דובר א׳", or the name the user
  assigned).
- A paragraph also starts after a pause of 4 s or more, or when adding the next
  segment would pass a soft 180-word cap (only at segment boundaries; a single
  long segment is never split). Without this, a recording with no speaker
  labels would be one wall of text.
- Spoken text is emitted verbatim (whitespace collapsed). It is not
  backslash-escaped or HTML-encoded, because the file is read raw by tools
  (`e-mail` and `Q&A` stay as spoken). Only speaker labels are escaped, and a
  line that would start with Markdown block syntax (`#`, `-`, `1.` …) when it
  has neither label nor timestamp gets a one-character guard.
- Front-matter values are JSON-encoded strings (valid YAML, Hebrew-safe). The
  `app` key appears only when the recording has an app name, and `speakers` only
  when the transcript has speaker labels.

**Settings** (Settings > Storage > "Markdown transcripts"; `UserDefaults` keys
`markdownExport.*`):

| Setting | Key | Default |
| --- | --- | --- |
| Save a Markdown transcript (.md) next to each recording | `markdownExport.sidecarEnabled` | **off** |
| Timestamp each paragraph | `markdownExport.paragraphTimestamps` | on (only matters once the above, a transcript vault mode or Export is used) |
| Notes in your vault contain: Summary (or transcript if no summary) / Full transcript / Summary + full transcript | `markdownExport.noteContent` | Summary (or transcript if no summary), i.e. today's behaviour |

Plus an **Export Transcript (.md)…** command next to "Export Subtitles (.srt)…"
(history context menu and detail toolbar), and a **Write Markdown for existing
recordings** button that backfills completed, non-trashed recordings (file work
runs off the main thread). The Export command includes the summary and action
items unless the vault setting is "Full transcript".

**Where it hooks in**

- `TranscriptExporter.writeSRT(for:in:)` also writes the sidecar. That one call
  covers every place the `.srt` is regenerated (completion, speaker rename,
  edits, re-transcription).
- `RecordingStore` removes the `.md` wherever it removes the `.srt`, and
  rewrites it when a completed recording's title changes in `rename` or
  `update`, since the title is in the front matter and the heading.
- `ObsidianExporter.markdown(for:)` and `hasContent(_:)` gain defaulted
  parameters for the note content mode; `writeNote` reads the mode from the
  exporter's injected `UserDefaults`.
- The grouping and rendering live in MilaKit
  (`ParagraphTranscriptFormatter`, pure and dependency-free, no TranscriptionCore
  import); `MarkdownTranscriptExporter` adapts a `Recording` to it.
- `MarkdownExportSettings` is an app-wide `@StateObject` created in
  `MilaApp.init()`, registered with the churn probe, and injected into both the
  main window and the Settings scene. It publishes nothing at audio cadence.

**What is unchanged**

- The `.srt` is still written, exactly as before (the subtitle-video feature
  reads it).
- The clipboard / LLM transcript (`TranscriptFormatter.plainText`) is untouched.
- With the default note content, vault notes are byte-for-byte what they were:
  that path runs the existing code, and a test compares the default-argument
  output with the upstream output.
- Logging follows the existing privacy rule: the sidecar's file name (derived
  from the title) is `.private`, the recording's UUID is the public key, and
  transcript text is never logged.

**Known limits**

- The sidecar is transcript-only. The summary is generated after the transcript
  sidecars are written, so including it there would leave a file that is missing
  it or stale. The Export command and the vault modes do include the summary.
- Paragraph timestamps come from segment starts: a paragraph's timestamp is its
  first segment's start, never borrowed from a later one, and renders as
  `[time unavailable]` if that segment has no usable start.
- The note content mode applies when a note is next written; this PR adds no
  bulk rewrite of notes already in the vault.

## How it was tested

CI evidence: the "Upstream PR check" workflow in the contributor's fork builds
this exact patch series on top of `island-io/mila` `605babbd5c2639841fc4ea366f9d3cf9f4a21118`
(Release 1.9.6, build 68) on a `macos-26` runner with Xcode. It clones upstream
at that commit, applies the four commits here with `git am --3way`, runs the
`swift test` suites of the local packages that have tests (MilaKit) and then
`make project`, a Debug build of the `Mila` scheme, and the **full** `MilaTests`
suite (not only the one class upstream's CI runs). Run: https://github.com/shircomay/mila-sandbox/actions/runs/38001457732

New tests, all with synthetic content and private `UserDefaults` suites:

- MilaKit `ParagraphTranscriptFormatterTests` (42): adjacency grouping, Hebrew +
  English order, word cap, pause break on/off and with non-finite times,
  timestamp rules ("never borrow a later segment's start"), label escaping,
  verbatim text, the block-syntax guard, and that the fallback text is not
  evaluated when segments exist.
- `MarkdownTranscriptExporterTests`: document shape and front matter,
  summary / action-item inclusion, Hebrew and assigned speaker names,
  `writeSidecar` no-op when disabled and write when enabled, `removeSidecar`,
  the Export write path, and the `writeSRT` hook (reads `.standard` only).
- `MarkdownExportSettingsTests`: code defaults, persistence under the
  namespaced keys, raw values, fallback for an unknown stored value.
- `ObsidianNoteContentModeTests`: the three modes, default argument equals the
  existing output, `hasContent` in the transcript modes, and the mode chosen via
  the exporter's injected defaults.
- `RecordingTitleRefreshTests`: `rename` / `update` rewrite the `.md` for a
  completed recording and do nothing for unchanged titles or other statuses.
  This one enables the sidecar on `UserDefaults.standard` for the duration of
  each test and restores the previous value, because `RecordingStore` reads the
  setting from `.standard`; it is the one deviation from the "custom suite"
  convention.

Not yet done: the Settings section, the Export panel and the context-menu items
were not exercised by hand, and no real recording has been run through the
sidecar or into a real vault. The unit and build checks above are the only
evidence so far.

## Checklist

- [x] Builds locally (`make build`) and tests pass (`make test`) — verified by the CI run above rather than on the author's own Mac
- [x] No secrets, credentials, tokens, or internal infrastructure references added
- [x] Follows the conventions in `CLAUDE.md` (app-wide `@StateObject` injected in both scenes, namespaced keys, private `UserDefaults` suites in tests, `.private` log fields)
- [x] User-facing change is noted in the README changelog (if applicable)

🤖 Generated with [Claude Code](https://claude.com/claude-code)
