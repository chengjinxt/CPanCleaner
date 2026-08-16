$ErrorActionPreference = 'Stop'

$requiredFiles = @(
    'CPanCleaner.ps1',
    'README.md',
    'CHANGELOG.md',
    'docs\SAFETY.md',
    'docs\RELEASE.md',
    'docs\WINDOWS_WIDGETS.md',
    'tests\Invoke-StaticTests.ps1'
)

foreach ($file in $requiredFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $file))) {
        throw "Missing required file: $file"
    }
}

& (Join-Path $PSScriptRoot 'tests\Invoke-StaticTests.ps1')
