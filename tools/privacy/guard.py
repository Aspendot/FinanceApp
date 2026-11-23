#!/usr/bin/env python3
"""Privacy guard for this public repo.

Blocks a commit or a push when the change holds a secret (checked by gitleaks)
or a term from the owner's private denylist. The denylist stays outside the repo.
Its path comes from the PRIVACY_DENYLIST environment variable or
`git config privacy.denylist`. Reports name the file, line and denylist line
number, never the matched text, so the output is safe to show to anyone.

  guard.py pre-commit           check staged files, paths and the author
  guard.py commit-msg FILE      check a commit message
  guard.py pre-push             check commits git is about to push (refs on stdin)
  guard.py scan PATH...         check files on disk

Exit codes: 0 clean, 1 blocked, 2 guard not set up. Anything but 0 stops git.
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import unicodedata
from dataclasses import dataclass
from pathlib import Path

HERE = Path(__file__).resolve().parent
GITLEAKS_CONFIG = HERE / "gitleaks.toml"
ZERO_SHA = "0" * 40
NOREPLY = re.compile(r"^[0-9]+\+[A-Za-z0-9-]+@users\.noreply\.github\.com$")
NEVER_COMMIT = {".eml", ".msg", ".mbox", ".dpapi"}
# Binary files are blocked unless their path matches one of these.
ALLOWED_BINARY = [re.compile(p) for p in (r"^App/.+\.xcassets/.+\.(png|pdf)$",)]

_DASHES = "‐‑‒–—―−─━〜ー－～ｰ~"
_FOLD = str.maketrans(
    _DASHES + "ァィゥェォッャュョヮヵヶぁぃぅぇぉっゃゅょゎ",
    "-" * len(_DASHES) + "アイウエオツヤユヨワカケあいうえおつやゆよわ",
)

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")


class SetupError(Exception):
    pass


@dataclass(frozen=True)
class Entry:
    line: int
    plain: str | None
    regex: re.Pattern | None


def fold(text: str) -> str:
    text = unicodedata.normalize("NFKC", text).casefold()
    text = "".join(ch for ch in text if not ch.isspace())
    return unicodedata.normalize("NFC", text).translate(_FOLD)


def git(*args: str, data: bytes | None = None) -> bytes:
    r = subprocess.run(["git", *args], input=data, capture_output=True)
    if r.returncode != 0:
        raise SetupError(f"git {args[0]} failed: {r.stderr.decode('utf-8', 'replace').strip()[:300]}")
    return r.stdout


def load_denylist() -> list[Entry]:
    path = os.environ.get("PRIVACY_DENYLIST", "").strip()
    if not path:
        r = subprocess.run(["git", "config", "--get", "privacy.denylist"], capture_output=True)
        path = r.stdout.decode("utf-8", "replace").strip()
    if not path:
        raise SetupError("no denylist configured (git config privacy.denylist)")
    p = Path(path)
    if not p.is_file():
        raise SetupError("the configured denylist file is missing")
    entries = []
    for n, raw in enumerate(p.read_text("utf-8-sig").splitlines(), 1):
        t = raw.strip()
        if not t or t.startswith("#"):
            continue
        if t.startswith("re:"):
            try:
                entries.append(Entry(n, None, re.compile(t[3:], re.IGNORECASE)))
            except re.error as e:
                raise SetupError(f"denylist line {n} is not a valid regex: {e}") from None
        elif fold(t):
            entries.append(Entry(n, fold(t), None))
    if not entries:
        raise SetupError("the denylist is empty")
    return entries


def text_hits(label: str, text: str, entries: list[Entry]) -> list[str]:
    hits = []
    for i, line in enumerate(text.splitlines() or [""], 1):
        folded = fold(line)
        nfkc = unicodedata.normalize("NFKC", line)
        for e in entries:
            if (e.plain and e.plain in folded) or (e.regex and e.regex.search(nfkc)):
                hits.append(f"{label}:{i} matches denylist line {e.line}")
    return hits


def file_hits(path: str, blob: bytes, entries: list[Entry], where: str) -> list[str]:
    """Checks one file's path and content. A matching path is never printed."""
    hits = []
    if text_hits("path", path, entries):
        lines = sorted({h.rsplit(" ", 1)[-1] for h in text_hits("path", path, entries)})
        hits.append(f"a path in {where} matches denylist line(s) {', '.join(lines)} (path not shown)")
        label = "<hidden path>"
    else:
        label = path
    if Path(path).suffix.lower() in NEVER_COMMIT:
        hits.append(f"{label}: this file type must never be committed")
    if b"\0" in blob[:8192]:
        if not any(rx.search(path) for rx in ALLOWED_BINARY):
            hits.append(f"{label}: binary files are blocked outside the allowed asset folders")
        return hits
    return hits + text_hits(label, blob.decode("utf-8", "replace"), entries)


