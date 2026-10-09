# Spec 04 — Keep my changes, take upstream updates

**Agent:** Claude Sonnet · **effort: medium** · read `00-overview.md` first.

## Goal

The owner runs a personal Mila build with custom features and wants new
upstream (`island-io/mila`) releases merged in, preferring the owner's code
where both sides changed the same lines. An official Mila auto-update must never
silently replace the personal build.

Repository facts: this repo (`shircomay/mila-sandbox`, public) holds the
complete upstream history; the personal line is currently the branch the
orchestrator works on (it will become the default branch). It is NOT a GitHub
"fork" object, so it cannot open PRs into upstream (FORK.md must explain that a
real fork is needed for contributions). Upstream releases are tags `vX.Y.Z`
(betas `vX.Y.Z-beta.N`); upstream's default branch is `main`.

The ChatGPT kit's helper is the starting point:
`/tmp/claude-0/-home-user-mila-sandbox/941088dd-746a-56b6-a96c-fa0440056ae3/scratchpad/kit/mila-customisation-kit-v3/scripts/sync-upstream.sh`
and its fixture tests `.../tests/test_sync.py`. Both were reviewed: the merge
logic (neutral merge to RECORD conflicts → abort → `-X ours` merge with rerere,
refuse structural conflicts, never touch the original branch) is sound; keep it.

## Part A — `scripts/fork/sync-upstream.sh`

Adapt the kit script:
- Usage: `sync-upstream.sh [--target latest|main|vX.Y.Z] [--build] [--ci] [--base <branch>]`.
  `latest` (default) = highest stable `vX.Y.Z` upstream tag (no suffix), by
  `sort -V`.
- `--base` defaults to the current branch; refuse to run on a detached HEAD or a
  dirty tree; refuse if `upstream` remote is missing, and print the exact
  `git remote add upstream https://github.com/island-io/mila.git` command.
- Never push anywhere. If an `upstream` push URL exists that is not already
  disabled, leave it alone but never use it.
- Fetch upstream tags into `refs/tags/upstream/*` (kit behaviour; avoids clobbering
  local tags).
- Already contains the target → print and exit 0 ("up to date").
- Local mode (default): kit behaviour — backup tag, review branch
  `sync/upstream-<target>-<UTC stamp>` in a separate worktree, reports kept.
- `--ci` mode: no worktree; create/checkout branch `sync/upstream-<target>` in the
  current checkout from `--base`, perform the merge there, commit, and write
  `$SYNC_REPORT` (markdown, default `sync-report.md` in `$RUNNER_TEMP` or `/tmp`).
- `--build` runs `make project && make build && make test` (macOS only; refuse
  elsewhere with a clear message). Default: no build — CI builds the PR.
- Report contents (markdown): target + SHA; upstream commits merged
  (`git log --oneline base..target`); files where the neutral merge conflicted
  (= where "mine" won); **files changed by upstream that the fork also changes**
  (intersection of `git diff --name-only merge-base..target` and
  `git diff --name-only merge-base..base`) — these need human review even without
  a conflict; and the `git grep -n "FORK:"` hook list for reference.
- Exit codes: 0 merged or up to date; 2 structural conflict (modify/delete,
  rename, binary) — report written, nothing committed; 1 other errors.
- Bash 3.2 compatible (macOS `/bin/bash`), `set -euo pipefail`.

