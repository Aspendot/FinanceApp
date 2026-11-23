"""Canary tests for the privacy guard: each case must be blocked, and the guard's
output must never repeat the blocked text. Runs locally and in CI with a made-up
denylist. Run: python -I tools/privacy/test_guard.py -v
"""
import os
import secrets
import shutil
import stat
import string
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
GUARD = HERE / "guard.py"
HOOKS = HERE / "hooks"
DENYLIST = "# test denylist\ncanaryterm-7f3a\nテストメイ\nre:\\bzzqx\\d{3}\\b\n"


def fixture_token():
    alphabet = string.ascii_letters + string.digits
    return "ghp_" + "".join(secrets.choice(alphabet) for _ in range(36))


def _rm_readonly(func, path, _exc):
    os.chmod(path, stat.S_IWRITE)
    func(path)


class GuardTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix=".guard-test-", dir=HERE.parent.parent))
        self.assertEqual(self.tmp.resolve().parent, HERE.parent.parent)
        self.addCleanup(shutil.rmtree, self.tmp, onerror=_rm_readonly)
        self.repo = self.tmp / "repo"
        self.repo.mkdir()
        self.deny = self.tmp / "denylist.txt"
        self.deny.write_text(DENYLIST, encoding="utf-8")
        self.git("init", "-q", "-b", "main")

    def git(self, *args, check=True, stdin=None, denylist=True, **settings):
        config = {
            "user.name": "Test",
            "user.email": "1+test@users.noreply.github.com",
            "core.hooksPath": HOOKS.as_posix(),
            "commit.gpgsign": "false",
            "core.autocrlf": "false",
            **settings,
        }
        options = [arg for key, value in config.items() for arg in ("-c", f"{key}={value}")]
        env = {**os.environ, "PRIVACY_DENYLIST": str(self.deny) if denylist else "",
               "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull}
        return subprocess.run(["git", *options, *args], cwd=self.repo, env=env,
                              capture_output=True, text=True, encoding="utf-8",
                              errors="replace", check=check, input=stdin, timeout=60)

    def push_check(self, source=None, destination="refs/heads/main", old=None):
        head = source or self.git("rev-parse", "HEAD").stdout.strip()
        update = f"refs/heads/main {head} {destination} {old or ('0' * len(head))}\n"
        return subprocess.run(
            [sys.executable, "-I", str(GUARD), "pre-push"], cwd=self.repo, input=update,
            env={**os.environ, "PRIVACY_DENYLIST": str(self.deny)}, capture_output=True,
            text=True, encoding="utf-8", timeout=60,
        )

    def commit(self, name, content, msg="add file", **settings):
        p = self.repo / name
        p.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(content, bytes):
            p.write_bytes(content)
        else:
            p.write_text(content, encoding="utf-8", newline="\n")
        self.git("add", "--", name)
        return self.git("commit", "-q", "-m", msg, check=False, **settings)

    def assertBlocked(self, r, *hidden, setup=False):
        out = r.stdout + r.stderr
        self.assertNotEqual(r.returncode, 0, "expected the commit to be blocked:\n" + out)
        reason = "privacy guard: not set up" if setup else "privacy guard: blocked."
        self.assertIn(reason, out)
        for text in hidden:
            self.assertNotIn(text.lower(), out.lower(), "guard output repeated the blocked text")

    def test_clean_commit_passes(self):
        r = self.commit("a.txt", "hello\n")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_plain_entry_matches_case_and_dash_variants(self):
        self.assertBlocked(self.commit("a.txt", "x = 'Canary Term－7F3A'\n"), "canary term", "7f3a")

    def test_halfwidth_kana_and_spaces(self):
        self.assertBlocked(self.commit("a.txt", "ﾃｽﾄ ﾒｲ\n"), "ﾃｽﾄ", "テスト")

    def test_regex_entry(self):
        self.assertBlocked(self.commit("a.txt", "id zzqx123 here\n"), "zzqx")

    def test_matching_path_is_blocked_and_not_shown(self):
        self.assertBlocked(self.commit("canaryterm-7f3a/a.txt", "ok\n"), "canaryterm")

    def test_commit_message(self):
        self.assertBlocked(self.commit("a.txt", "ok\n", msg="fix for canaryterm-7f3a"), "canaryterm")

    def test_raw_email_file_type(self):
        self.assertBlocked(self.commit("mail/x.eml", "From: a\n"))

    def test_binary_outside_asset_folders(self):
        self.assertBlocked(self.commit("x.png", b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR"))

    def test_non_noreply_identity(self):
        self.assertBlocked(self.commit("a.txt", "ok\n", **{"user.email": "someone@example.com"}))

    def test_noreply_email_is_checked_for_terms(self):
        self.deny.write_text("novilume\n", encoding="utf-8")
        self.assertBlocked(self.commit("a.txt", "ok\n", **{
            "user.email": "1+novilume@users.noreply.github.com",
        }), "novilume")

    def test_missing_denylist_fails_closed(self):
        self.assertBlocked(self.commit("a.txt", "ok\n", denylist=False), setup=True)

    def test_empty_denylist_fails_closed(self):
        self.deny.write_text("# empty\n", encoding="utf-8")
        self.assertBlocked(self.commit("a.txt", "ok\n"), setup=True)

    def test_missing_denylist_file_fails_closed(self):
        self.deny.unlink()
        self.assertBlocked(self.commit("a.txt", "ok\n"), setup=True)

    @unittest.skipUnless(shutil.which("gitleaks"), "gitleaks not installed")
    def test_secret_is_blocked_by_gitleaks(self):
        token = fixture_token()
        self.assertBlocked(self.commit("config.txt", f"token = {token}\n"), token)

    def test_pre_push_rechecks_new_ref_history(self):
        self.deny.write_text("unrelated-canary\n", encoding="utf-8")
        self.assertEqual(self.commit("a.txt", "canaryterm-7f3a\n").returncode, 0)
        self.deny.write_text(DENYLIST, encoding="utf-8")
        self.assertBlocked(self.push_check(), "canaryterm")

    def test_pre_push_checks_destination_ref(self):
        self.assertEqual(self.commit("a.txt", "fine\n").returncode, 0)
        self.assertBlocked(self.push_check(destination="refs/heads/canaryterm-7f3a"), "canaryterm")

    def test_pre_push_rejects_unscreened_annotated_tags(self):
        self.assertEqual(self.commit("a.txt", "fine\n").returncode, 0)
        self.git("tag", "-a", "-m", "tag fixture", "fixture")
        tag = self.git("rev-parse", "refs/tags/fixture").stdout.strip()
        self.assertBlocked(self.push_check(source=tag, destination="refs/tags/fixture"))

    def test_auto_merge_runs_staged_file_guard(self):
        self.deny.write_text("unrelated-canary\n", encoding="utf-8")
        self.assertEqual(self.commit("base.txt", "fine\n").returncode, 0)
        self.git("switch", "-qc", "fixture")
        self.assertEqual(self.commit("side.txt", "canaryterm-7f3a").returncode, 0)
        self.git("switch", "-q", "main")
        self.deny.write_text(DENYLIST, encoding="utf-8")
        self.assertBlocked(self.git("merge", "-q", "--no-ff", "fixture", check=False), "canaryterm")

    def test_apply_patch_runs_staged_file_guard(self):
        self.deny.write_text("unrelated-canary\n", encoding="utf-8")
        self.assertEqual(self.commit("base.txt", "fine\n").returncode, 0)
        self.git("switch", "-qc", "fixture")
        self.assertEqual(self.commit("a.txt", "canaryterm-7f3a").returncode, 0)
        patch = self.git("format-patch", "-1", "--stdout").stdout
        self.git("switch", "-q", "main")
        self.deny.write_text(DENYLIST, encoding="utf-8")
        self.assertBlocked(self.git("am", stdin=patch, check=False), "canaryterm")

    def test_pre_push_scans_merge_result(self):
        self.deny.write_text("unrelated-canary\n", encoding="utf-8")
        self.assertEqual(self.commit("base.txt", "fine\n").returncode, 0)
        self.git("switch", "-qc", "fixture")
        self.assertEqual(self.commit("side.txt", "fine\n").returncode, 0)
        self.git("switch", "-q", "main")
        self.assertEqual(self.commit("main.txt", "fine\n").returncode, 0)
        self.git("merge", "-q", "--no-commit", "--no-ff", "fixture")
        self.assertEqual(self.commit("merge.txt", "canaryterm-7f3a\n").returncode, 0)
        self.deny.write_text(DENYLIST, encoding="utf-8")
        self.assertBlocked(self.push_check(), "canaryterm")

    def test_clean_push_and_lightweight_tag_pass(self):
        self.assertEqual(self.commit("a.txt", "fine\n").returncode, 0)
        r = self.push_check(destination="refs/tags/fixture")
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_symlink_target_is_checked_from_git(self):
        oid = self.git("hash-object", "-w", "--stdin", stdin="canaryterm-7f3a").stdout.strip()
        self.git("update-index", "--add", "--cacheinfo", f"120000,{oid},link")
        self.assertBlocked(self.git("commit", "-qm", "add link", check=False), "canaryterm")

    def test_submodule_is_blocked(self):
        self.assertEqual(self.commit("a.txt", "fine\n").returncode, 0)
        oid = self.git("rev-parse", "HEAD").stdout.strip()
        self.git("update-index", "--add", "--cacheinfo", f"160000,{oid},nested")
        self.assertBlocked(self.git("commit", "-qm", "add gitlink", check=False, **{
            "diff.ignoreSubmodules": "all",
        }))

    def test_large_blob_fails_closed(self):
        self.assertBlocked(self.commit("a.txt", b"a" * (10 * 1024 * 1024 + 1)), setup=True)

    def test_plain_entry_matches_across_crlf_and_format_marks(self):
        self.assertBlocked(self.commit("a.txt", "Canary\u200b\r\nTerm-7f3a\n"), "7f3a")

    def test_utf8_bom_is_scanned(self):
        self.assertBlocked(self.commit("a.txt", "canaryterm-7f3a".encode("utf-8-sig")), "canaryterm")

    def test_utf16_is_rejected_even_in_allowed_assets(self):
        self.assertBlocked(self.commit("App/Icons.xcassets/a.png", "canaryterm-7f3a".encode("utf-16")),
                           "canaryterm")

    def test_invalid_utf8_is_rejected(self):
        self.assertBlocked(self.commit("a.txt", b"novi\xfflume\n"))

    def test_binary_detection_checks_past_initial_window(self):
        self.assertBlocked(self.commit("a.txt", b" " * 8192 + b"\0"))

    def test_comment_line_in_verbatim_commit_message_is_checked(self):
        self.assertBlocked(self.commit("a.txt", "ok\n", msg="# canaryterm-7f3a",
                                       **{"commit.cleanup": "verbatim"}), "canaryterm")

    def test_gitleaks_checks_commit_message(self):
        token = fixture_token()
        self.assertBlocked(self.commit("a.txt", "ok\n", msg=f"token = {token}"), token)

    def test_gitleaks_checks_full_blob_despite_repo_diff_settings(self):
        (self.repo / ".gitattributes").write_text("*.txt -diff\n", encoding="utf-8")
        self.git("add", ".gitattributes")
        token = fixture_token()
        marker = "gitleaks" + ":allow"
        self.assertBlocked(self.commit("config.txt", f"token = {token} # {marker}\n"), token)

    def test_gitleaks_checks_paths_without_echoing_them(self):
        token = fixture_token()
        self.assertBlocked(self.commit(f"{token}.txt", "ok\n"), token)

    def test_gitleaks_accepts_uppercase_example_domain(self):
        r = self.commit("a.txt", "fixture@" + "EXAMPLE.COM\n")
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_wall_clock_limit_stops_pathological_regex(self):
        self.deny.write_text("re:(a+)+b\n", encoding="utf-8")
        message = self.repo / "message"
        message.write_text("a" * 1000, encoding="utf-8")
        script = (
            "import runpy, sys; "
            "run_hook = runpy.run_path(sys.argv[1])['run_hook']; "
            "run_hook.__globals__['HOOK_TIMEOUT'] = 1; "
            "sys.exit(run_hook(sys.argv[2:]))"
        )
        r = subprocess.run(
            [sys.executable, "-I", "-c", script, str(GUARD), "commit-msg", str(message)],
            cwd=self.repo, env={**os.environ, "PRIVACY_DENYLIST": str(self.deny)},
            capture_output=True, text=True, encoding="utf-8", timeout=10,
        )
        self.assertEqual(r.returncode, 2, r.stderr)
        self.assertIn("scan timed out", r.stderr)

    def test_gitleaks_config_blocks_postal_mark(self):
        postal = "\u3012" + "000" + "-" + "0000"
        self.assertBlocked(self.commit("a.txt", postal), postal)


if __name__ == "__main__":
    unittest.main()
