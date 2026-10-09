# FORK.md — the owner's guide to this personal Mila

This repository (`shircomay/mila-sandbox`) is a personal copy of
[Mila](https://github.com/island-io/mila) (Apache-2.0) with extra features. It
holds the complete upstream history, but it is **not** a GitHub "fork" object, so
GitHub cannot open pull requests from it into upstream (see section 5).

## 1. What this is

Personal Mila = upstream Mila plus these features (specs in
[`docs/fork/designs/`](docs/fork/designs/00-overview.md)):

| Feature | Spec |
| --- | --- |
| Paragraph Markdown transcripts (`.md` sidecar, vault note content, Export…) | [01](docs/fork/designs/01-markdown-transcripts.md) |
| Echo-cancellation core (`Packages/EchoCancellation`) | [02](docs/fork/designs/02-aec-core.md) |
| Echo cancellation wired into recording | [03](docs/fork/designs/03-aec-integration.md) |
| Upstream sync, personal-build guard, DMG workflow (this file) | [04](docs/fork/designs/04-fork-maintenance.md) |
| Knowledge-base folder via `.milaconfig`, title refresh | [05](docs/fork/designs/05-kb-folder-and-title-refresh.md) |

Fork code is additive (new files) with small upstream-file hooks marked
`FORK:`; `git grep -n "FORK:"` lists every one. The personal build:

- switches the fork features on by default (`ForkBuild.applyPersonalDefaults()`),
- turns **Sparkle off**, so an official Mila update can never replace it; "Check
  for Updates…" explains that instead,
- keeps the official bundle identifier and name, so it replaces the official app
  in place and keeps your recordings and settings.

## 2. Install and update the app

**From GitHub (easiest).** Run the **Fork release** workflow (Actions tab → Fork
release → Run workflow), or push a tag such as `fork-v1`. Download the
`Mila-<version>-fork.dmg` artifact from the run (kept 30 days), or from the
Release a `fork-v*` tag creates. Open the DMG and drag Mila to Applications.

- The build is ad-hoc signed, not notarized. First launch: **right-click → Open**.
- The signature changes with every build, so macOS forgets permissions: re-grant
  **Microphone** and **Screen Recording** after each install.

**Locally with Xcode.** `make bootstrap project build`; then
`scripts/install-debug.sh` installs a build signed with a stable local
certificate, which keeps the permissions across installs.

## 3. How upstream updates arrive

1. Every Monday (or on demand: Actions → Fork upstream sync) the workflow merges
   the newest stable upstream release (`vX.Y.Z`, never a beta) and opens one pull
   request, **Upstream sync: vX.Y.Z**, from branch `sync/upstream-vX.Y.Z`.
2. Fork CI builds the PR and runs the full test suite.
3. Read the PR body (the report). Pay most attention to **Files changed by
   upstream that the fork also changes**, then to the list where the fork won.
4. Merge the PR, then run **Fork release** and install the new DMG.

If upstream and the fork changed a file structurally (deleted vs modified,
renamed, binary) nothing is committed. The workflow opens one issue, **Upstream
sync needs a manual merge**, with the report; merge by hand.

**What "mine wins" means.** Git first merges neutrally just to record which files
conflict, then merges again with `-X ours`: where both sides edited the same
lines the fork's text is kept; every other upstream change is taken. It is a
textual preference, not a semantic guarantee. A security fix or a changed API can
sit behind a hunk the fork won, and a merge can compile yet misbehave. The report
exists so you can check; build and tests passing do not prove recording or audio
correctness, so smoke-test on the Mac.

**Run it locally** (never pushes anything):

```
git remote add upstream https://github.com/island-io/mila.git   # once
scripts/fork/sync-upstream.sh                 # --target latest|main|vX.Y.Z, --build
git switch <your-branch> && git merge --ff-only sync/upstream-<target>-<stamp>
```

The script makes a backup tag and a review branch in a separate worktree and
prints the report path; `--build` also runs `make project build test` (macOS).
Tests: `python3 -I scripts/fork/tests/test_sync_upstream.py`.

## 4. Repo settings to enable once

- Settings → Actions → General → **Allow GitHub Actions to create and approve
  pull requests** (the sync workflow needs it).
- Optional secret **`FORK_SYNC_TOKEN`**: a fine-grained personal access token for
  this repository only, with Contents, Pull requests, Issues and Workflows
  read/write. Without it, `GITHUB_TOKEN` cannot push upstream changes to
  `.github/workflows/*` (the sync fails for those releases), and pull requests it
  opens do not trigger Fork CI (start Fork CI by hand on the sync branch).
- Upstream's workflows came along with the history. Those needing secrets this
  repo does not have (`e2e-remote-transcription`, `e2e-hebrew-remote`,
  `llm-live-ai-e2e`, `build-speaches-image`) can be disabled in the Actions tab,
  or left alone: they only run on pull requests into `main`.
- Upstream's Dependabot is silenced (`open-pull-requests-limit: 0`); its bumps
  arrive through the sync PR.

## 5. Contributing back to Mila

Yes, upstream accepts contributions (Apache-2.0). Nothing is ever submitted
without the owner's explicit OK. In outline:

1. Create a **real GitHub fork** of `island-io/mila` (this repository cannot open
   PRs into it) and branch from upstream `main`, containing only the one feature.
2. Open or find an issue first: a linked issue is required (CI checks it).
3. `make build` and `make test` pass; add a README changelog entry for
   user-facing changes.
4. Open the PR into `island-io/mila:main`.

Beta and "nightly" are update channels for users, not a way to contribute.

## 6. Knowledge-base folder

Goal: every finished transcript lands, as Markdown, in your knowledge-base (KB)
folder, without that path ever appearing in this public repository.

**How it works.** It reuses Mila's Obsidian-vault exporter (one
`<date> <title>.md` per recording, idempotent) and the note-content choice from
the Markdown feature. A private helper on your Mac writes a `.milaconfig` file
with a `knowledgeBase` section; you double-click it, Mila shows its usual
confirmation sheet listing only what would change, and applying it sets the
folder, subfolder, note content, git sync and the on/off switch (in that order,
"on" last). The format is in
[`docs/fork/knowledge-base.milaconfig.example`](docs/fork/knowledge-base.milaconfig.example):

