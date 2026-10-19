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

$apnicFixture = @(
    'apnic|CN|ipv4|1.0.1.0|256|20110414|allocated',
    'apnic|JP|ipv4|1.0.16.0|4096|20110412|allocated',
    'apnic|CN|ipv6|2001:250::|32|19990826|allocated'
)
$chinaRanges = @(ConvertFrom-CPanApnicDelegatedData -Lines $apnicFixture)
Assert-True -Condition ($chinaRanges.Count -eq 1) -Message 'APNIC parser should keep only China IPv4 ranges.'
$apnicByteFixture = [System.Text.Encoding]::UTF8.GetBytes(($apnicFixture -join "`n"))
$chinaRangesFromBytes = @(ConvertFrom-CPanApnicDelegatedData -Lines $apnicByteFixture)
Assert-True -Condition ($chinaRangesFromBytes.Count -eq 1) -Message 'APNIC parser should decode application/octet-stream byte responses from Windows PowerShell.'
Assert-True -Condition (Test-CPanIpv4InRanges -Address '1.0.1.42' -Ranges $chinaRanges) -Message 'China IPv4 address should match its delegated APNIC range.'
Assert-False -Condition (Test-CPanIpv4InRanges -Address '1.0.16.1' -Ranges $chinaRanges) -Message 'Non-China IPv4 address must not match China ranges.'

$ruleAudit = Get-CPanFlClashRuleAudit -Rules @(
    'DOMAIN-SUFFIX,example.cn,Proxy',
    'GEOIP,CN,DIRECT',
    'DOMAIN-SUFFIX,example.cn,DIRECT',
    'MATCH,Proxy'
)
Assert-True -Condition ($ruleAudit.FirstChinaDirectIndex -eq 1) -Message 'FlClash rule audit should locate the first China direct rule.'
Assert-True -Condition ($ruleAudit.ProxyRulesBeforeChinaDirect -eq 1) -Message 'FlClash rule audit should count proxy rules that shadow China direct matching.'
Assert-True -Condition ($ruleAudit.ExactProxyDirectConflicts -eq 1) -Message 'FlClash rule audit should report exact domain targets assigned to both proxy and direct.'
Assert-False -Condition $ruleAudit.HasGeositeChinaDirectBeforeProxy -Message 'A later GEOIP rule must not be mistaken for an early GEOSITE China direct rule.'

$connectionFixture = @(
    [pscustomobject]@{ LocalAddress='198.18.0.1'; RemoteAddress='1.0.1.42'; State='Established'; OwningProcess=100; ProcessName='domestic-app' },
    [pscustomobject]@{ LocalAddress='198.18.0.1'; RemoteAddress='1.0.1.43'; State='Established'; OwningProcess=101; ProcessName='direct-app' },
    [pscustomobject]@{ LocalAddress='192.168.1.10'; RemoteAddress='1.0.1.43'; State='Established'; OwningProcess=900; ProcessName='FlClashCore' },
    [pscustomobject]@{ LocalAddress='198.18.0.1'; RemoteAddress='1.0.16.1'; State='Established'; OwningProcess=102; ProcessName='foreign-app' }
)
$suspectedFlows = @(Get-CPanFlClashSuspectedDomesticProxyFlows -Connections $connectionFixture -CoreProcessId 900 -Ranges $chinaRanges)
Assert-True -Condition ($suspectedFlows.Count -eq 1) -Message 'Only China app flows without a matching direct core connection should be flagged.'
Assert-True -Condition ($suspectedFlows[0].ProcessName -eq 'domestic-app') -Message 'Suspected proxy flow should retain its owning process name.'
Assert-True -Condition ($suspectedFlows[0].RemoteAddress -eq '1.0.1.42') -Message 'Suspected proxy flow should retain the China destination IP.'

