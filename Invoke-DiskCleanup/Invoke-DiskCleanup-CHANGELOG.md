# Changelog — Invoke-DiskCleanup.ps1

## 2026-09-01

- Renamed `Set-VSAResult` → `Write-VSAResult`. `Write-` is an approved verb that better
  describes a function emitting a status string, and it resolves PSScriptAnalyzer's
  `PSUseShouldProcessForStateChangingFunctions` warning (which fired purely on the `Set-`
  verb). No behavior change — the function body, Kaseya output path, and `Write-Output`
  are untouched. Updated all three call sites and the reference in
  `Invoke-DiskCleanup-README.md`.
- Added a UTF-8 BOM to the file. It contains ~3,900 non-ASCII bytes (the box-drawing
  section banners) but had no BOM, which Windows PowerShell 5.1 can misread as ANSI and
  mangle. Resolves `PSUseBOMForUnicodeEncodedFile`. Applied at the byte level so line
  endings and all existing content are preserved exactly.

### Known PSScriptAnalyzer findings (intentionally not changed)

26 warnings remain and are accepted as false positives or deliberate design:

- **`PSReviewUnusedParameter` (13)** — false positives. All 13 parameters were verified to
  be used; the rule cannot see usage inside nested function bodies or inside the
  `-Action { ... }` scriptblocks passed to `Invoke-CleanupTask`, which is how this script
  is structured. `Set-StrictMode -Version Latest` means a genuine typo would throw at
  runtime rather than pass silently.
- **`PSAvoidUsingEmptyCatchBlock` (10)** — by design. Each wraps a best-effort ancillary
  operation whose failure must never abort a cleanup run: log write, log rotation, VSA
  result write, join-type detection (falls back to `Local`), DISM process priority,
  killing a timed-out process, and the summary JSON write.
- **`PSUseSingularNouns` (3)** — cosmetic, on `Format-Bytes`, `Get-FreeSpaceBytes`, and
  `Clear-PathAgedFiles`. Left as-is; the plural reads correctly for what each returns.
