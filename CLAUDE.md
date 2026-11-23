# FinanceApp: engineering guide

A personal finance app for iPhone in native Swift. `FinanceCore` holds everything that doesn't need iOS and builds on Windows, Linux and macOS. The iOS app will be a thin SwiftUI layer on top, built in CI.

## Rules
- **This repo is public.** Never add real emails, transactions, names, account or card numbers, places, merchants from real data, or categorization rules. Test data is invented: example.com addresses, made-up shops (サンプル商店, SAMPLE STORE), round amounts.
- **Never bypass the privacy guard** (`--no-verify`, editing hooks, changing `core.hooksPath`). If it blocks a commit, it names a file, line and denylist line number; change the invented data there.
- **Never open the denylist** or anything outside this repo unless the owner asks.
- **Native Swift only.** No cross-platform frameworks.
- Plain, short English in code comments and docs. No emoji.

## Build and test (Windows)
The toolchain is on F:. In PowerShell:

```
$env:Path = 'F:\Dev\Swift\Toolchains\6.4.3+Asserts\usr\bin;F:\Dev\Swift\Runtimes\6.4.3\usr\bin;' + $env:Path
$env:SDKROOT = 'F:\Dev\Swift\Platforms\6.4.3\Windows.platform\Developer\SDKs\Windows.sdk\'
swift test
python -I tools/privacy/test_guard.py
```

`.build` is a junction to `F:\Dev\build\FinanceApp`, because C: is nearly full. Delegate worktrees go in `F:\Dev\FinanceApp-worktrees`.

## Layout
- `Sources/FinanceCore/Mail`: Gmail format=full JSON to `MailMessage`, body decoding (UTF-8 or ISO-2022-JP), RFC 2047, Authentication-Results, `SenderCheck`, HTML to text.
- `Sources/FinanceCore/Parsers`: one parser per sender. Unknown layouts that mention money are quarantined, never guessed.
- `Sources/FinanceCore/Matching`: notices to statement rows, one to one; ties stay unresolved.
- `Sources/FinanceCore/Feed`: `NoticeFeed`, the path from a Gmail message to a notice.
- `Sources/finance-feed`: the CLI the private pipeline calls.

## Conventions
- Amounts are whole yen in `Int`. Positive is money out.
- Times are Japan time, as ISO 8601 strings with +09:00.
- JSON output is deterministic: sorted keys, sorted lines, LF.
- Matching uses `TextFold.key`; display text stays exactly as written.