$controllerSnapshot = [pscustomobject]@{
    connections = @(
        [pscustomobject]@{ metadata=[pscustomobject]@{ host='cdn.example.cn'; destinationIP='1.0.1.42'; process='large-app' }; chains=@('ProxyNode','Proxy'); download=73400320; upload=10485760; rule='DomainSuffix'; rulePayload='example.cn' },
        [pscustomobject]@{ metadata=[pscustomobject]@{ host='cdn.example.cn'; destinationIP='1.0.1.42'; process='large-app' }; chains=@('ProxyNode','Proxy'); download=31457280; upload=1048576; rule='DomainSuffix'; rulePayload='example.cn' },
        [pscustomobject]@{ metadata=[pscustomobject]@{ host='direct.example.cn'; destinationIP='1.0.1.43'; process='direct-app' }; chains=@('DIRECT'); download=524288000; upload=0; rule='GeoIP'; rulePayload='CN' },
        [pscustomobject]@{ metadata=[pscustomobject]@{ host='foreign.example'; destinationIP='1.0.16.1'; process='foreign-app' }; chains=@('ProxyNode','Proxy'); download=524288000; upload=0; rule='Match'; rulePayload='' }
    )
}
$controllerFindings = @(Get-CPanFlClashControllerTrafficFindings -Snapshot $controllerSnapshot -Ranges $chinaRanges -LargeTrafficBytes 100MB)
Assert-True -Condition ($controllerFindings.Count -eq 1) -Message 'Controller audit should keep only proxied China destinations and aggregate identical process/host connections.'
Assert-True -Condition ($controllerFindings[0].TotalBytes -eq 116391936) -Message 'Controller audit should sum upload and download bytes without recomputing the expected value.'
Assert-True -Condition $controllerFindings[0].IsLarge -Message 'Controller audit should flag aggregated traffic above the configured large-traffic threshold.'

$flClashFixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('CPanCleaner-FlClash-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $flClashFixtureRoot -Force | Out-Null
try {
    [pscustomobject]@{
        mode = 'rule'
        rule = @('DOMAIN-SUFFIX,example.cn,Proxy', 'GEOIP,CN,DIRECT', 'MATCH,Proxy')
        secret = ''
        'external-controller' = ''
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $flClashFixtureRoot 'config.json') -Encoding UTF8

    $routingAudit = @(Get-CPanFlClashRoutingAudit `
        -DataRoot $flClashFixtureRoot `
        -DelegatedLines $apnicFixture `
        -Connections $connectionFixture `
        -CoreProcessId 900)
    Assert-True -Condition (@($routingAudit | Where-Object Type -eq 'ProxyRoutingCandidate').Count -eq 1) -Message 'Integrated FlClash audit should expose suspected domestic proxy flows.'
    Assert-True -Condition (@($routingAudit | Where-Object { $_.Type -eq 'FlClashController' -and $_.Status -eq 'Disabled' }).Count -eq 1) -Message 'Integrated FlClash audit should explain that exact byte attribution needs the loopback controller.'
    Assert-True -Condition (@($routingAudit | Where-Object Type -eq 'ProxyRoutingAdvice').Count -gt 0) -Message 'Integrated FlClash audit should return a persistent override recommendation.'
} finally {
    Remove-Item -LiteralPath $flClashFixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
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
Assert-True -Condition ($performancePreventPreview.Version -eq '2.5.0') -Message 'Proxy-routing audit release should report version 2.5.0.'

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
$featureCatalogItems = if ($featureCatalog.Count -eq 1 -and $featureCatalog[0] -is [array]) { @($featureCatalog[0]) } else { @($featureCatalog) }
Assert-True -Condition ($featureCatalog.Count -gt 0) -Message 'GUI feature catalog should not be empty.'
foreach ($risk in @('Low', 'Medium', 'High')) {
    Assert-True -Condition (@($featureCatalog | Where-Object { $_.risk -eq $risk }).Count -gt 0) -Message "GUI should expose a $risk risk tab."
}
foreach ($id in @('aggressive-history', 'netlimiter-stats', 'disable-windows-update', 'restore-windows-update', 'optimize-performance', 'prevent-performance-spikes', 'performance-guard-task', 'windows-update-guard-task', 'repair-run-history', 'close-widgets', 'visual-studio-packages', 'storage-analysis', 'browser-offline-cache', 'qoder-cache', 'nuget-cache', 'nuget-migrate', 'nuget-remove-source', 'nuget-rollback', 'downloads-review', 'docker-migration-guide', 'wsl-migration-guide', 'visual-studio-migration-guide', 'proxy-routing-audit')) {
    Assert-True -Condition (@($featureCatalog | Where-Object { $_.id -eq $id }).Count -eq 1) -Message "GUI should expose restored historical feature $id exactly once."
}
foreach ($feature in $featureCatalog) {
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($feature.principle)) -Message "Feature $($feature.id) should explain its implementation principle."
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($feature.impact)) -Message "Feature $($feature.id) should explain its potential impact."
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($feature.safeguards)) -Message "Feature $($feature.id) should explain its safeguards."
}

