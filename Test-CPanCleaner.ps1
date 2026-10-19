$ErrorActionPreference = 'Stop'

$requiredFiles = @(
    'CPanCleaner.ps1',
    'README.md',
    'CHANGELOG.md',
    'docs\SAFETY.md',
    'docs\RELEASE.md',
    'docs\FLCLASH_PROXY_ROUTING_AUDIT.md',
    'docs\WINDOWS_WIDGETS.md',
    'tests\Invoke-StaticTests.ps1',
    'tests\CPanCleaner.Gui.LogicTests\CPanCleaner.Gui.LogicTests.csproj',
    'tests\CPanCleaner.Gui.LogicTests\Program.cs'
)

foreach ($file in $requiredFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $file))) {
        throw "Missing required file: $file"
    }
}

& (Join-Path $PSScriptRoot 'tests\Invoke-StaticTests.ps1')

& dotnet run --project (Join-Path $PSScriptRoot 'tests\CPanCleaner.Gui.LogicTests\CPanCleaner.Gui.LogicTests.csproj') --configuration Release
if ($LASTEXITCODE -ne 0) {
    throw "GUI logic tests failed with exit code $LASTEXITCODE."
}
