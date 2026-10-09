# Fork designs — overview and ground rules

This directory holds the implementation specs for the personal Mila fork
(`shircomay/mila-sandbox`). Each spec is written so that one coding agent
(Claude Sonnet) can implement it end-to-end without further context. The
specs replace the ChatGPT "customisation kit v3"; where they differ from the
kit, the spec wins (see "What changed from the kit" below).

| Spec | Scope | Agent effort | Why that effort |
| --- | --- | --- | --- |
| [01-markdown-transcripts.md](01-markdown-transcripts.md) | Paragraph Markdown transcripts: `.md` sidecar, vault note content modes, Export… command, settings | **high** | ~8 integration points in a large app that we cannot compile locally |
| [02-aec-core.md](02-aec-core.md) | `Packages/EchoCancellation`: vendored SpeexDSP + timestamp-aligned echo-cancellation stage + synthetic-echo tests | **xhigh** | DSP + timeline math; correctness can only be shown by measurement |
| [03-aec-integration.md](03-aec-integration.md) | Wire the stage into `RecordingSession` (timestamps, gain ordering, pause/stop flush, settings, debug audio) | **xhigh** | Touches the live recording path, the app's most regression-sensitive code |
| [04-fork-maintenance.md](04-fork-maintenance.md) | Upstream sync ("prefer mine"), sync workflow, personal-build guard (no official auto-update), DMG workflow, `FORK.md` | **medium** | Scripting/YAML/docs, testable locally with fixture repos |

Specs 01, 02 and 04 are independent. Spec 03 depends only on the **public API
contract written in spec 02** (§ "Public API"), so 02 and 03 can run in
parallel; do not rely on anything in the package beyond that contract.

## Ground rules for every agent

1. **Additive first.** Put new behaviour in NEW files (new Swift files, a new
   package, new tests, new workflows). Edit upstream files only to add small
   hooks — a few lines each. Every hook line or block in an upstream file gets
   a `// FORK:` comment (YAML/shell: `# FORK:`) so `git grep -n "FORK:"` lists
   every touchpoint. Small hooks keep future upstream merges conflict-free.
2. **Never reformat, reorder, rename or "clean up" upstream code.** No drive-by
   fixes. Do not edit existing upstream tests; add new test files instead. All
   existing upstream tests must keep passing unchanged.
3. **Follow `CLAUDE.md`.** In particular: app-wide settings objects are
   `@StateObject`s created in `MilaApp.init()` and injected with
   `.environmentObject()` on BOTH the main window and the Settings scene;
   UserDefaults keys are namespaced (`feature.key`); tests use a custom
   `UserDefaults(suiteName:)`, never `.standard`; logs never print user content
   (paths, titles, transcript text) except with `privacy: .private`; nothing that
   changes at audio cadence may be `@Published` on an App-level `@StateObject`.
4. **`project.yml` is the source of truth.** Files under `Mila/` and
   `MilaTests/` are picked up automatically (`sources: - path: Mila`); only a new
   local package needs `project.yml` edits.
5. **There is no Swift toolchain in the agent container** (`download.swift.org`
   is blocked). Swift code is compiled only by the `Fork CI` GitHub workflow on
   macOS after the orchestrator pushes. So: open and read every type and function
   you call — never guess a signature, initializer label, access level or
   actor isolation. Target Swift 5.10 / macOS 14 (check `project.yml` for
   `SWIFT_VERSION` and strict-concurrency settings before writing concurrency
   code). Prefer plain, boring Swift. C code CAN be compiled locally with
   `gcc`/`cc`; Python 3 is available.
