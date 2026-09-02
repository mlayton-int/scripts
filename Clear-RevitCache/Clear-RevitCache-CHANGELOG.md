# Changelog — Clear-RevitCache.ps1

## 2026-09-02

Added a **per-user Revit-running guard**, closing the residual risk recorded as declined
in the 2026-09-01 hardening entry. The `LastWriteTime` filter can select cache files
belonging to a model that is open right now, so deleting them risks corruption or lost
unsynced work — not merely a slow re-download.

- New `$SkipProfilesWithRevitRunning` (default `$true`) and `$RevitProcessNames` (default
  `@('Revit.exe')`) configuration variables.
- The guard is **per-profile**: only profiles whose user owns a running Revit process are
  skipped; every other profile on the workstation is still cleaned.
- Profiles are matched by **SID → `Win32_UserProfile.LocalPath`**, not by username. A
  profile folder is not reliably named after its user — duplicates become `user.DOMAIN`
  or `user.000`. Verified against the Azure-AD SID format (`S-1-12-1-…`) as well as
  classic SIDs. Attribution relies on the elevation the script already requires.
- New exit code `5` when profiles were skipped, and `6` when a Revit process is running
  whose owner cannot be determined — in that case no profile can be proven safe, so
  nothing is deleted. `6` is deliberately distinct from `5` so a guard malfunction (which
  could silently persist and leave a machine never cleaned) is distinguishable from the
  routine case of someone simply having Revit open.
- Documented exit-code precedence: `6` > `1` > `3` > `5` > `4` > `0`. Skips outrank the
  threshold gate — "we did not examine everything" is more actionable than "what we
  examined was not worth cleaning" — but genuine deletion failures outrank both.
- **The guard runs before the measure pass**, so the reclaimable total covers only
  profiles that will actually be cleaned. Otherwise the `$MinSpaceToFreeGB` gate could
  open on space the run was never going to reclaim.
- Report mode is unchanged in spirit: it reports what it *would* skip and still always
  exits `0`. An unattributable process there logs a warning that a live run would refuse,
  rather than aborting the scan — nothing is being deleted, so there is no safety issue.
- `Get-RevitInUseProfile` deliberately does no logging. `Write-Log` INFO writes to the
  success stream, so a function that logs cannot cleanly return an object — the same
  trap that previously bit `Invoke-CachePass`. The caller does all logging.
- `Get-RevitCollaborationCachePath` now also returns `ProfilePath`, needed for SID
  matching.
- Summary line gains `Skipped=<n>`; the summary object gains `GuardEnabled`,
  `SkippedProfiles`, `SkippedProfileCount` and `OwnerUnknownPids`.
- Exit codes and the two new variables are documented in `.NOTES`.

**Fixed while re-verifying under elevation: comment-based help was never reachable.**
`Get-Help .\Clear-RevitCache.ps1` returned only a bare syntax line. In Windows PowerShell
5.1, *any* non-blank line abutting the `<#` help block — a `#Requires` statement or even a
plain comment — suppresses the whole block. Inserting one blank line between the
`#Requires` lines and `<#` restores it (43 → 3117 characters of help). This had been
broken since the file was created and was masked by the test harness, which stripped the
`#Requires` lines before running; the harness now leaves them intact.

The same pattern affects
[Invoke-DiskCleanup.ps1](../Invoke-DiskCleanup/Invoke-DiskCleanup.ps1), whose
`#Requires -Version 5.1` also abuts its help block — not changed here, as it was outside
this task.

## 2026-09-01 (audit)

Full read-through after several rounds of feature work. Three real defects, each with a
regression test proven to fail against the previous code:

- **Fixed: profile names containing `[`, `]`, `*` or `?` were silently skipped.** Three
  enumerations used `-Path`, which treats those as wildcard patterns, so a legal Windows
  account like `John[Doe]` had its cache go undiscovered — no error, no log line, nothing
  cleaned. Now `-LiteralPath` throughout, matching the `Test-Path` call that already used
  it.
- **Fixed: malformed threshold line when no cache folders exist.** In report mode with a
  threshold set, a `$null` reclaimable total coerced to `0` and always reported
  `Would NOT meet the 2GB threshold ( MB reclaimable).` — an empty number, and wrong in
  substance, since a machine with no Revit cache is not "below threshold". Resolved by the
  new no-targets branch plus a `$null` guard on the comparison.
- **Fixed: the summary object's documented contract was false.** The code claimed callers
  need not parse the log, but `Write-Log` INFO lines share the success stream, so the
  object is neither the only nor the last item — the `finally` block logs after it. Stream
  behavior is deliberately unchanged (RMM console capture depends on it); the help and the
  emit-site comment now document the real access pattern:
  `& .\Clear-RevitCache.ps1 | Where-Object { $_ -isnot [string] }`. Note `-isnot [string]`
  rather than `-is [PSCustomObject]`: pipeline items are PSObject-wrapped, so the latter
  matches every log line too.

Cleanups:

- A machine with no Revit cache now reports one coherent outcome instead of a WARN that
  none was found followed by "Cache cleanup completed successfully".
- Renamed log level `DEBUG` → `VERBOSE`. It routes to `Write-Verbose`, so it surfaces
  under `-Verbose`, not `-Debug` — confusing next to the `Write-Debug` in the same
  function. Log prefix changes from `[DEBUG]` to `[VERBOSE]`.
- Extracted `ConvertTo-MB`, replacing three copies of `[math]::Round($x / 1MB, 1)`. The
  single GB rounding stays inline.
- Documented all configuration variables in `.NOTES`.
- Added `#Requires -Version 5.1`, matching the sibling script.

