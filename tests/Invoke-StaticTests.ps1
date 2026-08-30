$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$modulePath = Join-Path $root 'src\CPanCleaner.psm1'
Import-Module $modulePath -Force

function Assert-True {
    param(
        [bool] $Condition,
        [string] $Message
    )

    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

function Assert-False {
    param(
        [bool] $Condition,
        [string] $Message
    )

    Assert-True -Condition (-not $Condition) -Message $Message
}

$systemDrive = if ($env:SystemDrive) { $env:SystemDrive.TrimEnd('\') } else { 'C:' }
$defaultTargets = @(Get-CPanCleanerTarget -Include Default)
$allTargets = @(Get-CPanCleanerTarget -Include All)

Assert-True -Condition ($defaultTargets.Count -gt 0) -Message 'Default include should select at least one target.'
Assert-False -Condition (@($defaultTargets | Where-Object { $_.Risk -eq 'High' }).Count -gt 0) -Message 'Default include must not select high-risk targets.'
Assert-False -Condition (@($defaultTargets | Where-Object { $_.Category -eq 'RecycleBin' }).Count -gt 0) -Message 'Default include must not select recycle bin.'
Assert-False -Condition (@($defaultTargets | Where-Object { $_.Category -eq 'NetLimiterStats' }).Count -gt 0) -Message 'Default include must not select NetLimiter statistics.'
Assert-True -Condition (@($defaultTargets | Where-Object { $_.Category -eq 'DiagnosticsCache' }).Count -gt 0) -Message 'Default include should select low-risk diagnostics caches.'
Assert-True -Condition (@($defaultTargets | Where-Object { $_.Category -eq 'InternetCache' }).Count -gt 0) -Message 'Default include should select current-user internet cache.'
Assert-True -Condition (@($defaultTargets | Where-Object { $_.Category -eq 'CrashDumps' }).Count -gt 0) -Message 'Default include should select current-user crash dumps.'
Assert-True -Condition (@($defaultTargets | Where-Object { $_.Category -eq 'BrowserCache' }).Count -gt 0) -Message 'Default include should retain browser cache targets from the single-file release.'
Assert-True -Condition (@($defaultTargets | Where-Object { $_.Category -eq 'GraphicsCache' }).Count -gt 0) -Message 'Default include should retain graphics cache targets from the single-file release.'
Assert-True -Condition (@($allTargets | Where-Object { $_.Category -eq 'WindowsUpdate' }).Count -gt 0) -Message 'All include should expose Windows Update targets.'
Assert-True -Condition (@($allTargets | Where-Object { $_.Category -eq 'RecycleBin' }).Count -eq 1) -Message 'All include should expose recycle bin target.'
Assert-True -Condition (@($allTargets | Where-Object { $_.Category -eq 'NetLimiterStats' }).Count -eq 1) -Message 'All include should expose NetLimiter statistics target.'
Assert-False -Condition (@($allTargets | Where-Object { $_.Category -eq 'VisualStudioPackageCache' }).Count -gt 0) -Message 'All include must not expose Visual Studio package cache target.'

$visualStudioTargets = @(Get-CPanCleanerTarget -Include VisualStudioPackageCache)
Assert-True -Condition ($visualStudioTargets.Count -eq 1) -Message 'Visual Studio package cache should require and accept an exact include.'
Assert-True -Condition ($visualStudioTargets[0].Risk -eq 'High') -Message 'Visual Studio package cache must remain high risk.'
Assert-False -Condition (@($defaultTargets | Where-Object { $_.Category -eq 'VisualStudioPackageCache' }).Count -gt 0) -Message 'Default include must not expose Visual Studio package cache.'

$windowsUpdateDisablePreview = Invoke-CPanCleaner -Action DisableWindowsUpdate -DryRun -Quiet
Assert-True -Condition ($windowsUpdateDisablePreview.Mode -eq 'DryRun') -Message 'DisableWindowsUpdate should default to dry-run mode without -Apply.'
Assert-True -Condition ($windowsUpdateDisablePreview.Items.Count -eq 0) -Message 'DisableWindowsUpdate should not produce file cleanup items.'
Assert-True -Condition (@($windowsUpdateDisablePreview.Diagnostics | Where-Object { $_.Type -eq 'PlannedChange' }).Count -gt 0) -Message 'DisableWindowsUpdate dry-run should report planned changes.'

$performanceOptimizePreview = Invoke-CPanCleaner -Action OptimizePerformance -DryRun -Quiet
Assert-True -Condition ($performanceOptimizePreview.Mode -eq 'DryRun') -Message 'OptimizePerformance should default to dry-run mode without -Apply.'
Assert-True -Condition ($performanceOptimizePreview.Items.Count -eq 0) -Message 'OptimizePerformance should not produce file cleanup items.'
Assert-True -Condition (@($performanceOptimizePreview.Diagnostics | Where-Object { $_.Type -eq 'PerformanceCpu' -or $_.Type -eq 'PlannedChange' -or $_.Type -eq 'PerformanceOptimization' }).Count -gt 0) -Message 'OptimizePerformance dry-run should report performance diagnostics or planned changes.'

$performancePreventPreview = Invoke-CPanCleaner -Action PreventPerformanceSpikes -DryRun -Quiet
Assert-True -Condition ($performancePreventPreview.Mode -eq 'DryRun') -Message 'PreventPerformanceSpikes should default to dry-run mode without -Apply.'
Assert-True -Condition ($performancePreventPreview.Items.Count -eq 0) -Message 'PreventPerformanceSpikes should not produce file cleanup items.'
Assert-True -Condition (@($performancePreventPreview.Diagnostics | Where-Object { $_.Type -eq 'GuardControl' -and $_.Name -eq '\CPanCleaner\PerformanceGuard' }).Count -eq 1) -Message 'PreventPerformanceSpikes should explain that PerformanceGuard is managed separately.'
Assert-True -Condition (@($performancePreventPreview.Diagnostics | Where-Object { $_.Type -eq 'PlannedChange' -and $_.Name -eq 'TGitCacheCheckContentMaxSize' }).Count -eq 1) -Message 'PreventPerformanceSpikes dry-run should plan TortoiseGit content hashing reduction.'
Assert-True -Condition (@($performancePreventPreview.Diagnostics | Where-Object { $_.Type -eq 'PlannedChange' -and $_.Name -eq 'core.fsmonitor' }).Count -eq 1) -Message 'PreventPerformanceSpikes dry-run should plan global Git fsmonitor hardening.'
Assert-True -Condition ($performancePreventPreview.Version -eq '2.3.0') -Message 'Result-location context menu release should report version 2.3.0.'

$guardStatus = Invoke-CPanCleaner -Action ManageGuard -GuardName PerformanceGuard -GuardOperation Status -Quiet
Assert-True -Condition ($guardStatus.Mode -eq 'ReadOnly') -Message 'Guard status must be read-only.'
Assert-True -Condition (@($guardStatus.Diagnostics | Where-Object { $_.Type -eq 'GuardStatus' }).Count -eq 1) -Message 'Guard status should report exactly one task state record.'

$guardEnablePreview = Invoke-CPanCleaner -Action ManageGuard -GuardName PerformanceGuard -GuardOperation Enable -GuardIntervalMinutes 30 -DryRun -Quiet
Assert-True -Condition ($guardEnablePreview.Mode -eq 'DryRun') -Message 'Guard enable should remain dry-run without -Apply.'
Assert-True -Condition (@($guardEnablePreview.Diagnostics | Where-Object { $_.Type -eq 'PlannedChange' -and $_.Detail -match 'Every30Minutes' }).Count -eq 1) -Message 'Guard enable preview should preserve the selected interval.'

$runHistoryPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
$runHistoryBefore = (Get-ItemProperty -LiteralPath $runHistoryPath -ErrorAction SilentlyContinue).Start_TrackProgs
$runHistoryPreview = Invoke-CPanCleaner -Action RepairRunHistory -DryRun -Quiet
$runHistoryAfter = (Get-ItemProperty -LiteralPath $runHistoryPath -ErrorAction SilentlyContinue).Start_TrackProgs
Assert-True -Condition ($runHistoryPreview.Mode -eq 'DryRun') -Message 'Run history repair should remain dry-run without -Apply.'
Assert-True -Condition (@($runHistoryPreview.Diagnostics | Where-Object { $_.Type -eq 'RunHistoryState' }).Count -eq 1) -Message 'Run history preview should report the current state.'
Assert-True -Condition (@($runHistoryPreview.Diagnostics | Where-Object { $_.Type -eq 'PlannedChange' -and $_.Name -eq 'Start_TrackProgs' }).Count -eq 1) -Message 'Run history preview should plan enabling Start_TrackProgs.'
Assert-True -Condition ($runHistoryBefore -eq $runHistoryAfter) -Message 'Run history dry-run must not change Start_TrackProgs.'

$featureCatalogPath = Join-Path $root 'src\CPanCleaner.Gui\Resources\features.json'
$featureCatalog = @(Get-Content -LiteralPath $featureCatalogPath -Raw -Encoding UTF8 | ConvertFrom-Json)
Assert-True -Condition ($featureCatalog.Count -gt 0) -Message 'GUI feature catalog should not be empty.'
foreach ($risk in @('Low', 'Medium', 'High')) {
    Assert-True -Condition (@($featureCatalog | Where-Object { $_.risk -eq $risk }).Count -gt 0) -Message "GUI should expose a $risk risk tab."
}
foreach ($id in @('aggressive-history', 'netlimiter-stats', 'disable-windows-update', 'optimize-performance', 'prevent-performance-spikes', 'performance-guard-task', 'windows-update-guard-task', 'repair-run-history', 'close-widgets', 'visual-studio-packages')) {
    Assert-True -Condition (@($featureCatalog | Where-Object { $_.id -eq $id }).Count -eq 1) -Message "GUI should expose restored historical feature $id exactly once."
}
foreach ($feature in $featureCatalog) {
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($feature.principle)) -Message "Feature $($feature.id) should explain its implementation principle."
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($feature.impact)) -Message "Feature $($feature.id) should explain its potential impact."
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($feature.safeguards)) -Message "Feature $($feature.id) should explain its safeguards."
}

