# Upstream pull-request packages

Each directory here is one feature of this fork, rewritten to upstream quality
and packaged as its own pull request into `island-io/mila:main`:

```
<NN-slug>/
  BASE            the island-io/mila commit the patches apply to (one line)
  BRANCH          proposed head branch name in the contributor's fork (one line)
  000N-*.patch    `git format-patch` series against BASE
  ISSUE.md        first line "# <issue title>", then the issue body
  PR.md           first line "# <PR title>", then the PR body (upstream template)
```

| Package | Feature |
| --- | --- |
| `01-markdown-transcripts` | Speaker-paragraph Markdown transcripts: opt-in `.md` sidecar, vault note content choice, Export Transcript (.md)… |
| `02-echo-cancellation` | Opt-in acoustic echo cancellation for meeting recordings: timestamped capture, `EchoCancellation` package with vendored SpeexDSP, Settings > Audio section. Independent of package 01. |

The patches carry no fork-only code (no `ForkBuild`, no personal defaults, no
`FORK:` markers). They are not applied to this fork's branches; this fork has
its own, richer version of the same code.

## Check a package

The "Upstream PR check" workflow (`.github/workflows/fork-upstream-pr-check.yml`)
runs on pushes to `claude/**` that touch this directory, and by hand
(workflow_dispatch). For every package here it clones `island-io/mila` at
`BASE`, applies the series with `git am --3way`, and runs the package tests, a
Debug build and the full `MilaTests` suite on that tree. A green run is the
evidence quoted in `PR.md`.

## Apply a package by hand

```bash
git clone https://github.com/island-io/mila
cd mila
git checkout -b feature/markdown-paragraph-transcripts "$(cat /path/to/this/repo/docs/fork/upstream-prs/01-markdown-transcripts/BASE)"
git am --3way /path/to/this/repo/docs/fork/upstream-prs/01-markdown-transcripts/*.patch
```

If upstream `main` has moved past `BASE` and `git am` conflicts, resolve with
`git am --continue`, or rebase the resulting branch onto the new `main` and
re-run the build and tests before submitting.

## Submitting

Opening the issue and the pull request happens from a Claude session on the
owner's Mac, using the owner's `gh` login. The prompt for that session lives in
[`SUBMIT.md`](SUBMIT.md).
