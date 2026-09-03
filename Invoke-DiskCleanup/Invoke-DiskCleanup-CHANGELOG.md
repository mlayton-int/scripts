# Changelog — Invoke-DiskCleanup.ps1

## 2026-09-02

### Fixed: the path safety gate was bypassable (and three siblings of the same bug)

`Write-Log` routes INFO **and** WARN to `Write-Output`, so any function that logged and
also returned a value actually returned `@(log strings…, realValue)`. Four functions did
exactly that. Confirmed by regression tests written to fail against the previous code.

- **`Test-SafeCleanupPath` — safety gate bypass.** It logged a WARN before returning
  `$false` in 6 of its 8 rejection paths, so the caller received a 2-element array.
  `-not @(str, $false)` is `$false`, which meant `Clear-PathAgedFiles` **proceeded to
  delete on paths the gate had just rejected**, while the log recorded "Path rejected".
  The reachable trigger was the reparse-point rejection: a junctioned cleanup target
  (some deployments redirect `C:\Windows\Temp`) would be walked through — the exact
  hazard the documented safety model promises to prevent.
- **`Test-TaskEnabled` — `-SkipTasks` did not skip.** Same mechanism: it logged
  "skipped", returned a polluted `$false`, and the task then ran anyway. The deadline and
  free-space-target gates were equally ineffective, so `-MaxRuntimeMinutes` could not stop
  a *new* task from starting (the in-walk deadline check was a clean boolean and did work).
- **`Clear-PathAgedFiles` — task death on a protected extension.** It logged when
  preserving a protected file, so the caller's `$r.Bytes` threw under
  `Set-StrictMode -Version Latest`. `.bak` is on the protected list and plausible in a temp
  folder, so any task encountering one aborted and was logged as FAILED.
- **`Get-UserProfilePath` — corrupted profile list.** It logged in its CIM-failure
  fallback, injecting log strings into `$profilePaths`, which were then treated as profile
  paths.

**Fix:** all four are now pure predicates/producers that do no logging. Rejection reasons
travel back via `[ref]$Reason` out-parameters, and the diagnostics `Clear-PathAgedFiles`
can no longer emit itself (`$script:PathSkips`, `$script:ProtectedSkips`) are drained and
logged by `Invoke-CleanupTask`, which returns nothing and is therefore safe to log from.
Stream behaviour is unchanged, so VSA capture is unaffected.

### Opt-in tasks extracted into standalone scripts

The six opt-in tasks now live in `Tasks\` as fully self-contained scripts, each deployable
to VSA on its own and runnable independently:

| Script | Task |
|---|---|
| `Tasks\Clear-AgedRecycleBin.ps1` | RecycleBin |
| `Tasks\Clear-TeamsCache.ps1` | TeamsCache |
| `Tasks\Remove-WindowsOld.ps1` | WindowsOld |
| `Tasks\Invoke-ComponentCleanup.ps1` | ComponentCleanup |
| `Tasks\Remove-StaleProfile.ps1` | StaleProfiles |
| `Tasks\Remove-OldRestorePoint.ps1` | RestorePoints |

- The 6 switches and 6 tuning parameters are **removed** from this script — passing e.g.
  `-EmptyRecycleBin` now fails as an unknown parameter. Any VSA procedure using them must
  be repointed at the corresponding task script.
- Each task script writes its own `DiskCleanup_<Task>.log`, `_Summary.json` and
  `ScriptResult_DiskCleanup_<Task>.txt`, so per-task procedures never overwrite each
  other's results.
- Task bodies were lifted unchanged. Each script keeps a minimal `Invoke-Task` wrapper
  specifically so the lifted code retains its original `return` semantics — at script
  scope, `return` would skip the summary.
- `Clear-TeamsCache` is the only one carrying the full deletion engine (path safety gate,
  reparse-safe walk, protected extensions, profile enumeration), because it is the only
  one that walks user profile trees. It carries the *fixed* versions.
- Named `Clear-AgedRecycleBin`, not `Clear-RecycleBin`, to avoid colliding with the
  built-in PowerShell 5.1 cmdlet.
- **Trade-off accepted:** self-contained means the ~120-line common block (logging,
  formatting, free-space, result reporting) is duplicated across all six files. A change
  to that shared code must be applied to each.

### Other fixes

- **Log rotation could delete task logs.** The prune filter was `"$ScriptName_*.log"`,
  which as `DiskCleanup_*.log` matches every new per-task log. Archives now use a `-`
  separator (`DiskCleanup-<timestamp>.log`) and the filter anchors on the timestamp, so
  sibling task logs can never be candidates for deletion. Pre-existing `_`-style archives
  are still pruned via a second timestamp-anchored pattern.
- **Comment-based help was unreachable.** `Get-Help` returned only a bare syntax line. In
  Windows PowerShell 5.1 any non-blank line abutting the `<#` block — a `#Requires` or even
  a comment — suppresses the whole block. One blank line restores it (650 → 11,100
  characters of help).
- `.DESCRIPTION` now points at `Tasks\` instead of documenting the removed switches.

### PSScriptAnalyzer

Main script drops from 26 findings to **17** (`PSReviewUnusedParameter` 13 → 7,
`PSAvoidUsingEmptyCatchBlock` 10 → 7, `PSUseSingularNouns` 3). No new rule types. The task
scripts report only those same accepted types. All are the false positives and deliberate
design documented under the 2026-09-01 entry below.

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
