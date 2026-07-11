# Changelog

## 0.3.0 - 2026-07-11

- Added explicit `VisualStudioPackageCache` include target for `C:\ProgramData\Microsoft\VisualStudio\Packages`.
- Added double-click batch entrypoints migrated from the prototype project.
- Updated aggressive batch cleanup to include Windows Update, Delivery Optimization, old quarantine directories, NetLimiter statistics, and Visual Studio package cache targets.
- Updated README, safety notes, and static safety tests for prototype parity.

## 0.2.0 - 2026-07-11

- Added explicit `NetLimiterStats` include target for `C:\ProgramData\Locktime\NetLimiter\5\Stats\nlstats.db`.
- Added NetLimiter service handling for real cleanup: stop `NLSvc`, remove `nlstats.db`, and restart `NLSvc` when it was originally running.
- Updated README and static safety tests for the NetLimiter statistics database target.

## 0.1.0 - 2026-07-11

- Initial CPanCleaner PowerShell project.
- Added safe scan, dry-run, and apply workflow.
- Added low-risk default temp cleanup.
- Added opt-in Windows Update, Delivery Optimization, Recycle Bin, and old quarantine cleanup targets.
- Added read-only Git fsmonitor and Conda residual diagnostics.
- Added path safety checks for system component libraries, user document folders, and program directories.
- Added README, safety notes, logs directory placeholder, and static safety tests.
