$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $root 'CPanCleaner.ps1'

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

$tokens = $null
$parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref] $tokens, [ref] $parseErrors) | Out-Null
Assert-True ($parseErrors.Count -eq 0) 'CPanCleaner.ps1 must parse without errors.'

$source = Get-Content -LiteralPath $scriptPath -Raw -Encoding UTF8
Assert-True ($source -match "ValidateSet\('Scan', 'Clean', 'OptimizePerformance', 'CloseWidgets'\)") 'Only the reviewed actions should be exposed.'
Assert-True ($source -match '\$Apply -and -not \$DryRun') 'Real changes must require -Apply and respect -DryRun.'
Assert-True ($source -match 'FileAttributes\]::ReparsePoint') 'Reparse points must be skipped.'
Assert-True ($source -match 'codex-primary-runtime\.previous-\*') 'Only previous Codex runtimes may be selected.'

$forbidden = @(
    'DisableWindowsUpdate',
    'PreventPerformanceSpikes',
    'Clear-RecycleBin',
    'SoftwareDistribution',
    'DeliveryOptimization',
    'NetLimiterStats',
    'VisualStudioPackageCache',
    'schtasks.exe',
    'Stop-Service',
    'Set-ItemProperty'
)
foreach ($fragment in $forbidden) {
    Assert-True (-not $source.Contains($fragment)) "Forbidden behavior remains in the executable: $fragment"
}

$obsoleteFiles = @(
    'src\CPanCleaner.psm1',
    'scripts\Close-WindowsWidgets.ps1',
    'Run-Scan.bat',
    'Run-Clean-Safe.bat',
    'Run-Clean-Aggressive.bat',
    'Run-Clean-NetLimiter.bat',
    'Run-Disable-WindowsUpdate.bat',
    'Run-Optimize-Performance.bat',
    'Run-Prevent-Performance-Spikes.bat',
    'Run-Close-WindowsWidgets.bat'
)
foreach ($relativePath in $obsoleteFiles) {
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $root $relativePath))) "Obsolete executable still exists: $relativePath"
}

$json = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Action Scan -MaxScanItems 1000 -LogDirectory (Join-Path $root 'logs') -Json
$result = $json | ConvertFrom-Json
Assert-True ($result.Version -eq '1.0.0') 'Scan should report version 1.0.0.'
Assert-True ($result.Action -eq 'Scan') 'Scan should report the requested action.'
Assert-True ($result.Mode -eq 'ReadOnly') 'Scan must be read-only.'
Assert-True (@($result.Items | Where-Object { $_.Id -like 'PackageTempState:*' }).Count -eq 0) 'UWP TempState targets should not be included.'

$previewJson = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Action CloseWidgets -Json
$preview = $previewJson | ConvertFrom-Json
Assert-True ($preview.Mode -eq 'DryRun') 'CloseWidgets must default to dry-run.'
Assert-True (@($preview.Diagnostics | Where-Object { $_.Status -eq 'Closed' }).Count -eq 0) 'CloseWidgets preview must not stop processes.'

Write-Output 'All CPanCleaner safety tests passed.'
