$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot 'CPanCleaner.ps1'
if (-not (Test-Path -LiteralPath $scriptPath)) {
    throw 'Missing CPanCleaner.ps1'
}

$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref] $tokens, [ref] $errors) | Out-Null
if ($errors -and $errors.Count -gt 0) {
    $errors | Format-List
    throw 'PowerShell parser reported errors.'
}

$requiredFiles = @(
    'README.md',
    'CHANGELOG.md',
    'docs\SAFETY.md',
    'src\CPanCleaner.psm1',
    'tests\Invoke-StaticTests.ps1',
    'Run-Scan.bat',
    'Run-Clean-Safe.bat',
    'Run-Clean-NetLimiter.bat',
    'Run-Clean-Aggressive.bat'
)

foreach ($file in $requiredFiles) {
    $path = Join-Path $PSScriptRoot $file
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Missing required file: $file"
    }
}

& (Join-Path $PSScriptRoot 'tests\Invoke-StaticTests.ps1')
Write-Output 'CPanCleaner compatibility tests passed.'
