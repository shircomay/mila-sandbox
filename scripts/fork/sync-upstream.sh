#!/usr/bin/env bash
# Fork-only helper: merge an upstream (island-io/mila) release into the personal
# line, preferring the fork's code where both sides changed the same lines.
#
#   sync-upstream.sh [--target latest|main|vX.Y.Z] [--build] [--ci] [--base <branch>]
#
# How "prefer mine" works (see FORK.md):
#   1. A NEUTRAL merge is tried first, only to RECORD which files conflict.
#   2. It is aborted, then the real merge runs with `-X ours`: conflicting text
#      hunks keep the fork's side, independent upstream hunks are still taken.
#      (This is NOT `-s ours`, which would throw the whole upstream tree away.)
#   3. Structural conflicts (modify/delete, rename, binary) cannot be resolved by
#      a preference: exit 2, report written, nothing committed.
#
# The script never pushes and never uses an `upstream` push URL. The branch it
# starts from is never modified.
#
# Modes:
#   local (default)  backup tag + review branch sync/upstream-<target>-<UTC stamp>
#                    in a separate worktree; reports are kept in a temp dir.
#   --ci             no worktree; branch sync/upstream-<target> is created in the
#                    current checkout from --base; report goes to $SYNC_REPORT
#                    (default: ${RUNNER_TEMP:-/tmp}/sync-report.md).
#
# Exit codes: 0 merged or up to date; 2 structural conflict; 1 other errors.
# Machine-readable results (SYNC_RESULT, SYNC_TARGET, SYNC_BRANCH, SYNC_REPORT)
# are printed to stdout and, when set, appended to $GITHUB_OUTPUT.
#
# Bash 3.2 compatible (macOS /bin/bash).
set -euo pipefail

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: sync-upstream.sh [--target latest|main|vX.Y.Z] [--build] [--ci] [--base <branch>]
  --target  latest (default) = highest stable upstream vX.Y.Z tag; main; or a tag
  --build   run `make project && make build && make test` (macOS only)
  --ci      CI mode: branch sync/upstream-<target> in the current checkout
  --base    branch to merge into (default: the current branch)
EOF
}

target=latest
build=0
ci=0
base_branch=
while [ $# -gt 0 ]; do
    case "$1" in
        --target) [ $# -ge 2 ] || fail '--target needs a value'; target=$2; shift 2 ;;
        --base)   [ $# -ge 2 ] || fail '--base needs a value'; base_branch=$2; shift 2 ;;
        --build)  build=1; shift ;;
        --ci)     ci=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; fail "Unknown argument: $1" ;;
    esac
done

