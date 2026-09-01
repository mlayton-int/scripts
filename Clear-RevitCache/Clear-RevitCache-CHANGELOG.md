# Changelog — Clear-RevitCache.ps1

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
