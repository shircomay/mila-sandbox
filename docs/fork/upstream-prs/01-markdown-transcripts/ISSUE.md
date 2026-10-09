# feat: speaker-paragraph Markdown transcripts (opt-in .md sidecar, vault note content choice, Export command)

**Problem / use case**

I use Mila's transcripts as input to a personal knowledge base and to search
and retrieval tools, which ingest plain Markdown files. Today Mila gives me two
ways to get a transcript onto disk, and neither fits:

- **The `.srt` sidecar** is subtitle cues, one per sentence, with start and end
  times. It is the right shape for subtitling a video (Mila's own
  subtitle-video feature reads it), but as text it is a wall of numbered
  one-line cues. Speaker turns are not grouped, and a reader has to skip the
  cue numbers and time ranges to follow a conversation.
- **The Obsidian-vault exporter** writes the AI summary *instead of* the
  transcript whenever a summary exists. The transcript only lands in the vault
  for recordings that have no summary. For a knowledge base the full transcript
  is the thing I want, and the summary is a nice extra.

What I want is the transcript as readable speaker paragraphs, in a plain
Markdown file that sits next to the recording, and a say in what the vault
notes contain.

**Proposed solution**

Add paragraph-style Markdown transcripts, all opt-in so nothing changes for
anyone who does not turn them on:

1. **A `.md` sidecar** written next to each recording's `.srt` (the `.srt` is
   still written), off by default. Consecutive segments from the same speaker
   become one paragraph with a single timestamp, for example
   `**[00:12] Speaker B:** ...`. A paragraph also breaks on a long pause or
   after a soft word cap, so a recording without speaker labels does not turn
   into one giant paragraph. Spoken text is emitted verbatim (no backslash or
   HTML escaping), because the file is meant to be read raw by tools. The file
   starts with YAML front matter (title, date, duration, language, source,
   speakers, recording id).
2. **A choice of what Obsidian vault notes contain**: the current behaviour
   (summary, or the transcript if there is no summary) stays the default, plus
   "full transcript" and "summary + full transcript".
3. **An "Export Transcript (.md)…" command** next to "Export Subtitles (.srt)…"
   in the recording's context menu and detail toolbar.
4. **A settings section** under Settings > Storage with the toggles above and a
   one-shot "Write Markdown for existing recordings" button to backfill
   recordings that were transcribed before the sidecar was turned on.

The grouping and rendering would be a small pure type in MilaKit
(dependency-free, unit-tested), with the app-side exporter adapting a
`Recording` to it.

**Alternatives considered**

- *Post-processing the `.srt` or `.txt` outside Mila.* Possible, but every user
  who wants this would write their own converter, and the `.txt` has no
  timestamps. Doing it inside Mila reuses the same speaker display names the
  UI and the `.srt` show (including names the user assigned).
- *Changing the vault exporter's default to the transcript.* That would change
  existing users' notes, so it is a setting instead, defaulting to today's
  behaviour.
- *Including the summary in the sidecar.* The summary is generated after the
  transcript sidecars are written, so a sidecar containing it would be missing
  or stale until some later rewrite. The sidecar is therefore transcript-only;
  the Export command and the vault note modes can include the summary.

**Additional context**

I have this implemented, with unit tests plus a full build and test run passing
in CI (not yet tried by hand on a real recording), and will open a pull request
linked to this issue right away. It touches the transcript exporter, `RecordingStore` (remove
the `.md` along with the `.srt`, and refresh it when a completed recording's
title changes), `ObsidianExporter`, and adds one settings object. Happy to
adjust the shape, the defaults or the file format based on your feedback.