$wrapperPath = Join-Path $root 'CPanCleaner.ps1'
$widgetsCompatibilityJson = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapperPath -Action CloseWidgets -DryRun -Json
$widgetsCompatibility = $widgetsCompatibilityJson | ConvertFrom-Json
Assert-True -Condition ($widgetsCompatibility.Action -eq 'Widgets:Close') -Message 'The 1.0 CloseWidgets command-line action should remain compatible.'
Assert-True -Condition ($widgetsCompatibility.Mode -eq 'DryRun') -Message 'CloseWidgets compatibility action must default to dry-run behavior.'

$moduleSource = Get-Content -LiteralPath $modulePath -Raw -Encoding UTF8
Assert-True -Condition ($moduleSource -match 'git-remote-https\.exe') -Message 'Performance optimization should recognize git-remote-https.exe helpers.'
Assert-True -Condition ($moduleSource -match 'git remote-https') -Message 'Performance optimization should match Git remote HTTPS command lines.'
Assert-True -Condition ($moduleSource -match 'remote-https') -Message 'Performance optimization should match remote-https helper command lines.'
Assert-True -Condition ($moduleSource -match 'ApproxTotalCpuPercent -ge 5') -Message 'Performance optimization should handle hot TGitCache shell-cache CPU loops.'
Assert-True -Condition ($moduleSource -match "Type = 'GitShellCache'") -Message 'Diagnose should report TortoiseGit shell cache helper presence.'
Assert-True -Condition ($moduleSource -match 'PreventPerformanceSpikes') -Message 'Persistent performance prevention action should be exposed.'
Assert-True -Condition ($moduleSource -match 'TGitCacheCheckContentMaxSize') -Message 'Persistent performance prevention should configure TortoiseGit content hashing limit.'
Assert-True -Condition ($moduleSource -match 'MSPCManagerService') -Message 'Performance guard should include Microsoft PC Manager background helper.'
Assert-True -Condition ($moduleSource -match 'NTFSWatcher') -Message 'Performance guard should include Nutstore file watcher background helper.'
Assert-True -Condition ($moduleSource -match 'NutstoreDriverSvc') -Message 'Performance guard should include Nutstore driver background helper.'
Assert-True -Condition ($moduleSource -match 'vss-service-x64') -Message 'Performance guard should include Synology Drive VSS background helper.'
Assert-True -Condition ($moduleSource -match 'vmware-authd') -Message 'Performance guard should include VMware authorization background helper.'
Assert-True -Condition ($moduleSource -match "(?s)Get-Process -Name 'git','git-remote-http','git-remote-https'.+Get-CimInstance Win32_Process") -Message 'Performance guard should avoid CIM unless an exact Git process exists.'
Assert-True -Condition ($moduleSource -match '\[ValidateRange\(5, 1440\)\]') -Message 'Scheduled task intervals should be constrained to 5-1440 minutes.'
Assert-True -Condition ($moduleSource -match 'run-history-backup\.json') -Message 'Run history repair should back up the current registry state before applying.'
Assert-True -Condition ($moduleSource -match 'New-ItemProperty -LiteralPath \$before\.AdvancedPath -Name ''Start_TrackProgs''') -Message 'Run history repair should enable Start_TrackProgs.'
Assert-False -Condition ($moduleSource -match "New-ItemProperty.+-Name 'Start_TrackDocs'") -Message 'Run history repair must not enable unrelated recent-document tracking.'
Assert-True -Condition ($moduleSource -match 'if \(-not \(Test-Path -LiteralPath \$before\.AdvancedPath\)\)') -Message 'Run history repair must not recreate an existing Advanced registry key.'
Assert-True -Condition ($moduleSource -match 'Add-Content.+-Encoding UTF8') -Message 'PowerShell logs should preserve localized Windows error messages as UTF-8.'