if [ "$target" != latest ] && [ "$target" != main ] \
    && ! [[ "$target" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
    fail "Bad --target '$target': use latest, main or a tag like v1.9.7."
fi
if [ "$build" = 1 ] && [ "$(uname -s)" != Darwin ]; then
    fail '--build needs macOS (xcodebuild). Run without --build; CI builds the PR.'
fi

root=$(git rev-parse --show-toplevel 2>/dev/null) || fail 'Run inside your Mila fork checkout.'
cd "$root"

# ---- preflight --------------------------------------------------------------
if [ -z "$base_branch" ]; then
    base_branch=$(git symbolic-ref --quiet --short HEAD) \
        || fail 'Detached HEAD: switch to your personal branch (or pass --base).'
fi
if git show-ref --verify --quiet "refs/heads/$base_branch"; then
    base_ref="refs/heads/$base_branch"
elif git show-ref --verify --quiet "refs/remotes/origin/$base_branch"; then
    base_ref="refs/remotes/origin/$base_branch"
else
    fail "Base branch '$base_branch' not found."
fi
base_sha=$(git rev-parse --verify "$base_ref^{commit}")

[ -z "$(git status --porcelain)" ] \
    || fail 'Working tree is not clean. Commit or move your files before syncing.'
for state in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply sequencer; do
    [ ! -e "$(git rev-parse --git-path "$state")" ] \
        || fail "Finish the existing Git operation ($state) first."
done
if ! git remote get-url upstream >/dev/null 2>&1; then
    printf 'ERROR: no "upstream" remote. Add it with:\n  git remote add upstream https://github.com/island-io/mila.git\n' >&2
    exit 1
fi
git var GIT_COMMITTER_IDENT >/dev/null 2>&1 || fail 'No git identity: set user.name and user.email.'

# ---- fetch (never push) ------------------------------------------------------
# Upstream tags live in refs/tags/upstream/* so they never clobber local tags.
git fetch --prune --no-tags upstream \
    '+refs/heads/*:refs/remotes/upstream/*' \
    '+refs/tags/*:refs/tags/upstream/*' >&2 || fail 'Fetching upstream failed.'

if [ "$target" = latest ]; then
    latest_tag=$(git for-each-ref --format='%(refname:strip=3)' 'refs/tags/upstream/v*' \
        | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n 1 || true)
    [ -n "$latest_tag" ] || fail 'No stable vX.Y.Z tag found on upstream.'
    target=$latest_tag
fi
if [ "$target" = main ]; then
    ref=refs/remotes/upstream/main
else
    ref="refs/tags/upstream/$target"
fi
upstream_sha=$(git rev-parse --verify "$ref^{commit}" 2>/dev/null) \
    || fail "No such upstream ref: $target"
short=$(printf '%s' "$upstream_sha" | cut -c1-9)

emit() { # key value
    printf '%s=%s\n' "$1" "$2"
    if [ -n "${GITHUB_OUTPUT:-}" ]; then printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"; fi
}

if git merge-base --is-ancestor "$upstream_sha" "$base_sha"; then
    printf '%s is up to date: it already contains %s (%s).\n' "$base_branch" "$target" "$short"
    emit SYNC_RESULT up-to-date
    emit SYNC_TARGET "$target"
    exit 0
fi

merge_base=$(git merge-base "$base_sha" "$upstream_sha") \
    || fail 'No common history with upstream (unrelated histories).'

# ---- workspace --------------------------------------------------------------
stamp=$(date -u +%Y%m%dT%H%M%SZ)
safe_target=$(printf '%s' "$target" | tr '/' '-')
if [ "$ci" = 1 ]; then
    work=$root
    sync_branch="sync/upstream-$safe_target"
    report=${SYNC_REPORT:-${RUNNER_TEMP:-/tmp}/sync-report.md}
    workspace=$(mktemp -d "${TMPDIR:-/tmp}/mila-upstream.XXXXXX")
    trap 'rm -rf "$workspace"' EXIT
    git checkout -q -B "$sync_branch" "$base_sha"
else
    sync_branch="sync/upstream-$safe_target-$stamp"
    backup="backup/fork-before-$stamp-$$"
    workspace=$(mktemp -d "${TMPDIR:-/tmp}/mila-upstream.XXXXXX")
    work="$workspace/candidate"
    report="$workspace/REPORT.md"
    git tag "$backup" "$base_sha"
    git worktree add -q -b "$sync_branch" "$work" "$base_sha"
fi
cd "$work"

# ---- facts for the report (computed before merging) ---------------------------
git diff --name-only "$merge_base" "$upstream_sha" | sort > "$workspace/upstream-files.txt"
git diff --name-only "$merge_base" "$base_sha" | sort > "$workspace/fork-files.txt"
comm -12 "$workspace/upstream-files.txt" "$workspace/fork-files.txt" > "$workspace/both-files.txt"
git log --oneline "$base_sha..$upstream_sha" > "$workspace/commits.txt"

list_or_none() { # file
    if [ -s "$1" ]; then sed 's/^/- `/; s/$/`/' "$1"; else echo '- none'; fi
}

write_report() { # status-line, structural-file (optional)
    {
        printf '# Upstream sync: %s\n\n' "$target"
        printf -- '- Target: `%s` at `%s`\n' "$target" "$upstream_sha"
        printf -- '- Base: `%s` at `%s`\n' "$base_branch" "$base_sha"
        printf -- '- Merge base: `%s`\n' "$merge_base"
        printf -- '- Result: %s\n\n' "$1"
        printf '## Upstream commits merged (%s)\n\n```\n' "$(grep -c . "$workspace/commits.txt" || true)"
        head -n 200 "$workspace/commits.txt"
        printf '```\n\n'
        if [ -n "${2:-}" ] && [ -s "${2:-}" ]; then
            printf '## Structural conflicts (manual merge required)\n\n'
            list_or_none "$2"
            printf '\nThese are modify/delete, rename or binary conflicts that a "prefer mine" merge cannot settle. Nothing was committed.\n\n'
        fi
        printf '## Files where the fork won (neutral merge conflicted)\n\n'
        list_or_none "$workspace/conflicted-files.txt"
        printf '\nFor each file above, upstream'"'"'s competing hunk was discarded. Read the diff and check it is not a fix you want.\n\n'
        printf '## Files changed by upstream that the fork also changes\n\n'
        list_or_none "$workspace/both-files.txt"
        printf '\nThese merged without a textual conflict only if not listed above; they still need a human look for semantic compatibility.\n\n'
        printf '## Fork hooks (`FORK:`) for reference\n\n<details><summary>git grep -n "FORK:"</summary>\n\n```\n'
        git grep -n "FORK:" -- . ':!docs/fork' ':!FORK.md' ':!scripts/fork' 2>/dev/null | head -n 300 || true
        printf '```\n\n</details>\n\n'
        printf '"Mine wins" is a textual preference, not a semantic guarantee. Security fixes can hide behind it. A green build does not prove recording/audio correctness: smoke-test on a real Mac.\n'
    } > "$report"
}

# ---- merge ------------------------------------------------------------------
: > "$workspace/conflicted-files.txt"
if git -c rerere.enabled=false merge --no-ff --no-commit "$upstream_sha" \
    >"$workspace/neutral-merge.log" 2>&1; then
    :
else
    git diff --name-only --diff-filter=U | sort > "$workspace/conflicted-files.txt"
    if [ ! -s "$workspace/conflicted-files.txt" ]; then
        cat "$workspace/neutral-merge.log" >&2
        fail "Merge failed for a reason other than conflicts. Inspect $workspace"
    fi
    git merge --abort
    if ! git -c rerere.enabled=true -c rerere.autoupdate=false \
        merge --no-ff --no-commit -X ours "$upstream_sha" \
        >"$workspace/preferred-merge.log" 2>&1; then
        git diff --name-only --diff-filter=U | sort > "$workspace/structural-files.txt"
        if [ ! -s "$workspace/structural-files.txt" ]; then
            cat "$workspace/preferred-merge.log" >&2
            fail "Merge failed for a reason other than conflicts. Inspect $workspace"
        fi
        git merge --abort || git reset -q --hard "$base_sha"
        write_report 'STRUCTURAL CONFLICT, nothing committed' "$workspace/structural-files.txt"
        cd "$root"
        if [ "$ci" = 1 ]; then
            git checkout -q "$base_branch" 2>/dev/null || git checkout -q --detach "$base_sha"
            git branch -D "$sync_branch" >/dev/null 2>&1 || true
        else
            git worktree remove --force "$work" >/dev/null 2>&1 || true
            git branch -D "$sync_branch" >/dev/null 2>&1 || true
            git tag -d "$backup" >/dev/null 2>&1 || true
        fi
        printf 'Structural conflict; "prefer mine" cannot resolve it. Nothing was committed.\n' >&2
        emit SYNC_RESULT structural-conflict
        emit SYNC_TARGET "$target"
        emit SYNC_REPORT "$report"
        exit 2
    fi
fi
[ -z "$(git ls-files -u)" ] || fail "Unresolved conflicts remain in $work"

git commit -q -m "Merge upstream $target ($short); prefer fork on conflicting hunks (review required)"
write_report 'merged (review required)'

if [ "$build" = 1 ]; then
    if ! (make project && make build && make test) 2>&1 | tee "$workspace/build-test.log"; then
        fail "Build/tests failed. Branch $sync_branch holds the merge; log: $workspace/build-test.log"
    fi
    git diff --quiet || fail "Build/tests changed tracked files. Review them in $work."
fi

emit SYNC_RESULT merged
emit SYNC_TARGET "$target"
emit SYNC_BRANCH "$sync_branch"
emit SYNC_REPORT "$report"
if [ "$ci" != 1 ]; then
    cat <<EOF

Review branch ready (not adopted, not pushed): $sync_branch
Worktree: $work
Backup tag: $backup
Report: $report
After review, adopt it from your checkout:
  git switch $base_branch
  git merge --ff-only $sync_branch
EOF
fi
