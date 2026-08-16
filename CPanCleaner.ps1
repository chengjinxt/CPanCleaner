[CmdletBinding()]
param(
    [ValidateSet('Scan', 'Clean', 'OptimizePerformance', 'CloseWidgets')]
    [string] $Action = 'Scan',

    [switch] $Apply,
    [switch] $DryRun,
    [switch] $Elevate,

    [ValidateRange(0, 3650)]
    [int] $MinimumAgeDays = 1,

    [ValidateRange(1000, 1000000)]
    [int] $MaxScanItems = 100000,

    [string] $LogDirectory,
    [switch] $Json
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:CleanerVersion = '1.0.0'
$script:LogPath = $null

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function ConvertTo-FullPath {
    param([Parameter(Mandatory = $true)][string] $Path)

    try {
        $full = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Path))
        if ($full.Length -gt 3) {
            $full = $full.TrimEnd('\')
        }
        return $full
    } catch {
        return $null
    }
}

function Get-DriveSnapshot {
    $drive = [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.Name -eq 'C:\' } | Select-Object -First 1
    if (-not $drive) {
        return $null
    }

    return [pscustomobject]@{
        TotalGB = [math]::Round($drive.TotalSize / 1GB, 2)
        FreeGB = [math]::Round($drive.AvailableFreeSpace / 1GB, 2)
        FreePct = [math]::Round(($drive.AvailableFreeSpace / $drive.TotalSize) * 100, 1)
    }
}

function Initialize-Log {
    param([string] $PreferredDirectory)

    $directories = @()
    if ($PreferredDirectory) {
        $directories += $PreferredDirectory
    } else {
        $directories += (Join-Path $PSScriptRoot 'logs')
    }
    $directories += (Join-Path $env:TEMP 'CPanCleaner\logs')

    foreach ($directory in $directories | Select-Object -Unique) {
        try {
            New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop | Out-Null
            $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            $path = Join-Path $directory "cpancleaner-$stamp.log"
            New-Item -ItemType File -Path $path -Force -ErrorAction Stop | Out-Null
            $script:LogPath = $path
            return
        } catch {
        }
    }
}

function Write-SafeLog {
    param(
        [ValidateSet('INFO', 'WARN', 'ERROR')][string] $Level,
        [Parameter(Mandatory = $true)][string] $Message
    )

    if (-not $script:LogPath) {
        return
    }

    try {
        $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
        [System.IO.File]::AppendAllText($script:LogPath, $line + [Environment]::NewLine)
    } catch {
        $script:LogPath = $null
    }
}

function New-SafeTarget {
    param(
        [Parameter(Mandatory = $true)][string] $Id,
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][string] $Path,
        [bool] $UseAgeFilter = $false,
        [bool] $RequiresAdmin = $false,
        [bool] $DeleteSelf = $false,
        [string] $AllowedRoot = $Path
    )

    return [pscustomobject]@{
        Id = $Id
        Name = $Name
        Path = ConvertTo-FullPath $Path
        AllowedRoot = ConvertTo-FullPath $AllowedRoot
        UseAgeFilter = $UseAgeFilter
        RequiresAdmin = $RequiresAdmin
        DeleteSelf = $DeleteSelf
    }
}