$backendSource = Get-Content -LiteralPath (Join-Path $root 'src\CPanCleaner.Gui\Services\CleanerBackend.cs') -Raw -Encoding UTF8
Assert-True -Condition ($backendSource -match 'operation-results') -Message 'GUI operations should use a UTF-8 JSON result backchannel.'
Assert-True -Condition ($backendSource -match 'File\.ReadAllTextAsync\(resultPath') -Message 'GUI should parse the JSON result file instead of localized console output.'

$mainWindowXaml = Get-Content -LiteralPath (Join-Path $root 'src\CPanCleaner.Gui\MainWindow.xaml') -Raw -Encoding UTF8
$mainWindowSource = Get-Content -LiteralPath (Join-Path $root 'src\CPanCleaner.Gui\MainWindow.xaml.cs') -Raw -Encoding UTF8
Assert-True -Condition ($mainWindowXaml -match 'x:Name="OpenResultLocationMenuItem"') -Message 'Result grid should expose an open-location context menu.'
Assert-True -Condition ($mainWindowXaml -match 'PreviewMouseRightButtonDown="ResultGrid_OnPreviewMouseRightButtonDown"') -Message 'Right-click should select the row under the pointer.'
Assert-True -Condition ($mainWindowSource -match 'Path\.IsPathFullyQualified') -Message 'Open-location should require a fully-qualified filesystem path.'
Assert-True -Condition ($mainWindowSource -match 'Directory\.Exists\(fullPath\)') -Message 'Open-location should verify directories exist.'
Assert-True -Condition ($mainWindowSource -match 'File\.Exists\(fullPath\)') -Message 'Open-location should verify files exist.'
Assert-True -Condition ($mainWindowSource -match 'ArgumentList\.Add\("/select,"\)') -Message 'Open-location should select an exact file when the result points to a file.'