$storageAnalysisFeature = $featureCatalogItems | Where-Object { $_.id -eq 'storage-analysis' } | Select-Object -First 1
Assert-True -Condition ($storageAnalysisFeature.supportsApply -eq $true) -Message 'Storage analysis should allow applying explicitly selected cleanup targets.'
Assert-True -Condition ($storageAnalysisFeature.selectableResults -eq $true) -Message 'Storage analysis should mark its safe cleanup results as selectable.'

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
Assert-True -Condition ($backendSource -match 'ProcessPriorityClass\.BelowNormal') -Message 'GUI backend scans should run at BelowNormal priority.'
Assert-True -Condition ($backendSource -match 'SelectedItemTokens') -Message 'GUI should pass only explicitly selected Downloads identity tokens.'

$mainWindowXaml = Get-Content -LiteralPath (Join-Path $root 'src\CPanCleaner.Gui\MainWindow.xaml') -Raw -Encoding UTF8
$mainWindowSource = Get-Content -LiteralPath (Join-Path $root 'src\CPanCleaner.Gui\MainWindow.xaml.cs') -Raw -Encoding UTF8
Assert-True -Condition ($mainWindowXaml -match 'x:Name="OpenResultLocationMenuItem"') -Message 'Result grid should expose an open-location context menu.'
Assert-True -Condition ($mainWindowXaml -match 'PreviewMouseRightButtonDown="ResultGrid_OnPreviewMouseRightButtonDown"') -Message 'Right-click should select the row under the pointer.'
Assert-True -Condition ($mainWindowSource -match 'Path\.IsPathFullyQualified') -Message 'Open-location should require a fully-qualified filesystem path.'
Assert-True -Condition ($mainWindowSource -match 'Directory\.Exists\(fullPath\)') -Message 'Open-location should verify directories exist.'
Assert-True -Condition ($mainWindowSource -match 'File\.Exists\(fullPath\)') -Message 'Open-location should verify files exist.'
Assert-True -Condition ($mainWindowSource -match 'ArgumentList\.Add\("/select,"\)') -Message 'Open-location should select an exact file when the result points to a file.'
Assert-True -Condition ($mainWindowXaml -match 'DataGridCheckBoxColumn Header="选择"') -Message 'Downloads review should expose per-file selection checkboxes.'
$resultTooltipColumnCount = [regex]::Matches($mainWindowXaml, '<DataGridTextColumn[^>]+ElementStyle="\{StaticResource ResultCellTextStyle\}"').Count
Assert-True -Condition ($resultTooltipColumnCount -eq 7) -Message 'Every text column in the result grid should expose its complete cell text through the shared tooltip style.'
Assert-True -Condition ($mainWindowXaml -match 'Text="\{Binding\}" TextWrapping="Wrap" MaxWidth="680"') -Message 'Long result tooltips should wrap within a bounded readable width.'
Assert-True -Condition ($mainWindowXaml -match 'ToolTipService\.ShowDuration" Value="60000"') -Message 'Result tooltips should remain visible long enough to read complete details.'
Assert-True -Condition ($mainWindowXaml -match 'ScrollViewer\.HorizontalScrollBarVisibility="Auto"') -Message 'The result grid should retain horizontal access when minimum column widths exceed the viewport.'

$browserTargets = @(Get-CPanCleanerTarget -Include BrowserCache)
foreach ($target in $browserTargets) {
    Assert-True -Condition ((Split-Path -Leaf $target.Path) -in @('Cache','Code Cache','GPUCache','DawnGraphiteCache','DawnWebGPUCache','GrShaderCache')) -Message "Browser target $($target.Id) must end in an exact basic-cache whitelist leaf."
    Assert-False -Condition ($target.Path -match '\\Extensions(?:\\|$)|\\IndexedDB(?:\\|$)|\\Local Storage(?:\\|$)') -Message "Browser target $($target.Id) must not include extensions or account/site data."
}
$browserOfflineTargets = @(Get-CPanCleanerTarget -Include BrowserOfflineCache)
Assert-False -Condition (@($browserOfflineTargets | Where-Object Default).Count -gt 0) -Message 'Service Worker offline cache must never be part of Default cleaning.'
Assert-False -Condition (@($browserOfflineTargets | Where-Object Risk -ne 'Medium').Count -gt 0) -Message 'Service Worker offline cache must remain medium risk.'
$exactPlaywrightTarget = @(Get-CPanCleanerTarget -Include 'Id:PlaywrightCache')
Assert-True -Condition ($exactPlaywrightTarget.Count -eq 1 -and $exactPlaywrightTarget[0].Id -eq 'PlaywrightCache') -Message 'An explicit Id selector must not expand to sibling targets when a target ID equals its category.'

