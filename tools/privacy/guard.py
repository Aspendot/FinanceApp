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
MAX_BLOB_BYTES = 10 * 1024 * 1024
COMMAND_TIMEOUT = 30
HOOK_TIMEOUT = 120
OID = re.compile(r"(?:[0-9a-f]{40}|[0-9a-f]{64})")
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
    text = "".join(ch for ch in text if not ch.isspace() and unicodedata.category(ch) != "Cf")
    return unicodedata.normalize("NFC", text).translate(_FOLD)


def git(*args: str, data: bytes | None = None) -> bytes:
    r = subprocess.run(
        ["git", *args], input=data, capture_output=True, timeout=COMMAND_TIMEOUT,
        env={**os.environ, "GIT_NO_REPLACE_OBJECTS": "1"},
    )
    if r.returncode != 0:
        raise SetupError(f"git {args[0]} failed")
    return r.stdout


def load_denylist() -> list[Entry]:
    path = os.environ.get("PRIVACY_DENYLIST", "").strip()
    if not path:
        r = subprocess.run(["git", "config", "--get", "privacy.denylist"], capture_output=True, timeout=COMMAND_TIMEOUT)
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
            except re.error:
                raise SetupError(f"denylist line {n} is not a valid regex") from None
        elif fold(t):
            entries.append(Entry(n, fold(t), None))
    if not entries:
        raise SetupError("the denylist is empty")
    return entries


def text_hits(label: str, text: str, entries: list[Entry]) -> list[str]:
    first_hits = {}
    lines = text.splitlines()
    folded = fold(text)
    remaining = {e.line: e.plain for e in entries if e.plain and e.plain in folded}
    for i, line in enumerate(lines or [""], 1):
        nfkc = unicodedata.normalize("NFKC", line)
        for e in entries:
            if e.regex and e.line not in first_hits and e.regex.search(nfkc):
                first_hits[e.line] = i
        if remaining:
            folded_line = fold(line)
            for n, plain in list(remaining.items()):
                if plain in folded_line:
                    first_hits[n] = i
                    del remaining[n]
    hits = [f"{label}:{i} matches denylist line {n}" for n, i in sorted(first_hits.items())]
    return hits + [f"{label}: matches denylist line {n} across lines" for n in remaining]


def file_hits(path: str, blob: bytes, entries: list[Entry], where: str) -> list[str]:
    """Check path and content using the bytes stored in Git."""
    hits = []
    path_matches = text_hits("path", path, entries)
    if path_matches:
        lines = ", ".join(h.rsplit(" ", 1)[-1] for h in path_matches)
        hits.append(f"a path in {where} matches denylist line(s) {lines} (path not shown)")
    path_secrets = gitleaks(path.encode("utf-8"), f"a path in {where}")
    label = "<hidden path>" if path_matches or path_secrets else ascii(path)
    hits += path_secrets
    if Path(path).suffix.lower() in NEVER_COMMIT:
        hits.append(f"{label}: this file type must never be committed")
    if blob.startswith((b"\xff\xfe", b"\xfe\xff", b"\0\0\xfe\xff")):
        return hits + [f"{label}: files with a UTF-16 or UTF-32 BOM are blocked"]
    if b"\0" in blob:
        if not any(rx.fullmatch(path) for rx in ALLOWED_BINARY):
            hits.append(f"{label}: binary files are blocked outside the allowed asset folders")
        elif not blob.startswith(b"\x89PNG\r\n\x1a\n" if path.endswith(".png") else b"%PDF-"):
            hits.append(f"{label}: the file does not match the allowed asset type")
        return hits
    try:
        text = blob.decode("utf-8-sig")
    except UnicodeDecodeError:
        return hits + [f"{label}: text files must be UTF-8"]
    return hits + text_hits(label, text, entries) + gitleaks(text.encode("utf-8"), label)


def identity_hits(label: str, name: str, email: str, entries: list[Entry]) -> list[str]:
    hits = text_hits(f"{label} name", name, entries)
    hits += text_hits(f"{label} email", email, entries)
    if not NOREPLY.fullmatch(email):
        hits.append(f"{label} email is not a GitHub noreply address")
    return hits


