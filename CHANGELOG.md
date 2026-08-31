# Changelog

## 2.4.0 - 2026-08-30

- Added cancellable, BelowNormal-priority `AnalyzeStorage` with `diskusage.exe /c`, bounded .NET fallback, localized CSV parsing, and structured size/recommendation/blocker/migration fields.
- Expanded Chrome and Edge basic-cache cleanup to every valid profile while separating Service Worker offline caches as medium risk.
- Added exact cache targets for VS Code, npm, Jianying, WPS, Qoder, NuGet, Playwright, and WXWork; matching running processes now block apply without being terminated.
- Added high-risk Downloads direct-file review with default-unchecked GUI selection, extension/path/size/time identity validation, signatures, and SHA256 logging.
- Added transactional NuGet global-package migration with NTFS/fixed-drive/space checks, verified copy, user-level path switching, separate source removal, stable rollback state, and rollback support.
- Added read-only Docker, WSL, and Visual Studio capacity/migration guidance using official settings or management entry points; no junction-based migration is used.
- Fixed Windows PowerShell 5.1 localized source decoding by storing the backend module and localized test script as UTF-8 with BOM.
- Added reparse-point, browser whitelist, Qoder boundary, Downloads identity, migration destination, localized CSV, process priority, catalog, and compatibility tests.

## 2.3.0 - 2026-08-30

- Added an execution-result context menu for opening the selected item's filesystem location.
- Right-click now selects the row under the pointer before opening the menu.
- Directory results open directly; file results open Explorer with the exact file selected.
- The menu accepts only existing, fully qualified local filesystem paths and remains disabled for registry, task, and diagnostic-detail rows.

## 2.2.1 - 2026-08-29

- Fixed `RepairRunHistory` failing with `UnauthorizedAccessException` by avoiding `New-Item -Force` on an existing Explorer `Advanced` registry key.
- Added stage names to Run-history repair failures for actionable diagnostics.
- Forced PowerShell console and log output to UTF-8, and changed the GUI to parse every successful operation from a UTF-8 JSON result file instead of localized console output.

## 2.2.0 - 2026-08-29

- Added a GUI-visible `RepairRunHistory` feature for diagnosing and repairing Win+R commands that are not retained.
- The repair identifies disabled `Start_TrackProgs`, missing or unwritable `RunMRU`, and current-user or machine-level Explorer policy blockers.
- Apply mode backs up the original state, changes only current-user launch tracking and blocking user policies, preserves existing command entries, avoids enabling `Start_TrackDocs`, and notifies Explorer without terminating it.

## 2.1.0 - 2026-08-22

- Added GUI-visible management for `PerformanceGuard` and `WindowsUpdateGuard`, including status, enable/update, disable, and a configurable 5–1440 minute interval.
- Decoupled guard installation from `PreventPerformanceSpikes` and `DisableWindowsUpdate`; tasks are created only after explicit user enablement.
- Changed the default guard interval to 15 minutes and avoided idle WMI/CIM queries in `PerformanceGuard` when no Git process exists.
- Added a self-contained `win-x64` publish workflow targeting `dist` for folder-based transfer to other Windows computers.

## 2.0.0 - 2026-08-18

- Added a C# WPF desktop application with separate low-, medium-, and high-risk tabs and grouped features.
- Added a JSON-driven feature catalog with dynamic implementation principles, impact notes, affected paths, safeguards, permissions, and Git history provenance.
- Restored the modular PowerShell backend and the functionality previously exposed through the eight deleted batch entrypoints.
- Restored Windows Update control, NetLimiter cleanup, persistent performance prevention, historical aggressive cleanup, and Widgets user/machine policy flows behind dry-run and explicit confirmations.
- Restored Visual Studio package-cache scanning and explicit cleanup only on the high-risk page; excluded it from `Default`, `All`, and the aggressive combination.
- Merged browser, graphics, minidump, remote-desktop, and previous Codex runtime cache targets from the 1.0.0 single-file release.
- Added UAC orchestration, asynchronous execution, cancellation, structured JSON result display, typed high-risk confirmation, and GUI smoke validation.
- Strengthened age-filter handling and reparse-point rejection in the restored module.

## 1.0.0 - 2026-08-17

- Consolidated every end-user operation into the single self-contained `CPanCleaner.ps1` release file.
- Reduced the public actions to reviewed low-risk scanning, cleanup, transient performance optimization, and current Widgets process closing.
- Removed Windows Update, Delivery Optimization, recycle-bin, NetLimiter, Visual Studio installer cache, persistent task/policy, and general process-killing operations.
- Added strict child-path validation, reparse-point rejection, whole-tree age checks, bounded scans, and non-fatal logging/error handling.
- Added a one-file release and checksum verification guide for use on other computers.

## 0.5.0 - 2026-07-12

- Added `DisableWindowsUpdate` action for disabling Windows Update automatic download activity through explicit policy, service, BITS, and scheduled-task controls.
- Hardened `DisableWindowsUpdate` with protected-service registry `Start=4` updates and a temporary SYSTEM scheduled task for protected UpdateOrchestrator/WaaSMedic tasks.
- Added persistent SYSTEM guard task support through direct allowlisted registry actions to re-apply Windows Update disable controls after boot or service self-healing.
- Added `Run-Disable-WindowsUpdate.bat` UAC entrypoint.
- Added project skill notes under `skills/windows-update-control/SKILL.md` for diagnosing recurring Windows Update downloads.
- Updated README and safety notes with the 2026-07-12 recurrence analysis: policy keys remained set, but update services and UpdateOrchestrator/WaaSMedic tasks had resumed activity.
- Added dry-run static coverage for the new Windows Update disable action.

## 0.4.0 - 2026-07-11

- Ported remaining prototype cleanup coverage into the modular project: Windows Error Reporting cache, debug symbol cache, current-user Internet cache, current-user crash dumps, and old Codex runtime cache directories.
- Added `MinimumAgeHours` for prototype-compatible short-window temp cleanup.
- Added comma-separated `-Include A,B` support in addition to repeated argument syntax.
- Added automatic CSV report output alongside run logs.
- Added root `Test-CPanCleaner.ps1` compatibility test entrypoint.
- Updated README, safety notes, static tests, and `.gitignore` for full prototype parity.

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
