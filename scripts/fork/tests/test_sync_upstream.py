#!/usr/bin/env python3
"""Fixture tests for scripts/fork/sync-upstream.sh.

Every scenario builds throwaway git repositories in a temp dir (no network).
Run:  python3 -I scripts/fork/tests/test_sync_upstream.py
"""
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import traceback
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "sync-upstream.sh"

ENV = {k: v for k, v in os.environ.items()
       if k not in ("GITHUB_OUTPUT", "SYNC_REPORT", "RUNNER_TEMP")}
ENV.update({
    "GIT_AUTHOR_NAME": "Fixture", "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
    "GIT_COMMITTER_NAME": "Fixture", "GIT_COMMITTER_EMAIL": "fixture@example.invalid",
    "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
})


def run(cwd, *args, env=None, check=True):
    e = dict(ENV)
    if env:
        e.update(env)
    return subprocess.run(args, cwd=str(cwd), env=e, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=check)


def git(cwd, *args):
    return run(cwd, "git", *args).stdout.strip()


def sync(cwd, *args, env=None):
    return run(cwd, "bash", str(SCRIPT), *args, env=env, check=False)


def commit_all(repo, msg):
    git(repo, "add", "-A")
    git(repo, "commit", "-q", "-m", msg)


def make_fixture(root, structural=False):
    """upstream: base -> v1.9.6; fork branches off base and edits choice.txt."""
    up = root / "upstream"
    up.mkdir()
    git(up, "init", "-q", "-b", "main")
    (up / "choice.txt").write_text("one\ntwo\nthree\n")
    (up / "independent.txt").write_text("old\n")
    (up / "removed.txt").write_text("base\n")
    (up / "untouched.txt").write_text("x\n")
    commit_all(up, "base")
    fork = root / "fork"
    run(root, "git", "clone", "-q", str(up), str(fork))
    git(fork, "remote", "rename", "origin", "upstream")
    git(fork, "switch", "-q", "-c", "personal")
    (fork / "choice.txt").write_text("one\nMINE\nthree\n")
    (fork / "fork-only.txt").write_text("mine\n")
    if structural:
        (fork / "removed.txt").write_text("fork modification\n")
    commit_all(fork, "fork work")
    (up / "choice.txt").write_text("one\nUPSTREAM\nthree\n")
    (up / "independent.txt").write_text("new upstream improvement\n")
    if structural:
        git(up, "rm", "-q", "removed.txt")
    commit_all(up, "upstream update")
    git(up, "tag", "v1.9.6")
    return fork, up


def make_clean_fixture(root):
    up = root / "upstream"
    up.mkdir()
    git(up, "init", "-q", "-b", "main")
    (up / "a.txt").write_text("a\n")
    commit_all(up, "base")
    fork = root / "fork"
    run(root, "git", "clone", "-q", str(up), str(fork))
    git(fork, "remote", "rename", "origin", "upstream")
    git(fork, "switch", "-q", "-c", "personal")
    (fork / "mine.txt").write_text("mine\n")
    commit_all(fork, "fork work")
    (up / "a.txt").write_text("a2\n")
    commit_all(up, "upstream change")
    git(up, "tag", "v1.0.0")
    return fork, up


def cleanup(fork, result_out):
    """Remove worktrees/workspaces the script created (local mode)."""
    for m in re.finditer(r"^Worktree: (.+)$", result_out, re.M):
        wt = Path(m.group(1))
        run(fork, "git", "worktree", "remove", "--force", str(wt), check=False)
        shutil.rmtree(wt.parent, ignore_errors=True)


def parse_kv(out, key):
    m = re.search(r"^%s=(.*)$" % key, out, re.M)
    return m.group(1) if m else None


def worktrees(fork):
    lines = git(fork, "worktree", "list", "--porcelain").splitlines()
    return [l for l in lines if l.startswith("worktree ")]


# ---------------------------------------------------------------- scenarios
def test_clean_merge(root):
    fork, _ = make_clean_fixture(root)
    before = git(fork, "rev-parse", "HEAD")
    r = sync(fork, "--target", "v1.0.0")
    try:
        assert r.returncode == 0, r.stdout
        assert git(fork, "rev-parse", "HEAD") == before, "original branch moved"
        assert parse_kv(r.stdout, "SYNC_RESULT") == "merged", r.stdout
        branch = parse_kv(r.stdout, "SYNC_BRANCH")
        assert re.match(r"^sync/upstream-v1\.0\.0-\d{8}T\d{6}Z$", branch), branch
        tip = git(fork, "rev-parse", branch)
        assert len(git(fork, "rev-list", "--parents", "-n", "1", tip).split()) == 3, "not a merge commit"
        assert git(fork, "show", branch + ":a.txt") == "a2"
        assert git(fork, "show", branch + ":mine.txt") == "mine"
        assert "refs/tags/backup/fork-before-" in git(fork, "for-each-ref", "refs/tags/backup")
        report = Path(parse_kv(r.stdout, "SYNC_REPORT")).read_text()
        assert "## Upstream commits merged (1)" in report
        assert "upstream change" in report
    finally:
        cleanup(fork, r.stdout)


