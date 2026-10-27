# Changelog — Invoke-DiskCleanup.ps1

## 2026-09-03 (audit)

Full read-through of all 7 scripts and both READMEs as one body of work, after three rounds
of structural change (task extraction, the log-pollution fixes, the `$LogDir` move, the
`-Delete` inversion) that had only ever been verified in isolation. PSScriptAnalyzer was
already clean of unexpected findings, so everything below is something static analysis
cannot see.

### Breaking: `-MaxRuntimeMinutes` removed from 3 task scripts

`Invoke-ComponentCleanup`, `Remove-OldRestorePoint` and `Remove-WindowsOld` each declared the
parameter, documented it as "Hard cap on total runtime", and assigned `$script:Deadline` from
it — but **none of the three defined `Test-Deadline` or ever read the value**. The cap did
nothing, and `StoppedEarly` / `StopReason` in their summary JSON were permanently `false` /
`""`. PSScriptAnalyzer could not flag it because the parameter *was* referenced, just only to
compute a value nothing consumed.

Removed rather than implemented, because on the merits it earns nothing in any of the three:
`Invoke-ComponentCleanup` already enforces `-ComponentCleanupTimeoutMin` via `WaitForExit`,
`Remove-OldRestorePoint`'s loop is fast and bounded, and `Remove-WindowsOld`'s cost is a
single blocking `Remove-Item` that a deadline check cannot interrupt anyway.

- **A VSA procedure passing `-MaxRuntimeMinutes` to any of those three will now fail** as an
  unknown parameter rather than silently ignore it. Drop the argument.
- The parameter is unchanged and still functional in the other four
  (`Invoke-DiskCleanup`, `Clear-AgedRecycleBin`, `Clear-TeamsCache`, `Remove-StaleProfile`),
  which do define and call `Test-Deadline`.
- `StoppedEarly` / `StopReason` dropped from those three scripts' summary JSON, since nothing
  could ever set them.

### Fixed: `Remove-WindowsOld` reported space it had not reclaimed

It measured the tree, called `Remove-Item -Recurse -Force -ErrorAction SilentlyContinue`, then
unconditionally added the full pre-measured size to the reclaimed total. The task had **no
failure counter at all**. Partial failure on these trees is normal — locked files, ACL edge
cases — so `ReclaimedGB` could claim the whole tree while little or nothing actually went, and
the only contradicting evidence was a `FreeSpaceDeltaGB` that nothing compared it against.

`SilentlyContinue` is retained deliberately (a partial failure must not abort the task), but
its result is no longer trusted: the target is re-measured afterwards, only
`$size - $remaining` is reported, the tree is counted in `Failed`, and the task reports
`WARN` with a log line naming the bytes left behind.

### Fixed: a `takeown` failure aborted the whole WindowsOld task

Found while building a test for the partial-removal path above, and **pre-existing** rather
than introduced by it. `takeown.exe` / `icacls.exe` were invoked as
`& takeown.exe ... *>$null`, intended to discard their output. But in Windows PowerShell 5.1,
redirecting a native command's stderr *inside* PowerShell wraps each line in a
`NativeCommandError` record, and under `$ErrorActionPreference = 'Stop'` that is a
**terminating** error. takeown writes to stderr on exactly the failures worth reporting — a
non-elevated run emits `ERROR: The current logged on user does not have administrative
privileges.` — so the task threw on takeown's first stderr line and was logged as `FAILED`
without attempting the removal at all.

Verified that both `*>$null` and `2>$null` throw this way, and that only lowering the
preference around the call does not. Both invocations now go through a small
`Invoke-NativeTool` helper that drops `$ErrorActionPreference` to `Continue` for the duration,
captures the exit code, and logs a WARN naming the tool, its exit code and its first output
line. Without this the new exit-code check above was unreachable in precisely the case it
existed to report.

### Changed: `ThumbnailCache` no longer reports a fabricated `Failed` count

When `explorer.exe` was running it looped every user profile incrementing `Failed`, reporting
e.g. `0 B from 0 items (3 skipped/locked)` when nothing had been attempted — three phantom
locked files in fleet reporting. The check is loop-invariant, so it now runs once and the task
reports `Status: SKIPPED` with `Failed: 0`. Visible in the summary JSON.

### Main script version settled at 2.0.0

It was inconsistent three ways: help block `2.0.0`, `$ScriptVersion = '1.0.1'` (the value that
actually reaches the log header and summary JSON), README `1.0`. `2.0.0` is correct — since
1.x this script shed 6 opt-in switches to separate scripts and inverted its delete default.
The 6 task scripts were already self-consistent at `1.0.0` and are unchanged.