function Get-SafeTargets {
    $targets = @()
    $systemDrive = if ($env:SystemDrive) { $env:SystemDrive.TrimEnd('\') } else { 'C:' }
    $userTemp = [System.IO.Path]::GetTempPath()

    if ($userTemp) {
        $targets += New-SafeTarget -Id 'UserTemp' -Name 'Current user temporary files' -Path $userTemp -UseAgeFilter $true
    }

    $targets += New-SafeTarget -Id 'WindowsTemp' -Name 'Windows temporary files' -Path "$systemDrive\Windows\Temp" -UseAgeFilter $true -RequiresAdmin $true
    $targets += New-SafeTarget -Id 'WindowsErrorReporting' -Name 'Windows Error Reporting cache' -Path "$systemDrive\ProgramData\Microsoft\Windows\WER" -UseAgeFilter $true -RequiresAdmin $true
    $targets += New-SafeTarget -Id 'DebugSymbolCache' -Name 'Downloaded debug symbol cache' -Path "$systemDrive\ProgramData\Dbg\sym" -RequiresAdmin $true
    $targets += New-SafeTarget -Id 'WindowsMinidump' -Name 'Windows minidump files' -Path "$systemDrive\Windows\Minidump" -UseAgeFilter $true -RequiresAdmin $true

    if ($env:LOCALAPPDATA) {
        $localTargets = @(
            @{ Id = 'InternetCache'; Name = 'Windows Internet cache'; Relative = 'Microsoft\Windows\INetCache'; Age = $false },
            @{ Id = 'UserCrashDumps'; Name = 'Current user crash dumps'; Relative = 'CrashDumps'; Age = $true },
            @{ Id = 'D3DSCache'; Name = 'Direct3D shader cache'; Relative = 'D3DSCache'; Age = $false },
            @{ Id = 'EdgeCache'; Name = 'Microsoft Edge web cache'; Relative = 'Microsoft\Edge\User Data\Default\Cache'; Age = $false },
            @{ Id = 'EdgeCodeCache'; Name = 'Microsoft Edge code cache'; Relative = 'Microsoft\Edge\User Data\Default\Code Cache'; Age = $false },
            @{ Id = 'ChromeCache'; Name = 'Google Chrome web cache'; Relative = 'Google\Chrome\User Data\Default\Cache'; Age = $false },
            @{ Id = 'ChromeCodeCache'; Name = 'Google Chrome code cache'; Relative = 'Google\Chrome\User Data\Default\Code Cache'; Age = $false },
            @{ Id = 'NvidiaDxCache'; Name = 'NVIDIA DirectX shader cache'; Relative = 'NVIDIA\DXCache'; Age = $false },
            @{ Id = 'NvidiaGlCache'; Name = 'NVIDIA OpenGL shader cache'; Relative = 'NVIDIA\GLCache'; Age = $false },
            @{ Id = 'AmdDxCache'; Name = 'AMD DirectX shader cache'; Relative = 'AMD\DxCache'; Age = $false },
            @{ Id = 'RemoteDesktopCache'; Name = 'Remote Desktop bitmap cache'; Relative = 'Microsoft\Terminal Server Client\Cache'; Age = $false }
        )

        foreach ($definition in $localTargets) {
            $targets += New-SafeTarget -Id $definition.Id -Name $definition.Name -Path (Join-Path $env:LOCALAPPDATA $definition.Relative) -UseAgeFilter ([bool] $definition.Age)
        }

    }

    if ($env:USERPROFILE) {
        $runtimeRoot = Join-Path $env:USERPROFILE '.cache\codex-runtimes'
        try {
            if (Test-Path -LiteralPath $runtimeRoot -ErrorAction Stop) {
                foreach ($runtime in Get-ChildItem -LiteralPath $runtimeRoot -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'codex-primary-runtime.previous-*' }) {
                    $targets += New-SafeTarget -Id ('CodexPreviousRuntime:' + $runtime.Name) -Name ('Old Codex runtime: ' + $runtime.Name) -Path $runtime.FullName -DeleteSelf $true -AllowedRoot $runtimeRoot
                }
            }
        } catch {
        }
    }

    return @($targets | Where-Object { $_.Path -and $_.AllowedRoot })
}

function Test-SafeDeletionPath {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $AllowedRoot
    )

    $fullPath = ConvertTo-FullPath $Path
    $rootPath = ConvertTo-FullPath $AllowedRoot
    if (-not $fullPath -or -not $rootPath) {
        return $false
    }

    $comparison = [StringComparison]::OrdinalIgnoreCase
    $rootWithSlash = if ($rootPath.EndsWith('\')) { $rootPath } else { "$rootPath\" }
    if ([string]::Equals($fullPath, $rootPath, $comparison) -or -not $fullPath.StartsWith($rootWithSlash, $comparison)) {
        return $false
    }

    $protected = @(
        'C:\',
        'C:\Windows',
        'C:\Windows\System32',
        'C:\Windows\SysWOW64',
        'C:\Windows\WinSxS',
        'C:\Windows\servicing',
        'C:\Program Files',
        'C:\Program Files (x86)',
        $env:USERPROFILE,
        (Join-Path $env:USERPROFILE 'Desktop'),
        (Join-Path $env:USERPROFILE 'Documents'),
        (Join-Path $env:USERPROFILE 'Downloads'),
        (Join-Path $env:USERPROFILE 'Pictures'),
        (Join-Path $env:USERPROFILE 'Music'),
        (Join-Path $env:USERPROFILE 'Videos')
    ) | Where-Object { $_ } | ForEach-Object { ConvertTo-FullPath $_ }

    foreach ($item in $protected) {
        if ([string]::Equals($fullPath, $item, $comparison)) {
            return $false
        }
    }

    return $true
}

function Get-TargetCandidates {
    param(
        [Parameter(Mandatory = $true)][pscustomobject] $Target,
        [int] $AgeDays
    )

    try {
        if (-not (Test-Path -LiteralPath $Target.Path -ErrorAction Stop)) {
            return @()
        }
    } catch {
        return @()
    }

    if ($Target.DeleteSelf) {
        $item = Get-Item -LiteralPath $Target.Path -Force -ErrorAction SilentlyContinue
        if ($item) {
            return @($item)
        }
        return @()
    }

    $items = @(Get-ChildItem -LiteralPath $Target.Path -Force -ErrorAction SilentlyContinue)
    if ($Target.UseAgeFilter) {
        $cutoff = (Get-Date).AddDays(-1 * $AgeDays)
        $agedItems = @()
        foreach ($item in $items) {
            if ($item.LastWriteTime -gt $cutoff) {
                continue
            }

            if ($item -is [System.IO.DirectoryInfo]) {
                try {
                    $recentChild = Get-ChildItem -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop |
                        Where-Object { $_.LastWriteTime -gt $cutoff } |
                        Select-Object -First 1
                    if ($recentChild) {
                        continue
                    }
                } catch {
                    continue
                }
            }

            $agedItems += $item
        }
        $items = $agedItems
    }

    return @($items | Where-Object { -not ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) })
}

function Measure-ItemSafe {
    param(
        [Parameter(Mandatory = $true)][System.IO.FileSystemInfo] $Item,
        [int] $Limit
    )

    if ($Item -is [System.IO.FileInfo]) {
        return [pscustomobject]@{ Bytes = [int64] $Item.Length; Files = 1; Truncated = $false }
    }

    $bytes = [int64] 0
    $files = 0
    $truncated = $false
    foreach ($child in Get-ChildItem -LiteralPath $Item.FullName -Recurse -Force -File -ErrorAction SilentlyContinue) {
        $bytes += [int64] $child.Length
        $files++
        if ($files -ge $Limit) {
            $truncated = $true
            break
        }
    }
    return [pscustomobject]@{ Bytes = $bytes; Files = $files; Truncated = $truncated }
}

function Invoke-SafeTarget {
    param(
        [Parameter(Mandatory = $true)][pscustomobject] $Target,
        [bool] $DoApply,
        [bool] $IsAdmin,
        [int] $AgeDays,
        [int] $Limit,
        [bool] $ReadOnly
    )

    try {
        $exists = Test-Path -LiteralPath $Target.Path -ErrorAction Stop
    } catch {
        return [pscustomobject]@{ Id=$Target.Id; Name=$Target.Name; Status='AccessDenied'; EstimatedMB=0; RemovedMB=0; Candidates=0; Path=$Target.Path; Message=$_.Exception.Message }
    }

    if (-not $exists) {
        return [pscustomobject]@{ Id=$Target.Id; Name=$Target.Name; Status='NotFound'; EstimatedMB=0; RemovedMB=0; Candidates=0; Path=$Target.Path; Message='' }
    }

    if ($Target.RequiresAdmin -and -not $IsAdmin) {
        $status = 'NeedsAdministrator'
    } elseif ($DoApply) {
        $status = 'Cleaned'
    } elseif ($ReadOnly) {
        $status = 'Scanned'
    } else {
        $status = 'WouldClean'
    }

    $candidateItems = @(Get-TargetCandidates -Target $Target -AgeDays $AgeDays)
    $estimatedBytes = [int64] 0
    $removedBytes = [int64] 0
    $errors = @()
    $scanned = 0
    $truncated = $false

    foreach ($candidate in $candidateItems) {
        if ($scanned -ge $Limit) {
            $truncated = $true
            break
        }

        if (-not (Test-SafeDeletionPath -Path $candidate.FullName -AllowedRoot $Target.AllowedRoot)) {
            $errors += "Safety check rejected $($candidate.FullName)"
            continue
        }

        $remainingLimit = [math]::Max(1, $Limit - $scanned)
        $measurement = Measure-ItemSafe -Item $candidate -Limit $remainingLimit
        $estimatedBytes += $measurement.Bytes
        $scanned += $measurement.Files
        if ($measurement.Truncated -or $scanned -ge $Limit) {
            $truncated = $true
        }

        if ($DoApply -and (-not $Target.RequiresAdmin -or $IsAdmin)) {
            try {
                Remove-Item -LiteralPath $candidate.FullName -Recurse -Force -ErrorAction Stop
                $removedBytes += $measurement.Bytes
            } catch {
                $errors += $_.Exception.Message
            }
        }
    }

    if ($Target.RequiresAdmin -and -not $IsAdmin) {
        $status = 'NeedsAdministrator'
    } elseif ($errors.Count -gt 0) {
        if ($DoApply) {
            $status = 'Partial'
        } elseif ($ReadOnly) {
            $status = 'ScannedWithWarnings'
        } else {
            $status = 'WouldCleanWithWarnings'
        }
    }

    $messageParts = @()
    if ($truncated) {
        $messageParts += "Size scan stopped at $Limit files."
    }
    if ($errors.Count -gt 0) {
        $messageParts += (($errors | Select-Object -First 3) -join ' | ')
    }

    $result = [pscustomobject]@{
        Id = $Target.Id
        Name = $Target.Name
        Status = $status
        EstimatedMB = [math]::Round($estimatedBytes / 1MB, 2)
        RemovedMB = [math]::Round($removedBytes / 1MB, 2)
        Candidates = $candidateItems.Count
        Path = $Target.Path
        Message = ($messageParts -join ' ')
    }

    Write-SafeLog -Level 'INFO' -Message ("{0}: status={1}; estimatedMB={2}; removedMB={3}; candidates={4}; path={5}" -f $result.Id,$result.Status,$result.EstimatedMB,$result.RemovedMB,$result.Candidates,$result.Path)
    return $result
}

function Invoke-SafePerformanceOptimization {
    param([bool] $DoApply)

    $records = @()
    if ($DoApply) {
        try {
            Clear-DnsClientCache -ErrorAction Stop
            $records += [pscustomobject]@{ Action='FlushDns'; Status='Completed'; Detail='' }
        } catch {
            $records += [pscustomobject]@{ Action='FlushDns'; Status='Warning'; Detail=$_.Exception.Message }
        }
    } else {
        $records += [pscustomobject]@{ Action='FlushDns'; Status='WouldRun'; Detail='' }
    }

    $priorityNames = @(
        'NLSvc','FlClash','FlClashCore','SDPProxyClient','CmicSDPAccessAgent','CmicSDPAccessAgentDaemon',
        'CmicSDPAccessAgentTray','Lenovo.Modern.ImController','UsbClientService','vss-service-x64','vmware-authd',
        'SmpHelp','MSPCManager','MSPCManagerService','NTFSWatcher','NutstoreDriverSvc','AweSun','awesun_guard',
        'wpscloudsvr','TGitCache'
    )

    foreach ($name in $priorityNames) {
        foreach ($process in Get-Process -Name $name -ErrorAction SilentlyContinue) {
            $status = if ($DoApply) { 'BelowNormal' } else { 'WouldSetBelowNormal' }
            if ($DoApply) {
                try {
                    $process.PriorityClass = 'BelowNormal'
                } catch {
                    $status = 'Warning'
                }
            }
            $records += [pscustomobject]@{ Action='SetPriority'; Status=$status; Detail=("{0} PID={1}" -f $process.ProcessName,$process.Id) }
        }
    }

    return $records
}

function Invoke-CloseWindowsWidgets {
    param([bool] $DoApply)

    $records = @()
    $widgets = @(Get-Process -Name 'Widgets','WidgetService' -ErrorAction SilentlyContinue)
    if ($widgets.Count -eq 0) {
        return @([pscustomobject]@{ Action='CloseWidgets'; Status='NotRunning'; Detail='' })
    }

    foreach ($process in $widgets) {
        $status = if ($DoApply) { 'Closed' } else { 'WouldClose' }
        if ($DoApply) {
            try {
                Stop-Process -Id $process.Id -Force -ErrorAction Stop
            } catch {
                $status = 'Warning'
            }
        }
        $records += [pscustomobject]@{ Action='CloseWidgets'; Status=$status; Detail=("{0} PID={1}" -f $process.ProcessName,$process.Id) }
    }

    return $records
}

if ($Elevate -and -not (Test-Administrator)) {
    $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $PSCommandPath),'-Action',$Action,'-MinimumAgeDays',$MinimumAgeDays,'-MaxScanItems',$MaxScanItems)
    if ($Apply) { $arguments += '-Apply' }
    if ($DryRun) { $arguments += '-DryRun' }
    if ($LogDirectory) { $arguments += @('-LogDirectory',('"{0}"' -f $LogDirectory)) }
    Write-Host 'Requesting Administrator approval through UAC...'
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $arguments -Wait | Out-Null
    return
}