6. **Fork defaults vs upstream defaults.** New settings default to upstream
   behaviour (feature OFF) in code. The personal build switches them on through a
   single registration point, `ForkBuild.registerDefaults()` (spec 04), using
   `UserDefaults.register(defaults:)`. Registered defaults never override a value
   the user set, and test suites with their own `suiteName` never see them. The
   shared keys are fixed here so the specs stay in sync:

   | Key | Type | Code default | Personal-build default |
   | --- | --- | --- | --- |
   | `markdownExport.sidecarEnabled` | Bool | `false` | `true` |
   | `markdownExport.paragraphTimestamps` | Bool | `true` | `true` |
   | `markdownExport.noteContent` | String | `"summaryElseTranscript"` | `"summaryAndTranscript"` |
   | `echoCancellation.enabled` | Bool | `false` | `true` |
   | `echoCancellation.saveDebugAudio` | Bool | `false` | `false` |
   | `echoCancellation.lastSessionSummary` | String | absent | absent |

7. **Ledger.** For every upstream file you touch, add one row to the "Upstream
   files touched" table in `FORK.md` (create the section if it does not exist yet:
   `| File | Hook | Spec |`). The orchestrator merges these rows.
8. **Git.** Work only inside your assigned worktree. Commit your work there in
   focused commits (no pushing, no branch switching, no history rewriting). End
   commit messages with the attribution lines the orchestrator gives you.
9. **Public repo.** `shircomay/mila-sandbox` is public. Never add real
   recordings, real transcripts, personal names (other than synthetic examples),
   credentials or machine-specific paths.

## Final report every agent must return

- Files created / modified (upstream files listed separately, with the hook).
- Tests added and what each one proves.
- Anything you could not verify (e.g. "compiles?" — you cannot know; list the
  APIs you were least sure about so the orchestrator can check CI errors fast).
- Open risks and any deviation from the spec, with the reason.

## What changed from the ChatGPT kit (vetting summary)

Kept: the Markdown output shape (`**[MM:SS] Speaker:** paragraph`), one
timestamp per paragraph from the first segment's real start, `[H]H:MM:SS` past
one hour, adjacency-only grouping, the soft 180-word cap, the reference-based
echo-cancellation architecture (cancel the mic BEFORE mixing, keep the app
audio once), and the fork + `-X ours` merge policy with a neutral-merge
conflict report first.

Changed:
- **Markdown escaping.** The kit backslash-escaped `- + ! # | _ * [ ] \`` and
  HTML-encoded `& < >` everywhere in spoken text. For a knowledge base that is
  read raw (RAG ingestion, search), `e\-mail` and `Q&amp;A` are corruption.
  Spoken text is now verbatim; only labels and line-start block syntax are guarded.
- **Pause breaks.** Paragraphs also break on a long pause (default 4 s), so
  undiarized recordings are not one 180-word wall after another.
- **`.srt` stays.** Mila's "subtitle video" feature reads the `.srt` sidecar
  (`PostRecordingCoordinator`), so the `.md` sidecar is written alongside it,
  not instead of it.
- **Speaker labels** use Mila's own `displaySpeakerName(names:language:)`
  ("Speaker A" / "דובר א׳" or the assigned name), matching the UI and `.srt`.
- **Echo cancellation library.** SpeexDSP (BSD, small, pure C, builds as a
  SwiftPM target on macOS and Linux) instead of WebRTC AEC3 for v1, behind a
  backend protocol so AEC3 can be swapped in if listening tests demand it.
  Apple's voice-processing I/O is not used: it only cancels audio played
  through the app's own engine, not the meeting app's audio.
- **Timestamp alignment is mandatory.** Mila's meeting mix pairs mic and app
  audio by arrival order, and ScreenCaptureKit stops delivering during silence,
  so the mic/app offset jumps every time the far end goes quiet. An adaptive
  echo filter cannot track that; spec 02 aligns both streams by host time.
- **Gain ordering.** Mila's adaptive gain (200 ms attack) currently runs inside
  the mic tap. With echo cancellation on, it is moved after the canceller.
- **Updates.** The kit's local sync script is kept (adapted) and a weekly
  GitHub workflow opens a PR for each new upstream release. The personal build
  disables Sparkle so an official update can never silently replace it.
- **Dropped:** the Python AEC preview script (superseded by the native stage and
  its debug-audio dump) and the PR-body drafts (premature; upstream PRs come after
  the features are proven on a real Mac).