## 2026-09-01 (hardening)

Reliability and safety pass. Two latent bugs were found by the new guards themselves:

- **Fixed: `Invoke-CachePass` was returning log text, not just its totals.** `Write-Log`
  emits INFO lines with `Write-Output`, so the function returned
  `[log strings..., $totals]`. It only appeared to work because PowerShell's member
  enumeration silently plucked `.Folders`/`.Bytes` out of the mixed array. The totals now
  come back via `$script:LastPassTotals` instead of the polluted pipeline. Surfaced
  immediately by `Set-StrictMode`.
- **Fixed: the log-directory guard could pass without a usable log.**
  `New-Item -ItemType Directory -Force -ErrorAction Stop` reports success without creating
  anything when a parent path component is a file. The guard now verifies the directory
  exists afterwards and write-probes the log, rather than trusting the return.

Changes:

- Added `Set-StrictMode -Version Latest`.
- Added exit code `2` (`$EXIT_PREREQ`) for prerequisite failures, making real the contract
  the help text already documented.
- `$MaxAgeDays` is validated as `>= 1`. `0` put the cutoff at "now", which selected
  essentially the whole cache including files in active use — the most destructive typo
  the config allowed. A negative `$MinSpaceToFreeGB` is rejected too, rather than silently
  reading as "gate disabled".
- Log initialisation failures now exit `2` with a clear message instead of crashing before
  logging exists.
- Containment guard in `Clear-CacheFolder`: files carrying the `ReparsePoint` attribute and
  anything resolving outside the cache root are skipped. Verified empirically that
  Windows PowerShell 5.1 `Get-ChildItem -Recurse` does **not** walk into directory
  junctions, so the heavier manual-walk rewrite used by the sibling script was unnecessary
  here.
- Profile root is no longer hardcoded to `C:\Users`. It reads `ProfilesDirectory` from the
  registry, falls back to `$env:SystemDrive\Users`, and can be overridden with the new
  `$ProfileRoot` config variable.
- Log rotation: rolls to `<LogPath>.1` past `$MaxLogSizeMB` (default 5), keeping one
  archive. The log previously appended forever.
- `Write-Log` no longer lets a locked or unwritable log derail a run; the failure is
  visible under `-Debug`.

**Considered and declined at the time:** a guard refusing to delete while Revit is
running. Subsequently implemented — see the 2026-09-02 entry.

## 2026-09-01 (later)

- Added a `$MinSpaceToFreeGB` configuration variable acting as a **worthwhile gate**: the
  script measures what it could reclaim first and only deletes if that meets the
  threshold. Clearing this cache forces Revit to re-download from BIM 360, so churning it
  to reclaim a few hundred MB costs users time for negligible disk benefit. `0` (the
  default) disables the gate and preserves the previous behavior exactly.
- Added exit code `4` (`$EXIT_BELOW_THRESHOLD`), returned only when the gate skips
  deletion. It short-circuits before any deletion, so it can never mask the existing
  partial-failure (`3`) or total-failure (`1`) codes.
- Report mode still always exits `0`, including when the threshold would not be met; it
  logs whether the threshold *would* be met instead.
- Extracted the per-target loop into a new `Invoke-CachePass` helper so the measure and
  delete passes share one implementation. The gate's measure pass logs at `DEBUG` so a
  gated delete run does not print two sets of per-folder lines.
- The measure pass is skipped entirely when the gate is off and not reporting, so the
  default configuration still makes exactly one pass over the cache.
- Extended the pipeline summary object with `ThresholdGB`, `ReclaimableBytes`,
  `ReclaimableMB`, `ReclaimableGB`, `ThresholdMet`, and `SkippedBelowThreshold`.
  `Reclaimable*` are `$null` when no measure pass ran, rather than `0`, which would
  falsely read as "nothing to reclaim".
- Reclaimable amounts are reported in MB in log messages; rounding a few MB to GB
  displayed as `0GB`, which read as "nothing to reclaim" when there was plenty.
- Removed a dead `$processedProfiles` HashSet that was populated but never read.
- A machine with no Revit cache folders at all still exits `0`, not `4` — that path is
  intentionally left ahead of the gate so machines without Revit do not alert.

## 2026-09-01

- Replaced `-WhatIf` / `-Confirm` (`SupportsShouldProcess`) with a `$ReportOnly`
  configuration variable. When `$true`, the script performs the same discovery and
  staleness filter and logs how much space would be freed, without deleting anything.
  A report-only run always exits `0`.
- `Clear-CacheFolder` now takes an explicit `-ReportOnly` switch and measures instead of
  deleting when set.
- Per-folder and summary log lines are mode-aware (`Scanning`/`Cleaning`,
  `Reclaimable`/`Freed`) and now include the MB freed/reclaimable per folder.
- The script emits a summary object to the pipeline (`ReportOnly`, `Folders`, `Files`,
  `Bytes`, `FreedMB`, `Failed`) so callers can consume totals without parsing the log.
- Renamed accumulators (`$filesDeleted` → `$filesAffected`, `$foldersCleared` →
  `$foldersProcessed`) and the `Clear-CacheFolder` result property (`FilesDeleted` →
  `Files`) for clarity now that the script can measure as well as delete.
- Renamed helper `Get-RevitCollaborationCachePaths` → `Get-RevitCollaborationCachePath`
  to satisfy PSScriptAnalyzer's `PSUseSingularNouns` rule.
- Added a UTF-8 BOM to the file to satisfy PSScriptAnalyzer's
  `PSUseBOMForUnicodeEncodedFile` rule (the script's banner comments use non-ASCII
  box-drawing characters).
