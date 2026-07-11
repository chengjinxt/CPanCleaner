[CmdletBinding()]
param(
    [ValidateSet('Scan', 'Clean', 'Diagnose')]
    [string] $Action = 'Scan',

    [string[]] $Include = @('Default'),

    [switch] $Apply,
    [switch] $DryRun,
    [switch] $Elevate,
    [int] $MinimumAgeDays = 1,
    [int] $MinimumAgeHours = -1,
    [int] $MaxScanItems = 100000,
    [string] $LogDirectory,
    [string] $CsvPath,
    [string] $RepositoryPath = (Get-Location).Path,
    [switch] $Json
)

$ErrorActionPreference = 'Stop'
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

    if ($LogDirectory) {
        $arguments += @('-LogDirectory', ('"{0}"' -f $LogDirectory))
    }

    if ($CsvPath) {
        $arguments += @('-CsvPath', ('"{0}"' -f $CsvPath))
    }

    if ($RepositoryPath) {
        $arguments += @('-RepositoryPath', ('"{0}"' -f $RepositoryPath))
    }

    Write-Host 'Requesting Administrator approval through UAC...'
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $arguments | Out-Null
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
    -LogDirectory $LogDirectory `
    -CsvPath $CsvPath `
    -RepositoryPath $RepositoryPath

if ($Json) {
    $result | ConvertTo-Json -Depth 8
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