$browserFixture = Join-Path $env:TEMP ('cpancleaner-browser-' + [guid]::NewGuid().ToString('N'))
$previousLocalAppData = $env:LOCALAPPDATA
$previousAppData = $env:APPDATA
$previousUserProfileForStorage = $env:USERPROFILE
try {
    $env:LOCALAPPDATA = $browserFixture
    $env:APPDATA = Join-Path $browserFixture 'Roaming'
    $env:USERPROFILE = Join-Path $browserFixture 'Profile'
    New-Item -ItemType Directory -Path (Join-Path $browserFixture 'Google\Chrome\User Data\Default\Cache') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $browserFixture 'Google\Chrome\User Data\Default\Service Worker\CacheStorage') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $browserFixture 'Google\Chrome\User Data\Profile 12\Code Cache') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $browserFixture 'Google\Chrome\User Data\Profile Bad\Cache') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $browserFixture 'Google\Chrome\User Data\Default\Extensions') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $env:LOCALAPPDATA 'ms-playwright') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $env:LOCALAPPDATA 'ms-playwright-go') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $env:LOCALAPPDATA 'NuGet\v3-cache') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $env:APPDATA 'Code\CachedExtensionVSIXs') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $env:USERPROFILE '.vscode\extensions\.11111111-1111-1111-1111-111111111111') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $env:USERPROFILE '.nuget\packages') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $browserFixture 'Google\Chrome\User Data\Default\Cache\basic.cache') -Value ('basic' * 4096) -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $browserFixture 'Google\Chrome\User Data\Default\Service Worker\CacheStorage\offline.cache') -Value ('offline' * 4096) -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $env:LOCALAPPDATA 'ms-playwright\browser.pkg') -Value ('playwright' * 4096) -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $env:LOCALAPPDATA 'ms-playwright-go\browser.pkg') -Value ('playwright-go' * 4096) -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $env:LOCALAPPDATA 'NuGet\v3-cache\cache.bin') -Value ('nuget-v3' * 4096) -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $env:APPDATA 'Code\CachedExtensionVSIXs\extension.vsix') -Value ('vsix' * 4096) -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $env:USERPROFILE '.vscode\extensions\.11111111-1111-1111-1111-111111111111\staging.bin') -Value ('staging' * 4096) -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $env:USERPROFILE '.nuget\packages\package.bin') -Value ('nuget-package' * 4096) -Encoding ASCII
    $discoveredBrowserTargets = @(Get-CPanBrowserCacheTargets)
    Assert-True -Condition ($discoveredBrowserTargets.Count -eq 3) -Message 'Browser discovery should include the two basic-cache fixtures and the separate offline-cache fixture only.'
    Assert-False -Condition (@($discoveredBrowserTargets | Where-Object { $_.Path -match 'Profile Bad|Extensions' }).Count -gt 0) -Message 'Browser discovery must reject arbitrary profile names and extension data.'

    $storageAnalysis = @(Get-CPanStorageAnalysis -AnalysisScope Profile -MaxScanItems 1000)
    $chromeAnalysis = @($storageAnalysis | Where-Object { $_.Id -eq 'ChromeData' })[0]
    Assert-True -Condition ($null -ne $chromeAnalysis.PSObject.Properties['CanSelect']) -Message 'Storage analysis results with cleanup mappings should expose CanSelect.'
    Assert-True -Condition ($chromeAnalysis.CanSelect -eq $true) -Message 'Chrome analysis should be selectable even when Chrome is currently blocking apply.'
    Assert-True -Condition ($null -ne $chromeAnalysis.PSObject.Properties['CleanupTargetIds']) -Message 'Storage analysis should expose exact cleanup target IDs.'
    Assert-True -Condition ($chromeAnalysis.CleanupTargetIds -contains 'ChromeDefaultCache') -Message 'Chrome analysis should map to its exact basic-cache target.'
    Assert-False -Condition ($chromeAnalysis.CleanupTargetIds -contains 'ChromeDefaultOfflineCacheStorage') -Message 'Low-risk Chrome analysis must not silently include medium-risk Service Worker cache.'
    $selectedChromeTargets = @(Get-CPanCleanerTarget -Include @($chromeAnalysis.CleanupTargetIds | ForEach-Object { "Id:$_" }))
    Assert-True -Condition ($selectedChromeTargets.Count -gt 0) -Message 'Storage analysis cleanup IDs should resolve through the fixed target allowlist.'
    Assert-False -Condition (@($selectedChromeTargets | Where-Object { $_.Category -ne 'BrowserCache' }).Count -gt 0) -Message 'Chrome analysis selection should resolve only to basic browser-cache targets.'
    foreach ($analysisItem in @($storageAnalysis | Where-Object { $_.CleanupTargetIds.Count -gt 0 })) {
        $analysisRoot = [System.IO.Path]::GetFullPath($analysisItem.Path).TrimEnd('\')
        foreach ($mappedTarget in @(Get-CPanCleanerTarget -Include @($analysisItem.CleanupTargetIds | ForEach-Object { "Id:$_" }))) {
            $mappedPath = [System.IO.Path]::GetFullPath($mappedTarget.Path).TrimEnd('\')
            $isWithinAnalysisRoot = $mappedPath -eq $analysisRoot -or $mappedPath.StartsWith($analysisRoot + '\', [StringComparison]::OrdinalIgnoreCase)
            Assert-True -Condition $isWithinAnalysisRoot -Message "Storage analysis item $($analysisItem.Id) must not clean sibling path $mappedPath outside displayed root $analysisRoot."
        }
    }
} finally {
    $env:LOCALAPPDATA = $previousLocalAppData
    $env:APPDATA = $previousAppData
    $env:USERPROFILE = $previousUserProfileForStorage
    if (Test-Path -LiteralPath $browserFixture) { Remove-Item -LiteralPath $browserFixture -Recurse -Force }
}

$qoderTargets = @(Get-CPanCleanerTarget -Include QoderCache)
Assert-True -Condition ($qoderTargets.Count -eq 2) -Message 'Qoder cleanup must expose exactly index and cache targets.'
Assert-False -Condition (@($qoderTargets | Where-Object { $_.Path -notmatch '\\SharedClientCache\\(index|cache)$' }).Count -gt 0) -Message 'Qoder cleanup must stay inside SharedClientCache index/cache leaves.'
Assert-True -Condition (@(Get-CPanProcessBlockers -ProcessNames @('powershell')).Count -gt 0) -Message 'Process-blocker discovery should identify the current PowerShell test process.'

$vsCodeTargets = @(Get-CPanCleanerTarget -Include VSCodeCache)
Assert-False -Condition (@($vsCodeTargets | Where-Object { $_.Path -match '\\extensions\\' -and $_.Path -notmatch '(\\\.[0-9a-fA-F-]{36}$|\.vsctmp$)' }).Count -gt 0) -Message 'VS Code extension cleanup must only include UUID staging or .vsctmp directories.'
Assert-False -Condition (@($vsCodeTargets | Where-Object { $_.Path -match '\\extensions\\.*\\|\\extensions\\\.obsolete$' }).Count -gt 0) -Message 'VS Code cleanup must not include current extension directories or .obsolete metadata.'
Assert-False -Condition ($moduleSource -match 'Close VS Code first|Dry-run only\. Pass -Apply') -Message 'VS Code and dry-run guidance shown in the Chinese GUI should not fall back to unexplained English text.'
Assert-True -Condition ($moduleSource -match '当前仅为预览，尚未删除任何内容') -Message 'Dry-run results should explicitly explain that preview has not deleted anything.'

$localizedCsv = @(ConvertFrom-CPanDiskUsageCsv -Lines @('SizeOnDisk,FileSize,Files,目录路径','4096,2048,3,C:\临时目录'))
Assert-True -Condition ($localizedCsv.Count -eq 1 -and $localizedCsv[0].SizeOnDiskBytes -eq 4096 -and $localizedCsv[0].Path -eq 'C:\临时目录') -Message 'diskusage CSV parsing must ignore localized headers and preserve localized paths.'

$downloadFixture = Join-Path (Join-Path $env:LOCALAPPDATA 'Temp') ('cpancleaner-downloads-' + [guid]::NewGuid().ToString('N'))
$previousUserProfile = $env:USERPROFILE
try {
    $env:USERPROFILE = $downloadFixture
    $downloadsFixture = Join-Path $downloadFixture 'Downloads'
    $nestedFixture = Join-Path $downloadsFixture 'nested'
    New-Item -ItemType Directory -Path $nestedFixture -Force | Out-Null
    $directFile = Join-Path $downloadsFixture 'review.zip'
    Set-Content -LiteralPath $directFile -Value 'before' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $nestedFixture 'must-not-list.zip') -Value 'nested' -Encoding ASCII
    $downloadLog = Join-Path $downloadFixture 'review.log'
    New-Item -ItemType File -Path $downloadLog -Force | Out-Null
    $downloadContext = [pscustomobject]@{ LogPath=$downloadLog; Quiet=$true }
    $downloadPreview = @(Invoke-CPanDownloadReview -Context $downloadContext)
    Assert-True -Condition ($downloadPreview.Count -eq 1 -and $downloadPreview[0].Path -eq $directFile) -Message ("Downloads review must list direct allowlisted files only. Count={0}; Paths={1}; Expected={2}" -f $downloadPreview.Count, (($downloadPreview | ForEach-Object Path) -join '|'), $directFile)
    Add-Content -LiteralPath $directFile -Value 'changed' -Encoding ASCII
    $changedApply = @(Invoke-CPanDownloadReview -Context $downloadContext -SelectedItemTokens @($downloadPreview[0].IdentityToken) -Apply)
    Assert-True -Condition ($changedApply.Count -eq 1 -and $changedApply[0].Status -eq 'ChangedSkipped' -and (Test-Path -LiteralPath $directFile)) -Message 'Downloads apply must skip a file whose size or timestamp changed after preview.'
} finally {
    $env:USERPROFILE = $previousUserProfile
    if (Test-Path -LiteralPath $downloadFixture) { Remove-Item -LiteralPath $downloadFixture -Recurse -Force }
}

$reparseTestRoot = Join-Path $env:TEMP ('cpancleaner-reparse-' + [guid]::NewGuid().ToString('N'))
$reparseTarget = Join-Path $reparseTestRoot 'target'
$reparseLink = Join-Path $reparseTestRoot 'link'
try {
    New-Item -ItemType Directory -Path $reparseTarget -Force | Out-Null
    New-Item -ItemType Junction -Path $reparseLink -Target $reparseTarget | Out-Null
    $reparseMeasurement = Measure-CPanPathSizeOnDisk -Path $reparseLink
    Assert-True -Condition ($reparseMeasurement.Method -eq 'ReparsePointRejected') -Message 'Storage analysis must reject reparse-point roots.'
} finally {
    if (Test-Path -LiteralPath $reparseLink) { Remove-Item -LiteralPath $reparseLink -Force }
    if (Test-Path -LiteralPath $reparseTarget) { Remove-Item -LiteralPath $reparseTarget -Force }
    if (Test-Path -LiteralPath $reparseTestRoot) { Remove-Item -LiteralPath $reparseTestRoot -Force }
}

$nugetDestinationRejected = $false
try { Test-CPanNuGetMigrationDestination -DestinationPath $env:TEMP | Out-Null } catch { $nugetDestinationRejected = $true }
Assert-True -Condition $nugetDestinationRejected -Message 'NuGet migration must reject a C-drive or non-empty destination.'
Assert-True -Condition ($moduleSource -match 'dotnet nuget locals \$nugetCacheName --clear') -Message 'NuGet cleanup must call the official dotnet nuget locals command.'
Assert-True -Condition ($moduleSource -match 'LastWriteTimeUtcTicks') -Message 'Downloads apply must validate file modification identity.'
Assert-True -Condition ($moduleSource -match 'GetExtension' -and $moduleSource -match [regex]::Escape("@('.exe','.msi','.zip','.crdownload')")) -Message 'Downloads deletion must enforce the exact extension whitelist.'
Assert-True -Condition ($moduleSource -match [regex]::Escape("[Environment]::SetEnvironmentVariable('NUGET_PACKAGES',`$previousUserValue,'User')")) -Message 'NuGet prepare failures must restore the previous user-level package path.'
Assert-True -Condition ($moduleSource -match "MigrationOperation -eq 'Rollback'") -Message 'NuGet migration must expose an explicit rollback branch.'
Assert-True -Condition ($moduleSource -match '\.cpancleaner-staging-' -and $moduleSource -match 'Move-Item -LiteralPath \$stagingPath -Destination \$validated\.Path') -Message 'NuGet migration must verify a same-volume staging copy before committing the destination.'

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