Tests: port `test_sync.py` to `scripts/fork/tests/test_sync_upstream.py` (fixture
git repos in temp dirs, no network; run with `python3 -I`). Cover: clean merge;
conflicting hunk where mine wins and upstream's independent hunks survive;
`latest` picks the highest stable tag and ignores `-beta`; up-to-date no-op;
structural conflict → exit 2 with report and original branch untouched; dirty tree
refusal; `--ci` mode branch naming and report sections (conflicts + "also changed
by fork"). Run them locally until green.

## Part B — `.github/workflows/fork-upstream-sync.yml`

- Triggers: weekly cron (`17 6 * * 1`) and `workflow_dispatch` with inputs
  `target` (default `latest`) and `base_branch` (default empty → repository
  default branch).
- `runs-on: ubuntu-latest`, `permissions: contents: write, pull-requests: write, issues: write`,
  `concurrency: fork-upstream-sync`.
- Pin actions by full SHA exactly like the existing workflows (copy the
  `actions/checkout` pin from `.github/workflows/fork-ci.yml`). Checkout with
  `fetch-depth: 0` and a token of `secrets.FORK_SYNC_TOKEN || github.token`.
- Configure a bot git identity, add the upstream remote, run the script in `--ci`
  mode.
- Exit 0 with a merge commit → push `sync/upstream-<target>` (force-with-lease is
  fine: this branch is bot-owned) and create or update ONE PR into the base branch
  with `gh pr create` / `gh pr edit` (title `Upstream sync: <target>`, body = the
  report). Exit 0 and up to date → do nothing. Exit 2 → create or update ONE issue
  titled `Upstream sync needs a manual merge: <target>` with the report.
- Document in the workflow header why `FORK_SYNC_TOKEN` exists: (1) `GITHUB_TOKEN`
  cannot push commits that modify `.github/workflows/*` (upstream does this often),
  and (2) PRs opened with `GITHUB_TOKEN` do not trigger other workflows, so Fork CI
  would not build the sync PR. A fine-grained PAT for this repo with Contents,
  Pull requests, Issues and Workflows read/write fixes both. Without it the
  workflow still works for syncs that don't touch workflows; Fork CI can then be
  started manually (`workflow_dispatch`).
- Validate the YAML locally (`python3 -c 'import yaml…'`) and, if available,
  `actionlint` (do not install from untrusted sources; skip if absent).

## Part C — personal-build guard (Swift, small)

New `Mila/App/ForkBuild.swift`:

```swift
enum ForkBuild {
    /// True when Info.plist carries MilaForkPersonalBuild = YES.
    static var isPersonalBuild: Bool
    /// Personal-build defaults (overview table). Only fills keys the user never
    /// set; never touches suites other than the one passed.
    static func registerDefaults(on defaults: UserDefaults = .standard)
}
```

Use string-literal keys from the overview table (other specs own the settings
classes; do not import them).

Hooks (`// FORK:` / `# FORK:`):
- `project.yml`: add `MilaForkPersonalBuild: true` to the Mila target's
  `info.properties` (next to `CFBundleDisplayName`).
- `MilaApp.init()`: first statement `ForkBuild.registerDefaults()` (before any
  settings object reads defaults).
- Sparkle (`Mila/App/MilaApp.swift`, the updater wrapper around
  `SPUStandardUpdaterController`): `startingUpdater: !ForkBuild.isPersonalBuild`.
  In the user-initiated `checkForUpdates()` path, when personal: show an
  `NSAlert` "This is your personal Mila build" / "Official updates are turned off
  so they can't replace your custom features. New Mila releases arrive as an
  'Upstream sync' pull request in your GitHub repository — see FORK.md." and
  return. Read `UpdaterPrereleaseGuardTests` and any updater tests first; they run
  inside the app host (whose Info.plist WILL have the key) — make sure none of
  them depends on the updater having started; if one does, gate on an injected
  flag instead.
- Do not change the bundle identifier or the app name: the personal build
  replaces the official app in place and keeps the owner's recordings, settings
  and permissions location.

Tests: `MilaTests/ForkBuildTests.swift` — registerDefaults on a custom suite sets
the six keys' defaults, does not override a user-set value, and does not leak to
another suite.

## Part D — `.github/workflows/fork-release.yml` (build a DMG the owner can install)

- `workflow_dispatch` (input `version_suffix`, default `fork`) and `push` of tags
  `fork-v*`. `runs-on: macos-26`.
- Mirror the cache + bundle steps from `fork-ci.yml` that `make dmg` needs (read
  the Makefile `dmg`/`release-build` targets and `scripts/make-dmg.sh` to find
  out exactly what it requires: diarization bundle? models? signing identity?).
  Build ad-hoc signed (`CODESIGN_IDENTITY=-`), `VERSION=<MARKETING_VERSION from
  project.yml>-<suffix>`.
- Upload the DMG as an artifact (retention 30 days); on a `fork-v*` tag also attach
  it to a GitHub Release of this repo (`gh release create`, `contents: write`).
- Never publish to upstream; never touch `SUFeedURL`.

## Part E0 — silence upstream's Dependabot in the fork

Upstream's `.github/dependabot.yml` came along with the history and already
opened an action-bump PR in this repo. Those PRs edit upstream-owned files and
create merge noise. Set `open-pull-requests-limit: 0` on BOTH ecosystem entries
(two one-line edits, each with a `# FORK:` comment; do not delete the file —
deleting it would turn every upstream edit into a modify/delete conflict).
Upstream's own bumps arrive through the sync PR anyway.

## Part E — `FORK.md` (repo root) — the owner's guide

Plain language, short sections:
1. What this is (personal Mila + features list, linking `docs/fork/designs/`).
2. Install / update the app: download the DMG from the latest "Fork release" run
   or release; first launch right-click → Open; re-grant Microphone + Screen
   Recording after each install (ad-hoc signature changes). Alternative: build
   locally with Xcode (`make bootstrap project build`, `scripts/install-debug.sh`
   for a stable local signature that keeps permissions).
3. How upstream updates arrive: weekly sync PR → Fork CI builds it → review the
   "also changed by the fork" list → merge → run Fork release. What "mine wins"
   means and its limit (a textual preference, not a semantic guarantee; security
   fixes can hide behind it — read the report). Running the script locally.
4. Repo settings to enable once: Actions → "Allow GitHub Actions to create and
   approve pull requests"; optional `FORK_SYNC_TOKEN` secret (what scopes, why);
   disable upstream workflows that need secrets this repo doesn't have (list them:
   e2e-remote-transcription, e2e-hebrew-remote, llm-live-ai-e2e,
   build-speaches-image) — or leave them; they only run on PRs into `main`.
5. Contributing back to Mila: yes — Apache-2.0, PRs into `island-io/mila:main`
   from a real GitHub fork, linked issue required (CI check), `make build` +
   `make test`, README changelog entry for user-facing changes. Beta/"nightly" are
   update channels for users, not a way to contribute. Steps at a glance; nothing is
   submitted without the owner's explicit OK.
6. "Upstream files touched" ledger table (`| File | Hook | Spec |`), seeded with
   your own rows.

## Acceptance

- `python3 -I scripts/fork/tests/test_sync_upstream.py` passes locally;
  `bash -n` passes on the script; YAML parses.
- Fork CI green (ForkBuildTests + unchanged upstream tests).
- `FORK.md` complete; ledger seeded.