Initialize-Log -PreferredDirectory $LogDirectory
$before = Get-DriveSnapshot
$isAdmin = Test-Administrator
$effectiveApply = [bool] ($Apply -and -not $DryRun)
$items = @()
$diagnostics = @()

if ($Action -eq 'OptimizePerformance') {
    $diagnostics = @(Invoke-SafePerformanceOptimization -DoApply $effectiveApply)
} elseif ($Action -eq 'CloseWidgets') {
    $diagnostics = @(Invoke-CloseWindowsWidgets -DoApply $effectiveApply)
} else {
    foreach ($target in Get-SafeTargets) {
        $items += Invoke-SafeTarget -Target $target -DoApply ($Action -eq 'Clean' -and $effectiveApply) -IsAdmin $isAdmin -AgeDays $MinimumAgeDays -Limit $MaxScanItems -ReadOnly ($Action -eq 'Scan')
    }
}

$after = Get-DriveSnapshot
$summary = [pscustomobject]@{
    Version = $script:CleanerVersion
    Action = $Action
    Mode = if ($Action -eq 'Scan') { 'ReadOnly' } elseif ($effectiveApply) { 'Apply' } else { 'DryRun' }
    IsAdministrator = $isAdmin
    MinimumAgeDays = $MinimumAgeDays
    FreeGBBefore = if ($before) { $before.FreeGB } else { $null }
    FreeGBAfter = if ($after) { $after.FreeGB } else { $null }
    FreedGB = if ($before -and $after) { [math]::Round($after.FreeGB - $before.FreeGB, 2) } else { $null }
    LogPath = $script:LogPath
    Items = @($items)
    Diagnostics = @($diagnostics)
}