$forbiddenFragments = @(
    '\Documents',
    '\Downloads',
    '\Desktop',
    '\Pictures',
    '\Music',
    '\Videos',
    '\Windows\WinSxS',
    '\Windows\servicing\Packages',
    '\Program Files'
)

foreach ($target in $allTargets) {
    foreach ($fragment in $forbiddenFragments) {
        Assert-False -Condition ($target.Path -like "*$fragment*") -Message "Target $($target.Id) points into forbidden fragment $fragment."
    }
}

Assert-True `
    -Condition (Test-CPanPathSafety -Path "$systemDrive\Windows\Temp\cpancleaner-test.tmp" -AllowedRoot "$systemDrive\Windows\Temp") `
    -Message 'Windows temp child should be allowed under its own root.'

Assert-False `
    -Condition (Test-CPanPathSafety -Path "$systemDrive\Windows\Temp" -AllowedRoot "$systemDrive\Windows\Temp") `
    -Message 'Cleaner should not delete a target root unless explicitly allowed.'

Assert-False `
    -Condition (Test-CPanPathSafety -Path "$systemDrive\Windows\WinSxS\manifest.tmp" -AllowedRoot "$systemDrive\Windows") `
    -Message 'WinSxS children must be blocked.'

Assert-False `
    -Condition (Test-CPanPathSafety -Path "$systemDrive\Windows\servicing\Packages\package.tmp" -AllowedRoot "$systemDrive\Windows") `
    -Message 'Windows servicing package children must be blocked.'

