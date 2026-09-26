[CmdletBinding()]
param(
    [ValidateSet('Scan', 'Clean', 'AnalyzeStorage', 'ReviewDownloads', 'Migrate', 'Diagnose', 'DisableWindowsUpdate', 'RestoreWindowsUpdate', 'OptimizePerformance', 'PreventPerformanceSpikes', 'ManageGuard', 'RepairRunHistory', 'CloseWidgets')]
    [string] $Action = 'Scan',

    [string[]] $Include = @('Default'),

    [switch] $Apply,
    [switch] $DryRun,
    [switch] $Elevate,
    [ValidateRange(0, 3650)]
    [int] $MinimumAgeDays = 1,
    [ValidateRange(-1, 87600)]
    [int] $MinimumAgeHours = -1,
    [ValidateRange(1000, 1000000)]
    [int] $MaxScanItems = 100000,
    [ValidateSet('Profile', 'Applications', 'All')]
    [string] $AnalysisScope = 'Profile',
    [ValidateSet('NuGetPackages')]
    [string] $MigrationTarget = 'NuGetPackages',
    [ValidateSet('Preview', 'Prepare', 'RemoveSource', 'Rollback')]
    [string] $MigrationOperation = 'Preview',
    [string] $DestinationPath,
    [string[]] $SelectedItemTokens = @(),
    [string] $LogDirectory,
    [string] $CsvPath,
    [string] $RepositoryPath = (Get-Location).Path,
    [ValidateSet('PerformanceGuard', 'WindowsUpdateGuard')]
    [string] $GuardName = 'PerformanceGuard',
    [ValidateSet('Status', 'Enable', 'Disable')]
    [string] $GuardOperation = 'Status',
    [ValidateRange(5, 1440)]
    [int] $GuardIntervalMinutes = 15,
    [string] $JsonOutputPath,
    [switch] $Json
)

$ErrorActionPreference = 'Stop'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding = $utf8NoBom
$modulePath = Join-Path $PSScriptRoot 'src\CPanCleaner.psm1'
Import-Module $modulePath -Force

if ($Elevate -and -not (Test-CPanAdministrator)) {
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $PSCommandPath),
        '-Action', $Action,
        '-Include'
    )

    foreach ($item in $Include) {
        $arguments += $item
    }

    if ($Apply) { $arguments += '-Apply' }
    if ($DryRun) { $arguments += '-DryRun' }
    if ($Json) { $arguments += '-Json' }
    $arguments += @('-MinimumAgeDays', $MinimumAgeDays)
    $arguments += @('-MinimumAgeHours', $MinimumAgeHours)
    $arguments += @('-MaxScanItems', $MaxScanItems)
    $arguments += @('-AnalysisScope', $AnalysisScope)
    $arguments += @('-MigrationTarget', $MigrationTarget)
    $arguments += @('-MigrationOperation', $MigrationOperation)

    if ($DestinationPath) {
        $arguments += @('-DestinationPath', ('"{0}"' -f $DestinationPath))
    }

    if ($SelectedItemTokens.Count -gt 0) {
        $arguments += '-SelectedItemTokens'
        foreach ($token in $SelectedItemTokens) { $arguments += $token }
    }

    if ($LogDirectory) {
        $arguments += @('-LogDirectory', ('"{0}"' -f $LogDirectory))
    }

    if ($CsvPath) {
        $arguments += @('-CsvPath', ('"{0}"' -f $CsvPath))
    }

    if ($RepositoryPath) {
        $arguments += @('-RepositoryPath', ('"{0}"' -f $RepositoryPath))
    }

    $arguments += @('-GuardName', $GuardName)
    $arguments += @('-GuardOperation', $GuardOperation)
    $arguments += @('-GuardIntervalMinutes', $GuardIntervalMinutes)

    if ($JsonOutputPath) {
        $arguments += @('-JsonOutputPath', ('"{0}"' -f $JsonOutputPath))
    }

    Write-Host 'Requesting Administrator approval through UAC...'
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $arguments | Out-Null
    return
}

if ($Action -eq 'CloseWidgets') {
    $widgetsScript = Join-Path $PSScriptRoot 'scripts\Close-WindowsWidgets.ps1'
    & $widgetsScript `
        -Action Close `
        -Apply:$Apply `
        -DryRun:$DryRun `
        -Json:$Json `
        -JsonOutputPath $JsonOutputPath
    return
}

$result = Invoke-CPanCleaner `
    -Action $Action `
    -Include $Include `
    -Apply:$Apply `
    -DryRun:$DryRun `
    -MinimumAgeDays $MinimumAgeDays `
    -MinimumAgeHours $MinimumAgeHours `
    -MaxScanItems $MaxScanItems `
    -AnalysisScope $AnalysisScope `
    -MigrationTarget $MigrationTarget `
    -MigrationOperation $MigrationOperation `
    -DestinationPath $DestinationPath `
    -SelectedItemTokens $SelectedItemTokens `
    -LogDirectory $LogDirectory `
    -CsvPath $CsvPath `
    -RepositoryPath $RepositoryPath `
    -GuardName $GuardName `
    -GuardOperation $GuardOperation `
    -GuardIntervalMinutes $GuardIntervalMinutes

$jsonResult = $null
if ($Json -or $JsonOutputPath) {
    $jsonResult = $result | ConvertTo-Json -Depth 8
}

if ($JsonOutputPath) {
    $jsonDirectory = Split-Path -Parent $JsonOutputPath
    if ($jsonDirectory) {
        New-Item -ItemType Directory -Path $jsonDirectory -Force | Out-Null
    }
    Set-Content -LiteralPath $JsonOutputPath -Value $jsonResult -Encoding UTF8
}

if ($Json) {
    $jsonResult
    return
}

Write-Host ''
Write-Host ('CPanCleaner {0} | Action: {1} | Mode: {2} | Admin: {3}' -f $result.Version, $result.Action, $result.Mode, $result.IsAdministrator)
Write-Host ('Log: {0}' -f $result.LogPath)
if ($result.CsvPath) {
    Write-Host ('CSV: {0}' -f $result.CsvPath)
}
Write-Host ''

if ($result.Items.Count -gt 0) {
    $result.Items |
        Select-Object Id, Category, Risk, Status, Exists, EstimatedMB, ItemCount, RemovedCount, Path, Message |
        Format-Table -AutoSize
}

if ($result.Diagnostics.Count -gt 0) {
    $result.Diagnostics |
        Select-Object Type, Severity, Name, Id, Message, Detail |
        Format-Table -AutoSize
}

if ($result.Action -eq 'Clean' -and $result.Mode -eq 'DryRun') {
    Write-Host ''
    Write-Host 'Dry-run complete. Re-run with -Apply to remove the listed candidates.'
}

if ($result.Action -eq 'DisableWindowsUpdate' -and $result.Mode -eq 'DryRun') {
    Write-Host ''
    Write-Host 'Dry-run complete. Re-run with -Apply -Elevate to disable Windows Update automatic downloads.'
}

if ($result.Action -eq 'OptimizePerformance' -and $result.Mode -eq 'DryRun') {
    Write-Host ''
    Write-Host 'Dry-run complete. Re-run with -Apply to stop stale Git/Conda helpers, flush DNS, and lower noisy helper priorities.'
}

if ($result.Action -eq 'PreventPerformanceSpikes' -and $result.Mode -eq 'DryRun') {
    Write-Host ''
    Write-Host 'Dry-run complete. Re-run with -Apply -Elevate to set persistent Git/TortoiseGit performance settings and install the performance guard task.'
}
