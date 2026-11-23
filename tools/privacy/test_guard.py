"""Canary tests for the privacy guard: each case must be blocked, and the guard's
output must never repeat the blocked text. Runs locally and in CI with a made-up
denylist. Run: python tools/privacy/test_guard.py -v
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


def _rm_readonly(func, path, _exc):
    os.chmod(path, stat.S_IWRITE)
    func(path)


class GuardTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.repo = self.tmp / "repo"
        self.repo.mkdir()
        self.deny = self.tmp / "denylist.txt"
        self.deny.write_text(DENYLIST, encoding="utf-8")
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.name", "Test")
        self.git("config", "user.email", "1+test@users.noreply.github.com")
        self.git("config", "core.hooksPath", HOOKS.as_posix())
        self.git("config", "privacy.denylist", self.deny.as_posix())
        self.git("config", "commit.gpgsign", "false")
        self.git("config", "core.autocrlf", "false")

    def tearDown(self):
        shutil.rmtree(self.tmp, onerror=_rm_readonly)

    def git(self, *args, check=True, stdin=None):
        return subprocess.run(["git", *args], cwd=self.repo, capture_output=True, text=True,
                              encoding="utf-8", errors="replace", check=check, input=stdin)

    def commit(self, name, content, msg="add file", verify=True):
        p = self.repo / name
        p.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(content, bytes):
            p.write_bytes(content)
        else:
            p.write_text(content, encoding="utf-8", newline="\n")
        self.git("add", "--", name)
        return self.git("commit", "-q", "-m", msg, *([] if verify else ["--no-verify"]), check=False)

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
        self.git("config", "user.email", "someone@example.com")
        self.assertBlocked(self.commit("a.txt", "ok\n"))

    def test_missing_denylist_fails_closed(self):
        self.git("config", "--unset", "privacy.denylist")
        self.assertBlocked(self.commit("a.txt", "ok\n"), setup=True)

    def test_missing_denylist_file_fails_closed(self):
        self.deny.unlink()
        self.assertBlocked(self.commit("a.txt", "ok\n"), setup=True)

    @unittest.skipUnless(shutil.which("gitleaks"), "gitleaks not installed")
    def test_secret_is_blocked_by_gitleaks(self):
        token = "ghp_" + "".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(36))
        self.assertBlocked(self.commit("config.txt", f"token = {token}\n"), token)

    @unittest.skipUnless(shutil.which("gitleaks"), "gitleaks not installed")
    def test_pre_push_catches_a_commit_made_with_no_verify(self):
        self.assertEqual(self.commit("a.txt", "fine\n").returncode, 0)
        r = self.commit("b.txt", "canaryterm-7f3a\n", verify=False)
        self.assertEqual(r.returncode, 0, r.stderr)
        head = self.git("rev-parse", "HEAD").stdout.strip()
        line = f"refs/heads/main {head} refs/heads/main {'0' * 40}\n"
        p = subprocess.run([sys.executable, "-I", str(GUARD), "pre-push"], cwd=self.repo, input=line,
                           capture_output=True, text=True, encoding="utf-8")
        self.assertBlocked(p, "canaryterm")


if __name__ == "__main__":
    unittest.main()