def gitleaks(data: bytes | None, label: str, *mode: str) -> list[str]:
    if data == b"":
        return []
    exe = shutil.which("gitleaks")
    if not exe:
        raise SetupError("gitleaks is not installed or not on PATH")
    if not GITLEAKS_CONFIG.is_file():
        raise SetupError("the installed gitleaks config is missing")
    # The installed directory is trusted. Do not load repository suppressions.
    cmd = [exe, *(mode or ("stdin",)), "--redact=100", "--no-banner", "--ignore-gitleaks-allow",
           "--exit-code", "3", "--config", str(GITLEAKS_CONFIG)]
    r = subprocess.run(
        cmd, cwd=HERE, input=data, capture_output=True, timeout=COMMAND_TIMEOUT,
        env={**os.environ, "GIT_NO_REPLACE_OBJECTS": "1"},
    )
    if r.returncode == 3:
        return [f"{label}: gitleaks found a possible secret (value not shown)"]
    if r.returncode != 0:
        raise SetupError("gitleaks failed to scan")
    return []


def gitleaks_git(label: str, *options: str) -> list[str]:
    """Retain the detector's filename-dependent rules alongside full-blob checks."""
    root = git("rev-parse", "--show-toplevel").decode("utf-8").rstrip("\n")
    if os.path.lexists(Path(root) / ".gitleaksignore"):
        raise SetupError("a repository .gitleaksignore file is unsupported")
    return gitleaks(None, label, "git", *options, root)


def blob(oid: str, label: str) -> bytes:
    if int(git("cat-file", "-s", oid)) > MAX_BLOB_BYTES:
        raise SetupError(f"{label} contains a file larger than the scan limit")
    return git("cat-file", "blob", oid)


def changes_hits(changes: bytes, entries: list[Entry], where: str) -> list[str]:
    hits = []
    if not changes:
        return hits
    records = changes.rstrip(b"\0").split(b"\0")
    for raw, raw_path in zip(records[::2], records[1::2], strict=True):
        _, mode, _, oid, _ = raw.decode("ascii").split()
        if mode == "160000":
            hits.append(f"{where} contains a submodule (external contents cannot be checked)")
            continue
        path = raw_path.decode("utf-8")
        hits += file_hits(path, blob(oid, where), entries, where)
    return hits


DIFF = (
    "--raw", "--no-abbrev", "--no-renames", "--no-ext-diff",
    "--ignore-submodules=none", "-z", "--diff-filter=AMT",
)


def pre_commit(entries: list[Entry]) -> list[str]:
    hits = []
    for var, label in (("GIT_AUTHOR_IDENT", "author"), ("GIT_COMMITTER_IDENT", "committer")):
        ident = git("var", var).decode("utf-8")
        m = re.fullmatch(r"(.*) <(.*)> \d+ [+-]\d{4}", ident.rstrip("\n"))
        if not m:
            raise SetupError(f"cannot read the {label} identity")
        hits += identity_hits(label, m.group(1), m.group(2), entries)
        hits += gitleaks(ident.encode("utf-8"), f"{label} identity")
    label = "the staged files"
    changed = git("diff", "--cached", *DIFF)
    hits += changes_hits(changed, entries, label)
    if changed and not hits:
        hits += gitleaks_git(label, "--pre-commit", "--staged")
    return hits


def commit_msg(path: str, entries: list[Entry]) -> list[str]:
    message = Path(path)
    if message.stat().st_size > MAX_BLOB_BYTES:
        raise SetupError("the commit message is larger than the scan limit")
    raw = message.read_bytes()
    # Git decides which lines survive cleanup. At this point a comment may be literal.
    return text_hits("commit message", raw.decode("utf-8-sig"), entries) + gitleaks(raw, "commit message")