### Documentation corrected

- **9 broken links to `Tasks\README.md`.** The file is `Tasks\_README.md`, renamed in
  `3d5685e` / `3769614` without updating referrers: 8 markdown links in
  `Invoke-DiskCleanup-README.md` plus one prose reference in the script's own `.DESCRIPTION`
  — which was also pointing readers at the Tasks doc for *this* script's parameters, and now
  points at `Invoke-DiskCleanup-README.md`.
- **README §3.2 described the log-pollution bug as intended behaviour.** It said
  `Test-SafeCleanupPath` "returns `$false`, logs a warning, and skips the target". That
  logging *was* the safety-gate bypass fixed on 2026-09-02. Rewritten, with a note that the
  no-logging property is part of the control rather than a style preference.
- **README §3.3 claimed protected files are "logged by name".** They are counted and reported
  as a per-task total. The sample log and the Phase 1 audit guidance in §8 both showed the
  removed `Protected extension preserved:` line format.
- Sample output showed `Top: WindowsOld 9.77 GB` — a task this script no longer has — and a
  `Path rejected (reason): path` format that never occurs, since the reason string already
  contains the path.
- Added an `Outputs` block and a `.SYNOPSIS` to the main script's help, and reordered it to
  `.SYNOPSIS` → `.DESCRIPTION` → `.NOTES` → `.PARAMETER` to match the 6 task scripts. It was
  the only one of the 7 with no `.SYNOPSIS` at all.
- `Tasks\_README.md` claimed all six scripts accept `-MaxRuntimeMinutes`; it now names the
  three that do, and documents the `WindowsOld` partial-removal reporting.

### Complexity removed

- **`Clear-PathAgedFiles` returned 6 fields, 3 of which nothing read.** `Skipped`,
  `SkipReason` and `ProtectedSkipped` were maintained at every exit path while the actual
  diagnostic channel was `$script:PathSkips` / `$script:ProtectedSkips`. Reduced to
  `Bytes` / `Items` / `Failed` — the three every call site uses — in both the main script and
  `Clear-TeamsCache`.
- `Get-WorkstationJoinType` ran `dsregcmd` once, then made six `Select-String` passes over its
  output to derive three booleans. Now two regex matches; the two flags fully determine all
  four outcomes. The `JoinType` field is unchanged.
- `MemoryDumps` looped over a one-element array holding a hardcoded path. Collapsed to an `if`.

### Tests

- **The `help has SYNOPSIS` check was vacuous.** It matched `SYNOPSIS` in `Get-Help -Full`
  output, but PowerShell prints that section header whether or not the script supplies one —
  so it passed on the main script, which had none. Asserting "synopsis is non-empty" would
  have been vacuous too, in the opposite direction: when help is fully suppressed by the PS
  5.1 blank-line quirk, `.Synopsis` falls back to the auto-generated *syntax line*, which is
  non-empty. Measured all three states and split it into two checks — `help renders`
  (DESCRIPTION present) and `real SYNOPSIS` (non-blank **and** not the syntax line, via the
  new `Test-ScriptSynopsis` helper).
- Added a version-consistency check comparing each script's help `.NOTES Version` against its
  `$ScriptVersion`. This is what would have caught the 2.0.0/1.0.1 drift.
- Added a link check asserting every relative markdown link in both READMEs and this changelog
  resolves to a file that exists. It caught all 8 broken README links on first run.
- **`Invoke-AllTests.ps1` scored an aborted suite as a pass.** Trimming the unread result
  fields broke an assertion in `Test-LogPollutionBugs.ps1`, and the whole suite went quiet
  instead of failing: an error inside a suite's `try`/`finally` aborts the block, `finally`
  runs, and because suites set `$ErrorActionPreference = 'Continue'` execution then resumes at
  `Write-TestSummary`, which reports "0 passed, 0 failed" and exits 0. The runner scored on
  the exit code alone, so a suite that died on its first assertion read as PASS — it briefly
  hid a real regression in this very changeset. The runner now parses the check counts and
  reports `ERROR` for a suite that ran zero checks or produced no summary at all, contributing
  to the failure total so the aggregate can never exit 0. All five classification cases were
  verified directly.
- The two assertions that broke now target `$script:PathSkips` / `$script:ProtectedSkips`
  instead of the removed per-result fields — a strictly better test, since those are the
  channels that actually reach the log in production.

### PSScriptAnalyzer

