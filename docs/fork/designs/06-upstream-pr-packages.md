# Spec 06 — Upstream PR packages for island-io/mila

**Agent:** Claude Sonnet · **effort: high** · read `00-overview.md` first.

## Goal

The owner wants each fork feature offered back to the original project as its
OWN pull request into `island-io/mila:main`. This cloud session cannot open
issues or PRs there (no GitHub App installation on that org), so the
submission happens from a Claude session on the owner's Mac using the owner's
`gh` login. This spec produces, inside this repository, everything that session
needs — and a CI check that builds and tests EXACTLY what will be submitted.

One package per PR, under `docs/fork/upstream-prs/<NN-slug>/`:

```
BASE            # the upstream commit SHA the patches apply to (one line)
BRANCH          # proposed head branch name in the owner's fork (one line)
000N-*.patch    # `git format-patch` series against BASE
ISSUE.md        # first line "# <issue title>", then the issue body
PR.md           # first line "# <PR title>", then the PR body (upstream template)
```

This spec covers package `01-markdown-transcripts`. A later run of the same
spec covers `02-echo-cancellation` (only after its Fork CI is green; the
orchestrator will say when).

## Part A — the clean port (package 01)

Work in a scratch worktree created from upstream: `git worktree add
<scratch-dir>/port-01 upstream/main` (the `upstream` remote exists in this repo;
`git fetch upstream main` first). Do not use the fork branch as the base.

Bring over ONLY the paragraph-Markdown feature, rewritten to upstream quality:

Include
- `Packages/MilaKit/Sources/MilaKit/ParagraphTranscriptFormatter.swift` and its MilaKit tests.
- `Mila/Transcription/MarkdownTranscriptExporter.swift`,
  `Mila/Models/MarkdownExportSettings.swift`,
  `Mila/Views/MarkdownExportSettingsSection.swift`,
  `Mila/Views/MarkdownTranscriptExportPanel.swift`.
- Hooks in `TranscriptExporter.swift` (sidecar after `.srt`),
  `RecordingStore.swift` (remove the `.md` with the `.srt`; refresh the `.md`
  when a completed recording's title changes in `rename` and `update` — the
  sidecar write only, NOT the `onCompletedRecordingRetitled` callback),
  `ObsidianExporter.swift` (note-content modes), `MilaApp.swift` (settings
  `@StateObject`, churn-probe registration, `.environmentObject` on both
  scenes — no ForkBuild, no personal defaults, no `.milaconfig` changes),
  `RecordingContextMenu.swift` + `RecordingDetailView.swift` (Export Transcript
  button), `StorageSettingsTab.swift` (section line).
- Tests: `MarkdownTranscriptExporterTests`, `MarkdownExportSettingsTests`,
  `ObsidianNoteContentModeTests`, and the sidecar-only part of
  `RecordingTitleRefreshTests` (rename/update rewrite the `.md`; drop every
  callback assertion). Tests must not depend on any personal-build default:
  upstream code defaults are sidecar OFF and `summaryElseTranscript`.
- `README.md`: the `## Changelog` lists dated releases, newest first. Add ONE
  bullet at the top in the same style, labelled `**Unreleased**` instead of a
  version/date (maintainers fold it into the next release), describing only
  what the PR does.

Exclude: everything `ForkBuild`, `FORK.md`, `docs/fork/**`, `scripts/fork/**`,
fork workflows, Dependabot edits, `project.yml` personal key, echo
cancellation, the `.milaconfig` `knowledgeBase` section, the vault re-export
callback, `docs/fork/examples`.

Rewrite rules
- Remove every `// FORK:` marker. Where the marker carried a useful
  explanation, keep it as a normal comment in upstream's style (read nearby
  comments; this codebase explains *why* at length). No mention of "fork",
  "personal build", "spec 0N" or this repository anywhere.
- Copy code from the fork branch (`claude/compassionate-newton-7eszag`) — it
  passed Fork CI — and change only what the rules above require. Any non-comment
  change must be listed in your report.