def test_conflict_mine_wins(root):
    fork, _ = make_fixture(root)
    before = git(fork, "rev-parse", "HEAD")
    r = sync(fork, "--target", "main")
    try:
        assert r.returncode == 0, r.stdout
        assert git(fork, "rev-parse", "HEAD") == before
        branch = parse_kv(r.stdout, "SYNC_BRANCH")
        assert git(fork, "show", branch + ":choice.txt") == "one\nMINE\nthree"
        assert git(fork, "show", branch + ":independent.txt") == "new upstream improvement"
        assert git(fork, "show", branch + ":fork-only.txt") == "mine"
        report = Path(parse_kv(r.stdout, "SYNC_REPORT")).read_text()
        won = report.split("## Files where the fork won")[1].split("## ")[0]
        assert "`choice.txt`" in won and "independent.txt" not in won, won
        # adoption instructions work: fast-forward the personal branch
        git(fork, "merge", "-q", "--ff-only", branch)
        assert git(fork, "show", "HEAD:choice.txt") == "one\nMINE\nthree"
        again = sync(fork, "--target", "main")
        assert again.returncode == 0 and "up to date" in again.stdout, again.stdout
    finally:
        cleanup(fork, r.stdout)


def test_latest_ignores_beta_and_picks_highest(root):
    up = root / "upstream"
    up.mkdir()
    git(up, "init", "-q", "-b", "main")
    (up / "v.txt").write_text("0\n")
    commit_all(up, "base")
    fork = root / "fork"
    run(root, "git", "clone", "-q", str(up), str(fork))
    git(fork, "remote", "rename", "origin", "upstream")
    git(fork, "switch", "-q", "-c", "personal")
    # Created out of order on purpose; sort -V must put 1.10.0 above 1.9.9.
    for tag in ["v1.9.9", "v1.10.0", "v1.11.0-beta.1", "v1.9.10-beta.2"]:
        (up / "v.txt").write_text(tag + "\n")
        commit_all(up, "release " + tag)
        git(up, "tag", tag)
    r = sync(fork)  # default target = latest
    try:
        assert r.returncode == 0, r.stdout
        assert parse_kv(r.stdout, "SYNC_TARGET") == "v1.10.0", r.stdout
        branch = parse_kv(r.stdout, "SYNC_BRANCH")
        assert git(fork, "show", branch + ":v.txt") == "v1.10.0"
    finally:
        cleanup(fork, r.stdout)


def test_up_to_date_noop(root):
    fork, _ = make_clean_fixture(root)
    git(fork, "fetch", "-q", "upstream")
    git(fork, "merge", "-q", "--no-edit", "refs/remotes/upstream/main")
    before = git(fork, "rev-parse", "HEAD")
    r = sync(fork, "--target", "main")
    assert r.returncode == 0, r.stdout
    assert "up to date" in r.stdout and parse_kv(r.stdout, "SYNC_RESULT") == "up-to-date"
    assert git(fork, "rev-parse", "HEAD") == before
    assert len(worktrees(fork)) == 1
    assert git(fork, "branch", "--list", "sync/*") == ""
    # the highest stable tag (v1.0.0) is contained in main too
    r2 = sync(fork)  # latest -> v1.0.0, which main already contains
    assert r2.returncode == 0 and "up to date" in r2.stdout, r2.stdout


def test_structural_conflict_exit2(root):
    fork, _ = make_fixture(root, structural=True)
    before = git(fork, "rev-parse", "HEAD")
    r = sync(fork, "--target", "main")
    assert r.returncode == 2, r.stdout
    assert parse_kv(r.stdout, "SYNC_RESULT") == "structural-conflict"
    assert git(fork, "rev-parse", "HEAD") == before
    assert git(fork, "symbolic-ref", "--short", "HEAD") == "personal"
    assert git(fork, "status", "--porcelain") == ""
    assert git(fork, "branch", "--list", "sync/*") == ""
    assert len(worktrees(fork)) == 1, "worktree left behind"
    report_path = Path(parse_kv(r.stdout, "SYNC_REPORT"))
    try:
        report = report_path.read_text()
        assert "STRUCTURAL CONFLICT" in report
        assert "## Structural conflicts" in report and "`removed.txt`" in report
    finally:
        shutil.rmtree(report_path.parent, ignore_errors=True)


