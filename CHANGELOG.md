# Changelog

## Unreleased

- Removed the `VisualStudioPackageCache` cleanup target and protected it from explicit `-Include` selection because deleting `C:\ProgramData\Microsoft\VisualStudio\Packages` can break Visual Studio instance/workload detection.
- Updated `Run-Clean-Aggressive.bat` so it no longer cleans Visual Studio installer state or package caches.
- Added `OptimizePerformance` action and `Run-Optimize-Performance.bat` for low-risk CPU relief: stop stale Git/Conda helpers, restart TortoiseGit cache when Git background work is looping, flush DNS, disable fsmonitor in affected local repositories, and lower noisy helper priorities.
- Expanded `OptimizePerformance` and `Diagnose` for Explorer/TortoiseGit lag incidents by detecting `git remote-https` helpers and hot `TGitCache.exe` shell-cache CPU loops.
- Added `PreventPerformanceSpikes` action and `Run-Prevent-Performance-Spikes.bat` to persist Git/TortoiseGit performance settings and install a background-helper priority guard task.
- Expanded the performance priority guard to include observed mCloud/mount-space/upload-download/backup-disk and SpaceAgent sync helpers that can otherwise run at High or AboveNormal priority.
- Expanded the performance priority guard to include Lenovo ImController, Synology USB helper, SmpHelp, AweSun, WXWorkWeb, and WeMail after observing them contributing to foreground lag.
- Expanded the performance priority guard to lower Codex/WPS helpers and stop only Codex/OpenAI plugin Git probes that target `github.com/openai/plugins.git`.

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