Write-SafeLog -Level 'INFO' -Message ("Completed action={0}; mode={1}; freeBeforeGB={2}; freeAfterGB={3}" -f $summary.Action,$summary.Mode,$summary.FreeGBBefore,$summary.FreeGBAfter)

if ($Json) {
    $summary | ConvertTo-Json -Depth 8
    return
}

Write-Host ''
Write-Host ('CPanCleaner {0} | Action: {1} | Mode: {2} | Admin: {3}' -f $summary.Version,$summary.Action,$summary.Mode,$summary.IsAdministrator)
Write-Host ('C drive free: {0} GB -> {1} GB | Freed: {2} GB' -f $summary.FreeGBBefore,$summary.FreeGBAfter,$summary.FreedGB)
if ($summary.LogPath) { Write-Host ('Log: {0}' -f $summary.LogPath) }
Write-Host ''

if ($summary.Items.Count -gt 0) {
    $summary.Items | Where-Object { $_.Status -ne 'NotFound' -or $_.EstimatedMB -gt 0 } | Select-Object Id,Status,EstimatedMB,RemovedMB,Candidates,Path,Message | Format-Table -AutoSize
}
if ($summary.Diagnostics.Count -gt 0) {
    $summary.Diagnostics | Format-Table -AutoSize
}

if ($Action -eq 'Clean' -and -not $effectiveApply) {
    Write-Host ''
    Write-Host 'Dry-run complete. Re-run with -Apply to remove only the listed low-risk cache candidates.'
}
if ($Action -eq 'OptimizePerformance' -and -not $effectiveApply) {
    Write-Host ''
    Write-Host 'Dry-run complete. Re-run with -Apply to flush DNS and temporarily lower known background helper priorities.'
}
if ($Action -eq 'CloseWidgets' -and -not $effectiveApply) {
    Write-Host ''
    Write-Host 'Dry-run complete. Re-run with -Apply to close only the current Windows Widgets processes.'
}