def test_dirty_tree_refused(root):
    fork, _ = make_fixture(root)
    (fork / "choice.txt").write_text("unsaved work\n")
    before = git(fork, "rev-parse", "HEAD")
    r = sync(fork, "--target", "main")
    assert r.returncode == 1 and "not clean" in r.stdout, r.stdout
    assert git(fork, "rev-parse", "HEAD") == before
    assert (fork / "choice.txt").read_text() == "unsaved work\n"
    assert len(worktrees(fork)) == 1


def test_missing_upstream_remote(root):
    fork, _ = make_fixture(root)
    git(fork, "remote", "remove", "upstream")
    r = sync(fork)
    assert r.returncode == 1, r.stdout
    assert "git remote add upstream https://github.com/island-io/mila.git" in r.stdout


def test_detached_head_refused(root):
    fork, _ = make_fixture(root)
    git(fork, "checkout", "-q", "--detach")
    r = sync(fork, "--target", "main")
    assert r.returncode == 1 and "Detached HEAD" in r.stdout, r.stdout


def test_bad_target_rejected(root):
    fork, _ = make_fixture(root)
    r = sync(fork, "--target", "bogus")
    assert r.returncode == 1 and "Bad --target" in r.stdout, r.stdout


def test_build_refused_off_macos(root):
    if platform.system() == "Darwin":
        return
    fork, _ = make_fixture(root)
    r = sync(fork, "--build", "--target", "main")
    assert r.returncode == 1 and "needs macOS" in r.stdout, r.stdout
    assert len(worktrees(fork)) == 1


def test_ci_mode(root):
    fork, _ = make_fixture(root)
    before = git(fork, "rev-parse", "HEAD")
    report_path = root / "out" / "report.md"
    report_path.parent.mkdir()
    gh_out = root / "gh-output.txt"
    r = sync(fork, "--ci", "--target", "v1.9.6", "--base", "personal",
             env={"SYNC_REPORT": str(report_path), "GITHUB_OUTPUT": str(gh_out)})
    assert r.returncode == 0, r.stdout
    assert git(fork, "symbolic-ref", "--short", "HEAD") == "sync/upstream-v1.9.6"
    assert len(worktrees(fork)) == 1, "CI mode must not create a worktree"
    assert git(fork, "rev-parse", "personal") == before, "base branch moved"
    parents = git(fork, "rev-list", "--parents", "-n", "1", "HEAD").split()
    assert len(parents) == 3 and parents[1] == before
    assert git(fork, "show", "HEAD:choice.txt") == "one\nMINE\nthree"
    assert git(fork, "show", "HEAD:independent.txt") == "new upstream improvement"
    out = gh_out.read_text()
    assert "SYNC_RESULT=merged" in out and "SYNC_TARGET=v1.9.6" in out
    assert "SYNC_BRANCH=sync/upstream-v1.9.6" in out
    report = report_path.read_text()
    assert "## Files where the fork won (neutral merge conflicted)" in report
    assert "- `choice.txt`" in report
    also = report.split("## Files changed by upstream that the fork also changes")[1].split("## ")[0]
    assert "`choice.txt`" in also and "`independent.txt`" not in also, also
    assert "## Fork hooks (`FORK:`)" in report
    assert "STRUCTURAL" not in report
    # re-running on the same target is a no-op that reports up-to-date
    git(fork, "switch", "-q", "personal")
    git(fork, "merge", "-q", "--ff-only", "sync/upstream-v1.9.6")
    r2 = sync(fork, "--ci", "--target", "v1.9.6")
    assert r2.returncode == 0 and "up to date" in r2.stdout, r2.stdout


def test_ci_structural_restores_base(root):
    fork, _ = make_fixture(root, structural=True)
    before = git(fork, "rev-parse", "HEAD")
    report_path = root / "report.md"
    r = sync(fork, "--ci", "--target", "main", "--base", "personal",
             env={"SYNC_REPORT": str(report_path)})
    assert r.returncode == 2, r.stdout
    assert git(fork, "symbolic-ref", "--short", "HEAD") == "personal"
    assert git(fork, "rev-parse", "HEAD") == before
    assert git(fork, "branch", "--list", "sync/*") == ""
    assert "`removed.txt`" in report_path.read_text()


TESTS = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]


def main():
    passed = 0
    failed = []
    for fn in TESTS:
        with tempfile.TemporaryDirectory(prefix="fork-sync-fixture-") as d:
            try:
                fn(Path(d))
                passed += 1
                print("ok   %s" % fn.__name__)
            except Exception:
                failed.append(fn.__name__)
                print("FAIL %s" % fn.__name__)
                traceback.print_exc()
    if failed:
        print("FAILED: %d of %d scenarios (%s)" % (len(failed), len(TESTS), ", ".join(failed)))
        return 1
    print("PASS: %d sync-upstream fixture scenarios" % passed)
    return 0


if __name__ == "__main__":
    sys.exit(main())