if ($env:TEMP) {
    Assert-True `
        -Condition (Test-CPanPathSafety -Path (Join-Path $env:TEMP 'cpancleaner-test.tmp') -AllowedRoot $env:TEMP) `
        -Message 'Current user temp child should be allowed under temp root.'
}

Assert-True `
    -Condition (Test-CPanPathSafety -Path "$systemDrive\ProgramData\Locktime\NetLimiter\5\Stats\nlstats.db" -AllowedRoot "$systemDrive\ProgramData\Locktime\NetLimiter\5\Stats\nlstats.db" -AllowRootItself) `
    -Message 'NetLimiter statistics database file should be allowed only as an explicit file target.'

Assert-True `
    -Condition (Test-CPanPathSafety -Path "$systemDrive\ProgramData\Microsoft\Windows\WER\cpancleaner-test.tmp" -AllowedRoot "$systemDrive\ProgramData\Microsoft\Windows\WER") `
    -Message 'WER cache children should be allowed under their explicit cache root.'

Assert-True `
    -Condition (Test-CPanPathSafety -Path "$systemDrive\ProgramData\Dbg\sym\cpancleaner-test.tmp" -AllowedRoot "$systemDrive\ProgramData\Dbg\sym") `
    -Message 'Debug symbol cache children should be allowed under their explicit cache root.'

Assert-True `
    -Condition (Test-CPanPathSafety -Path "$systemDrive\ProgramData\Microsoft\VisualStudio\Packages\cpancleaner-test.pkg" -AllowedRoot "$systemDrive\ProgramData\Microsoft\VisualStudio\Packages") `
    -Message 'Visual Studio package cache children should only be allowed under the explicit high-risk root.'

if ($env:LOCALAPPDATA) {
    Assert-True `
        -Condition (Test-CPanPathSafety -Path (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\INetCache\cpancleaner-test.tmp') -AllowedRoot (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\INetCache')) `
        -Message 'Current-user INetCache children should be allowed under their explicit cache root.'

    Assert-True `
        -Condition (Test-CPanPathSafety -Path (Join-Path $env:LOCALAPPDATA 'CrashDumps\cpancleaner-test.dmp') -AllowedRoot (Join-Path $env:LOCALAPPDATA 'CrashDumps')) `
        -Message 'Current-user crash dump children should be allowed under their explicit cache root.'
}

Write-Host 'All CPanCleaner static safety tests passed.'
