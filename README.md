# FinanceApp

A personal finance app for iPhone, written in native Swift.

`FinanceCore` is a Swift package. It reads bank, card and app notice emails, turns them into transactions, and matches them against statements. It builds and tests on Windows, Linux and macOS. The iPhone app will reuse it.

## Privacy

This repo is public and holds no personal data: no real emails, transactions, names, account numbers or categorization rules. All test data is invented.

Every clone that commits runs a privacy guard from `tools/privacy`. Its pre-commit, commit-msg and pre-push hooks run gitleaks and check a private denylist kept outside the repo. They also require a GitHub noreply author address. CI scans the full history with gitleaks on every push and runs the guard's canary tests.

Set up a clone (needs Python 3 and gitleaks on PATH):

```
powershell -ExecutionPolicy Bypass -File tools/privacy/install.ps1 -Denylist <path to the private denylist>
```

## Build and test

```
swift build
swift test
```