def commit_hits(oid: str, parents: list[str], entries: list[Entry]) -> list[str]:
    label = "commit " + oid[:10]
    if int(git("cat-file", "-s", oid)) > MAX_BLOB_BYTES:
        raise SetupError(f"{label} metadata is larger than the scan limit")
    raw = git("cat-file", "commit", oid)
    text = raw.decode("utf-8")
    headers, _, message = text.partition("\n\n")
    hits = text_hits(f"{label} message", message, entries)
    # A continuation line belongs to the preceding header.
    for header in re.split(r"\n(?! )", headers):
        kind, _, value = header.partition(" ")
        if kind in {"author", "committer"}:
            m = re.fullmatch(r"(.*) <(.*)> \d+ [+-]\d{4}", value)
            if not m:
                raise SetupError(f"cannot read the {label} {kind} identity")
            hits += identity_hits(f"{label} {kind}", m.group(1), m.group(2), entries)
        elif kind not in {"tree", "parent"}:
            hits += text_hits(f"{label} header", value, entries)
    hits += gitleaks(raw, label)
    # A merge's result can contain changes that are in none of its parents.
    compared = [parents[0], oid] if parents else ["--root", oid]
    changed = git("diff-tree", "--no-commit-id", "-r", *DIFF, *compared)
    hits += changes_hits(changed, entries, label)
    if changed and not hits:
        log_opts = f"-1 --root --diff-merges=first-parent --no-ext-diff --no-textconv --text {oid}"
        hits += gitleaks_git(label, "--log-opts", log_opts)
    return hits


def pre_push(entries: list[Entry], stdin: str) -> list[str]:
    hits = []
    checked = set()
    if stdin and git("rev-parse", "--is-shallow-repository") == b"true\n":
        raise SetupError("push requires a complete local history")
    for line in stdin.splitlines():
        parts = line.split()
        if len(parts) != 4 or not all(OID.fullmatch(parts[i]) for i in (1, 3)):
            raise SetupError("invalid push ref data")
        _, local_sha, remote_ref, remote_sha = parts
        if not local_sha.strip("0"):
            continue  # Deletion introduces no ref or objects.
        hits += text_hits("destination ref", remote_ref, entries)
        hits += gitleaks(remote_ref.encode("utf-8"), "destination ref")
        # Only branch tips and lightweight tags pointing directly to commits are covered.
        if not remote_ref.startswith(("refs/heads/", "refs/tags/")) or (
            git("cat-file", "-t", local_sha) != b"commit\n"
        ):
            hits.append("push contains a ref other than a branch or a lightweight tag to a commit")
            continue
        rev_range = [local_sha]
        if remote_sha.strip("0"):
            try:
                git("cat-file", "-t", remote_sha)
            except SetupError:
                pass  # Scan all local ancestry when the receiving tip is unavailable.
            else:
                rev_range.append("^" + remote_sha)
        # Commits already on origin are already public, so scanning them again protects
        # nothing. Commits known only from other remotes are still scanned.
        rev_range += ["--not", "--remotes=origin"]
        history = git("rev-list", "--parents", *rev_range)
        for revision in history.decode("ascii").splitlines():
            oid, *parents = revision.split()
            if oid not in checked:
                checked.add(oid)
                hits += commit_hits(oid, parents, entries)
    return hits


def scan(paths: list[str], entries: list[Entry]) -> list[str]:
    hits = []
    for value in paths:
        path = Path(value)
        if not path.exists():
            raise SetupError("a scan path does not exist")
        for f in [path] if path.is_file() else sorted(x for x in path.rglob("*") if x.is_file()):
            if f.stat().st_size > MAX_BLOB_BYTES:
                raise SetupError("a scanned file is larger than the scan limit")
            hits += file_hits(f.as_posix(), f.read_bytes(), entries, "the scanned files")
    return hits


def main(argv: list[str]) -> int:
    arity = {"pre-commit": 1, "commit-msg": 2, "pre-push": 1}
    if not argv or (len(argv) < 2 if argv[0] == "scan" else len(argv) != arity.get(argv[0])):
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
    except (OSError, ValueError, subprocess.TimeoutExpired):
        print("privacy guard: could not read or finish scanning the input, so git is stopped.",
              file=sys.stderr)
        return 2
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


def run_hook(argv: list[str]) -> int:
    try:
        completed = subprocess.run(
            [sys.executable, "-I", __file__, "--worker", *argv], timeout=HOOK_TIMEOUT
        )
    except subprocess.TimeoutExpired:
        print("privacy guard: scan timed out, so git is stopped.", file=sys.stderr)
        return 2
    return completed.returncode


if __name__ == "__main__":
    if sys.argv[1:2] == ["--worker"]:
        sys.exit(main(sys.argv[2:]))
    sys.exit(run_hook(sys.argv[1:]))
