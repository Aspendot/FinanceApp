# FinanceApp

A personal finance app for iPhone, written in native Swift.

`FinanceCore` is a Swift package. It reads bank, card and app notice emails, turns them into transactions, and matches them against statements. It builds and tests on Windows, Linux and macOS. The iPhone app will reuse it.

## Privacy

This repo is public and holds no personal data: no real emails, transactions, names, account numbers or categorization rules. All test data is invented.

Clones that commit use the hooks in `tools/privacy` to check Git content with gitleaks and a private denylist. Commit authors and committers need GitHub noreply addresses. Pushes can create or update branches and lightweight tags pointing at commits. The guard blocks submodules and text files in encodings other than UTF-8. It limits each scanned file to 10 MiB. Allowed PNG and PDF assets still need a manual review for private content. CI scans Git history with gitleaks and runs the guard's canary tests.

Set up a clone (needs Python 3 and gitleaks on PATH):

```
powershell -ExecutionPolicy Bypass -File tools/privacy/install.ps1 -Denylist <path to the private denylist>
```

Reinstall the hooks after updating the guard. The installer keeps the active copy outside the worktree.

## Build and test

```
swift build
swift test
```