def identity_hits(label: str, name: str, email: str, entries: list[Entry]) -> list[str]:
    hits = text_hits(f"{label} name", name, entries)
    if not NOREPLY.match(email):
        hits.append(f"{label} email is not a GitHub noreply address")
    return hits


def gitleaks(args: list[str]) -> list[str]:
    exe = shutil.which("gitleaks")
    if not exe:
        raise SetupError("gitleaks is not installed or not on PATH")
    cmd = [exe, *args, "--redact", "--no-banner", "--verbose", "--exit-code", "1"]
    if GITLEAKS_CONFIG.is_file():
        cmd += ["--config", str(GITLEAKS_CONFIG)]
    r = subprocess.run(cmd, capture_output=True)
    out = (r.stdout + r.stderr).decode("utf-8", "replace").strip()
    if r.returncode == 1:
        return ["gitleaks found a possible secret (values redacted):\n" + out]
    if r.returncode != 0:
        raise SetupError("gitleaks failed to run: " + out[-400:])
    return []


def repo_root() -> str:
    return git("rev-parse", "--show-toplevel").decode().strip()


def pre_commit(entries: list[Entry]) -> list[str]:
    hits = []
    for var, label in (("GIT_AUTHOR_IDENT", "author"), ("GIT_COMMITTER_IDENT", "committer")):
        ident = git("var", var).decode("utf-8", "replace")
        m = re.match(r"^(.*) <(.*)> \d+ [+-]\d{4}$", ident.strip())
        if not m:
            raise SetupError(f"cannot read the {label} identity")
        hits += identity_hits(label, m.group(1), m.group(2), entries)
    names = git("diff", "--cached", "--name-only", "-z", "--diff-filter=ACMR").decode("utf-8").split("\0")
    for path in filter(None, names):
        hits += file_hits(path, git("show", f":{path}"), entries, "the staged files")
    return hits + gitleaks(["git", "--pre-commit", "--staged", repo_root()])


def commit_msg(path: str, entries: list[Entry]) -> list[str]:
    text = Path(path).read_text("utf-8", "replace")
    body = "\n".join(line for line in text.splitlines() if not line.startswith("#"))
    return text_hits("commit message", body, entries)


def pre_push(entries: list[Entry], stdin: str) -> list[str]:
    hits = []
    for line in stdin.splitlines():
        parts = line.split()
        if len(parts) != 4 or parts[1] == ZERO_SHA:
            continue
        local_sha, remote_sha = parts[1], parts[3]
        rev_range = [local_sha, "--not", "--remotes"] if remote_sha == ZERO_SHA else [f"{remote_sha}..{local_sha}"]
        for c in git("rev-list", *rev_range).decode().split():
            short = c[:10]
            fields = git("log", "-1", "--format=%an%x00%ae%x00%cn%x00%ce%x00%B", c).decode("utf-8", "replace").split("\0")
            hits += identity_hits(f"commit {short} author", fields[0], fields[1], entries)
            hits += identity_hits(f"commit {short} committer", fields[2], fields[3], entries)
            hits += text_hits(f"commit {short} message", fields[4], entries)
            changed = git("diff-tree", "--no-commit-id", "--name-only", "-r", "-z", "--root", "--diff-filter=ACMR", c)
            for path in filter(None, changed.decode("utf-8").split("\0")):
                hits += file_hits(path, git("show", f"{c}:{path}"), entries, f"commit {short}")
        hits += gitleaks(["git", "--log-opts", " ".join(rev_range), repo_root()])
    return hits


def scan(paths: list[str], entries: list[Entry]) -> list[str]:
    hits = []
    for p in paths:
        for f in [Path(p)] if Path(p).is_file() else sorted(x for x in Path(p).rglob("*") if x.is_file()):
            hits += file_hits(f.as_posix(), f.read_bytes(), entries, "the scanned files")
    return hits


def main(argv: list[str]) -> int:
    if not argv or argv[0] not in {"pre-commit", "commit-msg", "pre-push", "scan"}:
        print(__doc__, file=sys.stderr)
        return 2
    try:
        entries = load_denylist()
        cmd = argv[0]
        if cmd == "pre-commit":
            hits = pre_commit(entries)
        elif cmd == "commit-msg":
            hits = commit_msg(argv[1], entries)
        elif cmd == "pre-push":
            hits = pre_push(entries, sys.stdin.read())
        else:
            hits = scan(argv[1:], entries)
    except SetupError as e:
        print(f"privacy guard: not set up, so git is stopped: {e}.", file=sys.stderr)
        print("Set it up with tools/privacy/install.ps1 (see README).", file=sys.stderr)
        return 2
    if hits:
        print("privacy guard: blocked.", file=sys.stderr)
        for h in hits:
            print("  " + h, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
