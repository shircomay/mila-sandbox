# Submitting the upstream PRs (run on the owner's Mac)

The cloud session that prepared these packages cannot open issues or pull
requests on `island-io/mila`. A Claude Code session on the owner's Mac can,
with the owner's own `gh` login. Paste the prompt below into that session.

Each package in this folder is one PR: `BASE` (upstream commit), `BRANCH`
(head branch name), `*.patch` (the exact commits, built and tested by the
"Fork upstream PR check" workflow), `ISSUE.md` and `PR.md` (first line = title).

---

```
Submit my prepared contributions to the Mila project (github.com/island-io/mila) as SEPARATE pull requests, one per package. Use my own GitHub login via the gh CLI. Everything here is public, so show me exactly what will be published and wait for my explicit OK before creating any issue or PR.

Setup
1. Check `gh auth status` shows me logged in (account shircomay). If gh is missing or logged out, stop and tell me how to fix it.
2. Work in ~/mila-upstream-prs (create it). Get the packages:
   git clone --depth 1 --branch claude/compassionate-newton-7eszag https://github.com/shircomay/mila-sandbox ~/mila-upstream-prs/sandbox
   The packages are the folders under ~/mila-upstream-prs/sandbox/docs/fork/upstream-prs/ that contain *.patch files (e.g. 01-markdown-transcripts, 02-echo-cancellation).
3. Make sure my fork exists: `gh repo fork island-io/mila --clone=false` (fine if it already exists; it is shircomay/mila).
4. git clone https://github.com/island-io/mila ~/mila-upstream-prs/mila
   cd ~/mila-upstream-prs/mila && git remote add fork https://github.com/shircomay/mila.git

For EACH package, in number order:
5. BASE=$(cat <pkg>/BASE); BRANCH=$(cat <pkg>/BRANCH)
   git checkout -b "$BRANCH" "$BASE" && git am --3way <pkg>/*.patch
   If `git am` fails, run `git am --abort` and stop for that package; tell me.
6. If origin/main has moved past BASE, try `git rebase origin/main`. If it is not completely clean, `git rebase --abort` and keep BASE (the PR will still show its base; say so in the summary).
7. Show me: `git log --oneline origin/main..HEAD`, `git diff --stat origin/main...HEAD`, the issue title + body (ISSUE.md) and the PR title + body (PR.md). Also check for duplicates: `gh issue list --repo island-io/mila --state all --search "<3-4 keywords from the title>"` and `gh pr list --repo island-io/mila --state all --search "<same>"`. Then WAIT for my OK.
8. After my OK:
   - Issue: title = first line of ISSUE.md without "# "; body = the rest.
     gh issue create --repo island-io/mila --title "<title>" --body-file <body file>
     Note the issue number N.
   - PR body: the rest of PR.md after the first line, with "#ISSUE_NUMBER" replaced by "#N".
   - git push -u fork "$BRANCH"
   - gh pr create --repo island-io/mila --base main --head "shircomay:$BRANCH" --title "<first line of PR.md without '# '>" --body-file <body file>
     Add --draft for the echo-cancellation package (02-echo-cancellation): it needs real-audio testing before review.
9. Never push to island-io/mila directly, never force-push, never enable auto-merge, never close or edit anyone else's issues/PRs.

Finish with a short list: each package → issue URL, PR URL, draft or ready, and anything that needs my attention (e.g. Mila's "Linked issue" check, or CI waiting for maintainer approval because I'm a first-time contributor).
```

---

After submission, Mila's maintainers decide. Reviews may ask for changes; the
cloud session can update the packages and the Mac session can push the new
commits to the same branch (`git push fork "$BRANCH"`, no force).