```json
{
  "version": 1,
  "knowledgeBase": {
    "enabled": true,
    "folder": "~/path/to/knowledge-base",
    "subfolder": "Mila transcripts",
    "noteContent": "transcript",
    "gitSync": false
  }
}
```

- Every field is optional; absent leaves the current setting alone.
- `noteContent` is `summaryElseTranscript`, `transcript` or
  `summaryAndTranscript`; an unknown value is ignored.
- `folder` must be absolute after `~` expansion; a relative path is refused with a
  message. A missing folder is created (its parent must exist).
- Official Mila builds ignore the extra key, so `version` stays 1.

**The real file lives only on your Mac.** Keep the actual `.milaconfig` (with your
real path) out of the repository and out of any shared drive; only the placeholder
example above is committed. Settings → Storage shows the result like any other
Obsidian-vault setup, so you can also set it by hand.

**Commit & push.** Leave `gitSync` off (the default) unless the KB folder is a
private repository. With it on, Mila commits and pushes that folder after every
note.

**Title refresh.** When a completed recording's title changes (the post-recording
naming sheet, an automatic LLM title, or a rename), the `.md` sidecar is rewritten
and the KB note is renamed in place (the exporter's index keeps one note per
recording, so no duplicate appears). A note still waiting for its summary is left
to the summary step, which writes it with the newest title.

## Upstream files touched

One row per upstream file with fork hooks (other specs append rows).

