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
Assert-True -Condition (@($allTargets | Where-Object { $_.Category -eq 'WindowsUpdate' }).Count -gt 0) -Message 'All include should expose Windows Update targets.'
Assert-True -Condition (@($allTargets | Where-Object { $_.Category -eq 'RecycleBin' }).Count -eq 1) -Message 'All include should expose recycle bin target.'
Assert-True -Condition (@($allTargets | Where-Object { $_.Category -eq 'NetLimiterStats' }).Count -eq 1) -Message 'All include should expose NetLimiter statistics target.'
Assert-False -Condition (@($allTargets | Where-Object { $_.Category -eq 'VisualStudioPackageCache' }).Count -gt 0) -Message 'All include must not expose Visual Studio package cache target.'

$visualStudioPackageCacheProtected = $false
try {
    [void] (Get-CPanCleanerTarget -Include VisualStudioPackageCache)
} catch {
    $visualStudioPackageCacheProtected = ($_.Exception.Message -like '*Protected Include value(s): VisualStudioPackageCache*')
}
Assert-True -Condition $visualStudioPackageCacheProtected -Message 'Visual Studio package cache include should be protected.'

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
Assert-True -Condition (@($performancePreventPreview.Diagnostics | Where-Object { $_.Type -eq 'PlannedChange' -and $_.Name -eq '\CPanCleaner\PerformanceGuard' }).Count -eq 1) -Message 'PreventPerformanceSpikes dry-run should plan the performance guard task.'
Assert-True -Condition (@($performancePreventPreview.Diagnostics | Where-Object { $_.Type -eq 'PlannedChange' -and $_.Name -eq 'TGitCacheCheckContentMaxSize' }).Count -eq 1) -Message 'PreventPerformanceSpikes dry-run should plan TortoiseGit content hashing reduction.'
Assert-True -Condition (@($performancePreventPreview.Diagnostics | Where-Object { $_.Type -eq 'PlannedChange' -and $_.Name -eq 'core.fsmonitor' }).Count -eq 1) -Message 'PreventPerformanceSpikes dry-run should plan global Git fsmonitor hardening.'

$moduleSource = Get-Content -LiteralPath $modulePath -Raw -Encoding UTF8
Assert-True -Condition ($moduleSource -match 'git-remote-https\.exe') -Message 'Performance optimization should recognize git-remote-https.exe helpers.'
Assert-True -Condition ($moduleSource -match 'git remote-https') -Message 'Performance optimization should match Git remote HTTPS command lines.'
Assert-True -Condition ($moduleSource -match 'remote-https') -Message 'Performance optimization should match remote-https helper command lines.'
Assert-True -Condition ($moduleSource -match 'ApproxTotalCpuPercent -ge 5') -Message 'Performance optimization should handle hot TGitCache shell-cache CPU loops.'
Assert-True -Condition ($moduleSource -match "Type = 'GitShellCache'") -Message 'Diagnose should report TortoiseGit shell cache helper presence.'
Assert-True -Condition ($moduleSource -match 'PreventPerformanceSpikes') -Message 'Persistent performance prevention action should be exposed.'
Assert-True -Condition ($moduleSource -match 'TGitCacheCheckContentMaxSize') -Message 'Persistent performance prevention should configure TortoiseGit content hashing limit.'

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

if ($env:LOCALAPPDATA) {
    Assert-True `
        -Condition (Test-CPanPathSafety -Path (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\INetCache\cpancleaner-test.tmp') -AllowedRoot (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\INetCache')) `
        -Message 'Current-user INetCache children should be allowed under their explicit cache root.'

    Assert-True `
        -Condition (Test-CPanPathSafety -Path (Join-Path $env:LOCALAPPDATA 'CrashDumps\cpancleaner-test.dmp') -AllowedRoot (Join-Path $env:LOCALAPPDATA 'CrashDumps')) `
        -Message 'Current-user crash dump children should be allowed under their explicit cache root.'
}

Write-Host 'All CPanCleaner static safety tests passed.'