59 → **60** across the 7 files; main script unchanged at 17. No new rule types. The single
addition is the new `Get-TreeBytes` helper in `Remove-WindowsOld` hitting `PSUseSingularNouns`,
the same accepted cosmetic rule as `Format-Bytes`, `Get-FreeSpaceBytes` and
`Clear-PathAgedFiles`. `PSReviewUnusedParameter` stays at 8 — the 3 removed parameters were
never in that list, precisely because they were referenced without being used.

## 2026-09-03 (later)

### Reporting is now the default; deleting requires -Delete

**Breaking change.** `-ReportOnly` has been **replaced** by `[switch]$Delete` in the main
script and all 6 `Tasks\*.ps1` scripts. Previously, running a script with no switch
deleted; now it performs a full measurement pass and removes nothing.

- **To reclaim space, pass `-Delete`.** Every existing VSA procedure that relied on the old
  "no switch means delete" behaviour must add `-Delete`, or it will silently stop
  reclaiming anything.
- **`-ReportOnly` no longer exists** and will fail as an unknown parameter. Procedures
  passing it should simply drop it — reporting is now what happens by default.
- Internally each script still drives its logic from `$ReportOnly`, derived once as
  `$ReportOnly = -not $Delete` immediately after `param()`. That keeps ~49 existing
  internal reads untouched, so the behavioural diff is confined to argument handling. The
  `ReportOnly` field in the JSON summary is unchanged.
- `.PARAMETER` help updated in all 7 scripts, plus the README parameter table, the
  suggested-profile examples, the deployment sections and the rollout guidance in both
  READMEs.

**Why a bare switch rather than defaulting `-ReportOnly` to `$true`.** That was the first
attempt, and it worked, but it violated PowerShell convention and raised
`PSAvoidDefaultValueSwitchParameter` on all 7 scripts — a switch that defaults to on
inverts the meaning of a switch. It also depended on the caller writing
`-ReportOnly:$false`, an explicit boolean that binds only when the script is invoked
directly in a PowerShell session (which is how VSA X runs these). Under
`powershell.exe -File script.ps1 -ReportOnly:$false` every argument arrives as plain text
and PowerShell 5.1 rejects it with `ParameterArgumentTransformationError` — verified, and it
fails identically as `-ReportOnly:0`, `-ReportOnly false`, and with a `[bool]`-typed
parameter. Opting into the destructive action with a plain switch is the idiomatic fix:
no analyser finding, and it binds under any invocation style.

**Deployment sections corrected in both READMEs.** They previously documented
`powershell.exe -ExecutionPolicy Bypass -NoProfile -File "<path>\Script.ps1" ...`, which is
not how VSA X runs these — it invokes them directly inside an existing PowerShell session.
Both now show direct invocation, and the `Tasks\` note claiming "there is no
`-Switch:$true`" has been rewritten.

## 2026-09-03

### Output directory moved to C:\INS-Temp\Logs\

**Breaking change** for any already-deployed VSA procedure that reads the old paths.

All 7 scripts (the main script and all 6 `Tasks\*.ps1` scripts) now write their log,
JSON summary, and VSA result `.txt` to `C:\INS-Temp\Logs\` instead of split across
`C:\ProgramData\Kaseya\Logs\` (log, summary) and `C:\ProgramData\Kaseya\` directly
(result `.txt`, previously hardcoded rather than derived from `$LogDir`). All three
outputs now live in one folder per script, matching the convention already used by
`Clear-RevitCache.ps1`.

- `$LogDir` changed from `C:\ProgramData\Kaseya\Logs` to `C:\INS-Temp\Logs` in every
  script.
- `Write-VSAResult`'s hardcoded `C:\ProgramData\Kaseya\ScriptResult_$ScriptName.txt` path
  now derives from `$LogDir`, so it moves with everything else.
- **Any VSA procedure with a *Get Variable* step reading the old
  `C:\ProgramData\Kaseya\ScriptResult_*.txt` path must be repointed** at
  `C:\INS-Temp\Logs\ScriptResult_*.txt` before this version is deployed, or result
  capture will silently start reading a stale/missing file.
- `C:\ProgramData\Kaseya` remains in `$script:ProtectedPaths` in the main script and in
  `Tasks\Clear-TeamsCache.ps1` — unrelated to this script's own output, still a real
  system folder worth protecting.
- Updated the "Outputs" block in every script's comment-based help, plus all matching
  paths in `Invoke-DiskCleanup-README.md` and `Tasks\_README.md`.

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