| File | Hook | Spec |
| --- | --- | --- |
| `Mila/App/MilaApp.swift` | `ForkBuild.applyPersonalDefaults()` (writes unset keys) as first statement of `MilaApp.init()` | 04 |
| `Mila/App/MilaApp.swift` | `startingUpdater: !ForkBuild.isPersonalBuild` (Sparkle off in the personal build) | 04 |
| `Mila/App/MilaApp.swift` | `UpdaterViewModel.checkForUpdates()` shows an alert and returns when personal | 04 |
| `Mila/App/MilaApp.swift` | "Check for Updates…" stays enabled in the personal build (updater not started) | 04 |
| `project.yml` | `MilaForkPersonalBuild: true` Info.plist key | 04 |
| `.github/dependabot.yml` | `open-pull-requests-limit: 0` on both ecosystems | 04 |
| `Mila/Transcription/TranscriptExporter.swift` | `writeSRT(for:in:)`: one `defer { MarkdownTranscriptExporter.writeSidecar(...) }` line writes the `.md` sidecar after the `.srt` (no-op unless enabled; `defer` covers the early return) | 01 |
| `Mila/Models/RecordingStore.swift` | `permanentlyDelete` and `emptyTrash`: also `removeSidecar` next to the `.srt` removal; `rename`: rewrite the `.md` sidecar (title/heading) for completed recordings | 01 |
| `Mila/Actions/ObsidianExporter.swift` | `markdown(for:)` gains defaulted `content:`/`timestamps:` (non-default modes build the note via `MarkdownTranscriptExporter.vaultNote`); `hasContent` gains defaulted `content:` (segments count in transcript modes); `writeNote` reads `MarkdownExportSettings.current(defaults)` and passes both | 01 |
| `Mila/App/MilaApp.swift` | `@StateObject markdownExportSettings`, created in `init`, registered with the churn probe, `.environmentObject` on the main window and the Settings scene | 01 |
| `Mila/Views/RecordingContextMenu.swift` | "Export Transcript (.md)…" button after "Export Subtitles (.srt)…" | 01 |
| `Mila/Views/RecordingDetailView.swift` | Export-transcript toolbar button after the `.srt` button | 01 |
| `Mila/Views/StorageSettingsTab.swift` | `MarkdownExportSettingsSection()` one line after `ObsidianSettingsSection()` | 01 |
| `Mila/Models/MilaConfig.swift` | `var knowledgeBase: KnowledgeBase?` (default nil keeps existing memberwise calls compiling); the type is in `MilaConfig+KnowledgeBase.swift` | 05 |
| `Mila/Models/MilaConfigImporter.swift` | internal `obsidian`/`markdownExport` properties; `init` gains two defaulted trailing parameters; `plannedChanges` calls `knowledgeBaseChanges(for:)`; `apply` calls `applyKnowledgeBase(_:)` | 05 |
| `Mila/Models/RecordingStore.swift` | `onCompletedRecordingRetitled` callback; `update(_:)` rewrites the `.md` sidecar and fires it when a completed recording's title changed; `rename(_:to:)` fires it after the sidecar rewrite | 05 |
| `Mila/App/MilaApp.swift` | `MarkdownExportSettings` created before the importer (moved up from its later line); importer receives `obsidian:`/`markdownExport:`; `store.onCompletedRecordingRetitled` re-exports the KB note unless it is still pending | 05 |
| `THIRD_PARTY_NOTICES.md` | New section "D. Fork additions" appended at the end, marked `<!-- FORK -->`: SpeexDSP (BSD-3-Clause) notice for the vendored echo canceller | 02 |
| `Mila/Audio/MicrophoneRecorder.swift` | `let timestamps = CaptureTimestampQueue()` and `var deferGainToConsumer = false`; `bringUpRealEngine` reads both at every bring-up/rebuild and passes them to `realBringUp`; tap closure takes `when`, skips `gain.process` when `deferGain`, and pushes the buffer's host time right before `continuation.yield` | 03 |
| `Mila/Audio/SystemAudioRecorder.swift` | `timestamps` accessor (queue lives on `AudioStreamOutput`); `deliver(_:hostTimeSeconds:)` / `deliverForTesting(_:hostTimeSeconds:)` gain a defaulted parameter; SCK callback passes the sample buffer's PTS; pushes right before `continuation?.yield` | 03 |
| `Mila/Views/SettingsView.swift` | `EchoCancellationSettingsSection()` inserted in `AudioSettingsTab` between the automatic-gain toggle and the trailing `Spacer()` | 03 |
| `Mila/App/MilaApp.swift` | `@StateObject echoCancellationSettings` created in `init()` (+ churn-probe registration) and injected with `.environmentObject` into BOTH the main window and the Settings scene | 03 |