- Commits (2–4, focused, upstream conventional style like
  `feat(export): …`), authored as
  `shircomay <112399495+shircomay@users.noreply.github.com>` (use
  `git -c user.name=… -c user.email=… commit`), each message ending with:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01D6Ni8F4iG4iXK8xfgdhSqe
  ```
- Then `git format-patch <BASE>..HEAD -o docs/fork/upstream-prs/01-markdown-transcripts/`
  (in the fork worktree), write `BASE` and `BRANCH`
  (`feature/markdown-paragraph-transcripts`).

## Part B — ISSUE.md and PR.md

Read upstream `.github/pull_request_template.md`, `CONTRIBUTING.md` and
`.github/ISSUE_TEMPLATE/*` first and mirror their structure.

ISSUE.md: a feature request — problem (`.srt` is sentence cues for subtitles;
the vault exporter writes the AI summary instead of the transcript whenever one
exists; knowledge-base users need the full transcript as readable speaker
paragraphs), proposal (paragraph Markdown, opt-in sidecar, vault note content
choice, Export command), and a note that a PR follows. No personal details.

PR.md, following the template headings:
- First body line `Closes #ISSUE_NUMBER` (literal placeholder — the Mac session
  replaces it after creating the issue).
- **What & why**: the problem, the output format with a short synthetic example
  (English + Hebrew), every setting and its default (all OFF / upstream behaviour
  by default), what is unchanged (`.srt`, clipboard/LLM `plainText`, default vault
  notes byte-for-byte), and known limits (sidecar is transcript-only because the
  summary arrives later; paragraph timestamps come from segment starts).
- **How it was tested**: the exact CI evidence — the "Upstream PR check" workflow
  (Part C) builds this exact patch series on upstream `BASE` with Xcode on
  `macos-26` and runs MilaKit tests and the FULL `MilaTests` suite; leave
  `RUN_URL` as a literal placeholder for the orchestrator. State plainly that the
  UI and real recordings were not yet exercised by hand.
- **Checklist**: tick only what is true (build/tests via the CI evidence; no
  secrets; CLAUDE.md conventions; README changelog).
- End with the line `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.

## Part C — `.github/workflows/fork-upstream-pr-check.yml`

Builds each package exactly as it will be submitted:
- Triggers: `push` to `claude/**` with `paths: ['docs/fork/upstream-prs/**']`,
  and `workflow_dispatch`.
- A small first job lists `docs/fork/upstream-prs/*/` dirs that contain
  `*.patch` and emits a JSON matrix; the second job (`runs-on: macos-26`,
  `timeout-minutes: 90`, `fail-fast: false`) per package:
  checkout this repo (for the patches), `git clone` `https://github.com/island-io/mila`
  into `upstream-src`, `git -C upstream-src checkout $(cat BASE)`, apply with
  `git -C upstream-src am --3way <package>/*.patch` (configure a throwaway
  committer identity), then run inside `upstream-src` the same steps as
  `fork-ci.yml` (package tests for packages with `Tests/` except
  TranscriptionCore, xcodegen, diarization bundle cache keyed on that checkout's
  script hash, `make project`, resolve, Debug build, full `-only-testing:MilaTests`
  with the same summary greps).
- Pin actions by SHA, reusing pins from `fork-ci.yml`. `permissions: contents: read`.
  Validate YAML locally.

## Part D — `docs/fork/upstream-prs/README.md`

Short: what the packages are, how to apply one by hand
(`git am`), and that the Mac-session submission prompt lives in
`docs/fork/upstream-prs/SUBMIT.md` (the orchestrator writes that file — do not).

## Local verification (required before you finish)

- In a fresh scratch worktree at `BASE`, `git am --3way docs/fork/upstream-prs/01-markdown-transcripts/*.patch`
  applies cleanly.
- `git grep -n -i "FORK\|personal build\|spec 0" ` on the resulting tree finds
  nothing from your patches.
- `git diff --stat BASE` of the result lists only the intended files.
- Compare each ported Swift file against the fork branch version
  (`diff -u`): only marker/comment lines and the documented exclusions differ.

## Deliverables

Committed in this worktree: the package directory, the workflow, the README.
Do not push. Report: file list, the non-comment differences from the fork code,
the patch list, and anything in the PR text you were unsure about.
