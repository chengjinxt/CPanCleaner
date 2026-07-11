Set-StrictMode -Version 2.0

$script:CleanerVersion = '0.4.0'

function Get-CPanSystemDrive {
    $drive = $env:SystemDrive
    if ([string]::IsNullOrWhiteSpace($drive)) {
        return 'C:'
    }
    return $drive.TrimEnd('\')
}

function ConvertTo-CPanFullPath {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    try {
        $expanded = [Environment]::ExpandEnvironmentVariables($Path)
        $full = [System.IO.Path]::GetFullPath($expanded)
        if ($full.Length -gt 3) {
            $full = $full.TrimEnd('\')
        }
        return $full
    } catch {
        return $null
    }
}

function Test-CPanAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-CPanProtectedPathRules {
    $systemDrive = Get-CPanSystemDrive
    $userProfile = ConvertTo-CPanFullPath $env:USERPROFILE

    $rules = @(
        [pscustomobject]@{ Path = "$systemDrive\"; Recursive = $false },
        [pscustomobject]@{ Path = "$systemDrive\Windows"; Recursive = $false },
        [pscustomobject]@{ Path = "$systemDrive\Windows\System32"; Recursive = $true },
        [pscustomobject]@{ Path = "$systemDrive\Windows\SysWOW64"; Recursive = $true },
        [pscustomobject]@{ Path = "$systemDrive\Windows\WinSxS"; Recursive = $true },
        [pscustomobject]@{ Path = "$systemDrive\Windows\servicing"; Recursive = $true },
        [pscustomobject]@{ Path = "$systemDrive\Windows\servicing\Packages"; Recursive = $true },
        [pscustomobject]@{ Path = "$systemDrive\Program Files"; Recursive = $true },
        [pscustomobject]@{ Path = "${systemDrive}\Program Files (x86)"; Recursive = $true },
        [pscustomobject]@{ Path = "$systemDrive\ProgramData\Microsoft\Windows Defender"; Recursive = $true }
    )

    if ($userProfile) {
        $rules += @(
            [pscustomobject]@{ Path = $userProfile; Recursive = $false },
            [pscustomobject]@{ Path = (Join-Path $userProfile 'Desktop'); Recursive = $true },
            [pscustomobject]@{ Path = (Join-Path $userProfile 'Documents'); Recursive = $true },
            [pscustomobject]@{ Path = (Join-Path $userProfile 'Downloads'); Recursive = $true },
            [pscustomobject]@{ Path = (Join-Path $userProfile 'Pictures'); Recursive = $true },
            [pscustomobject]@{ Path = (Join-Path $userProfile 'Music'); Recursive = $true },
            [pscustomobject]@{ Path = (Join-Path $userProfile 'Videos'); Recursive = $true }
        )
    }

    return $rules | ForEach-Object {
        $full = ConvertTo-CPanFullPath $_.Path
        if ($full) {
            [pscustomobject]@{ Path = $full; Recursive = [bool] $_.Recursive }
        }
    }
}

function Test-CPanPathSafety {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [string] $AllowedRoot,

        [switch] $AllowRootItself
    )

    $fullPath = ConvertTo-CPanFullPath $Path
    $rootPath = ConvertTo-CPanFullPath $AllowedRoot
    if (-not $fullPath -or -not $rootPath) {
        return $false
    }

    $comparison = [StringComparison]::OrdinalIgnoreCase
    $rootWithSlash = if ($rootPath.EndsWith('\')) { $rootPath } else { "$rootPath\" }

    if ($AllowRootItself) {
        if ([string]::Equals($fullPath, $rootPath, $comparison)) {
            return $true
        }
    } elseif ([string]::Equals($fullPath, $rootPath, $comparison)) {
        return $false
    }

    if (-not $fullPath.StartsWith($rootWithSlash, $comparison)) {
        return $false
    }

    foreach ($rule in Get-CPanProtectedPathRules) {
        $protected = $rule.Path
        $protectedWithSlash = if ($protected.EndsWith('\')) { $protected } else { "$protected\" }
        if ([string]::Equals($fullPath, $protected, $comparison)) {
            return $false
        }

        if ($rule.Recursive -and $fullPath.StartsWith($protectedWithSlash, $comparison)) {
            return $false
        }
    }

    return $true
}

function New-CPanRunContext {
    param(
        [string] $LogDirectory,
        [switch] $Quiet
    )

    if ([string]::IsNullOrWhiteSpace($LogDirectory)) {
        $moduleRoot = Split-Path -Parent $PSScriptRoot
        $LogDirectory = Join-Path $moduleRoot 'logs'
    }

    New-Item -ItemType Directory -Force -Path $LogDirectory | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $suffix = ([guid]::NewGuid().ToString('N')).Substring(0, 8)
    $logPath = Join-Path $LogDirectory "cpancleaner-$stamp-$suffix.log"
    New-Item -ItemType File -Force -Path $logPath | Out-Null

    return [pscustomobject]@{
        LogPath = $logPath
        Quiet = [bool] $Quiet
    }
}

function Write-CPanLog {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Context,

        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string] $Level = 'INFO',

        [Parameter(Mandatory = $true)]
        [string] $Message
    )

    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -LiteralPath $Context.LogPath -Value $line
    if (-not $Context.Quiet) {
        Write-Verbose $line
    }
}

function New-CPanTarget {
    param(
        [Parameter(Mandatory = $true)] [string] $Id,
        [Parameter(Mandatory = $true)] [string] $Name,
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [string] $Kind,
        [ValidateSet('Low', 'Medium', 'High')] [string] $Risk = 'Low',
        [string] $Category = 'Default',
        [bool] $Default = $false,
        [bool] $RequiresAdmin = $false,
        [bool] $UseAgeFilter = $true,
        [string] $Description = ''
    )

    return [pscustomobject]@{
        Id = $Id
        Name = $Name
        Path = ConvertTo-CPanFullPath $Path
        Kind = $Kind
        Risk = $Risk
        Category = $Category
        Default = $Default
        RequiresAdmin = $RequiresAdmin
        UseAgeFilter = $UseAgeFilter
        Description = $Description
    }
}

function Get-CPanStaticTargets {
    $systemDrive = Get-CPanSystemDrive
    $userTemp = [System.IO.Path]::GetTempPath()

    $targets = @()
    if ($userTemp) {
        $targets += New-CPanTarget `
            -Id 'UserTemp' `
            -Name 'Current user temporary files' `
            -Path $userTemp `
            -Kind 'DirectoryChildren' `
            -Risk 'Low' `
            -Category 'Temp' `
            -Default $true `
            -RequiresAdmin $false `
            -UseAgeFilter $true `
            -Description 'Files under the current user temp directory older than the selected age.'
    }

    $targets += New-CPanTarget `
        -Id 'WindowsTemp' `
        -Name 'Windows temporary files' `
        -Path "$systemDrive\Windows\Temp" `
        -Kind 'DirectoryChildren' `
        -Risk 'Low' `
        -Category 'Temp' `
        -Default $true `
        -RequiresAdmin $false `
        -UseAgeFilter $true `
        -Description 'Files under Windows Temp older than the selected age. Locked files are skipped.'

    $targets += New-CPanTarget `
        -Id 'WindowsErrorReporting' `
        -Name 'Windows Error Reporting cache' `
        -Path "$systemDrive\ProgramData\Microsoft\Windows\WER" `
        -Kind 'DirectoryChildren' `
        -Risk 'Low' `
        -Category 'DiagnosticsCache' `
        -Default $true `
        -RequiresAdmin $true `
        -UseAgeFilter $false `
        -Description 'Windows Error Reporting diagnostic reports and queued archive data.'

    $targets += New-CPanTarget `
        -Id 'DebugSymbolCache' `
        -Name 'Debug symbol cache' `
        -Path "$systemDrive\ProgramData\Dbg\sym" `
        -Kind 'DirectoryChildren' `
        -Risk 'Low' `
        -Category 'DiagnosticsCache' `
        -Default $true `
        -RequiresAdmin $true `
        -UseAgeFilter $false `
        -Description 'Downloaded debug symbol cache.'

    if ($env:LOCALAPPDATA) {
        $targets += New-CPanTarget `
            -Id 'InternetCache' `
            -Name 'Windows Internet cache' `
            -Path (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\INetCache') `
            -Kind 'DirectoryChildren' `
            -Risk 'Low' `
            -Category 'InternetCache' `
            -Default $true `
            -RequiresAdmin $false `
            -UseAgeFilter $false `
            -Description 'Current user Windows Internet cache.'

        $targets += New-CPanTarget `
            -Id 'UserCrashDumps' `
            -Name 'Current user crash dumps' `
            -Path (Join-Path $env:LOCALAPPDATA 'CrashDumps') `
            -Kind 'DirectoryChildren' `
            -Risk 'Low' `
            -Category 'CrashDumps' `
            -Default $true `
            -RequiresAdmin $false `
            -UseAgeFilter $false `
            -Description 'Current user application crash dump files.'
    }

    $targets += New-CPanTarget `
        -Id 'WindowsUpdateDownload' `
        -Name 'Windows Update download cache' `
        -Path "$systemDrive\Windows\SoftwareDistribution\Download" `
        -Kind 'DirectoryChildren' `
        -Risk 'Medium' `
        -Category 'WindowsUpdate' `
        -Default $false `
        -RequiresAdmin $true `
        -UseAgeFilter $false `
        -Description 'Downloaded Windows Update payloads. Parent folder is preserved.'

    $targets += New-CPanTarget `
        -Id 'WindowsUpgradeBT' `
        -Name 'Windows upgrade staging $WINDOWS.~BT' `
        -Path "$systemDrive\`$WINDOWS.~BT" `
        -Kind 'DirectoryChildren' `
        -Risk 'Medium' `
        -Category 'WindowsUpdate' `
        -Default $false `
        -RequiresAdmin $true `
        -UseAgeFilter $false `
        -Description 'Feature update or setup staging content.'

    $targets += New-CPanTarget `
        -Id 'WindowsUpgradeWS' `
        -Name 'Windows upgrade staging $Windows.~WS' `
        -Path "$systemDrive\`$Windows.~WS" `
        -Kind 'DirectoryChildren' `
        -Risk 'Medium' `
        -Category 'WindowsUpdate' `
        -Default $false `
        -RequiresAdmin $true `
        -UseAgeFilter $false `
        -Description 'Feature update or setup staging content.'

    $targets += New-CPanTarget `
        -Id 'Windows10Upgrade' `
        -Name 'Windows Update Assistant cache' `
        -Path "$systemDrive\Windows10Upgrade" `
        -Kind 'DirectoryChildren' `
        -Risk 'Medium' `
        -Category 'WindowsUpdate' `
        -Default $false `
        -RequiresAdmin $true `
        -UseAgeFilter $false `
        -Description 'Windows Update Assistant payload cache.'

    $targets += New-CPanTarget `
        -Id 'DeliveryOptimizationProgramData' `
        -Name 'Delivery Optimization cache' `
        -Path "$systemDrive\ProgramData\Microsoft\Windows\DeliveryOptimization\Cache" `
        -Kind 'DirectoryChildren' `
        -Risk 'Medium' `
        -Category 'DeliveryOptimization' `
        -Default $false `
        -RequiresAdmin $true `
        -UseAgeFilter $false `
        -Description 'Delivery Optimization cache under ProgramData.'

    $targets += New-CPanTarget `
        -Id 'DeliveryOptimizationNetworkService' `
        -Name 'Delivery Optimization NetworkService cache' `
        -Path "$systemDrive\Windows\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache" `
        -Kind 'DirectoryChildren' `
        -Risk 'Medium' `
        -Category 'DeliveryOptimization' `
        -Default $false `
        -RequiresAdmin $true `
        -UseAgeFilter $false `
        -Description 'Delivery Optimization cache under NetworkService.'

    $targets += New-CPanTarget `
        -Id 'RecycleBinC' `
        -Name 'Recycle Bin on C drive' `
        -Path "$systemDrive\`$Recycle.Bin" `
        -Kind 'RecycleBin' `
        -Risk 'High' `
        -Category 'RecycleBin' `
        -Default $false `
        -RequiresAdmin $false `
        -UseAgeFilter $false `
        -Description 'Empties the C drive recycle bin. This can permanently remove user-deleted files.'

    $targets += New-CPanTarget `
        -Id 'NetLimiterStatsDb' `
        -Name 'NetLimiter traffic statistics database' `
        -Path "$systemDrive\ProgramData\Locktime\NetLimiter\5\Stats\nlstats.db" `
        -Kind 'FileSelf' `
        -Risk 'High' `
        -Category 'NetLimiterStats' `
        -Default $false `
        -RequiresAdmin $true `
        -UseAgeFilter $false `
        -Description 'NetLimiter traffic history database. Removing it frees space but loses historical traffic statistics.'

    $targets += New-CPanTarget `
        -Id 'VisualStudioPackageCache' `
        -Name 'Visual Studio installer package cache' `
        -Path "$systemDrive\ProgramData\Microsoft\VisualStudio\Packages" `
        -Kind 'DirectoryChildren' `
        -Risk 'High' `
        -Category 'VisualStudioPackageCache' `
        -Default $false `
        -RequiresAdmin $true `
        -UseAgeFilter $false `
        -Description 'Visual Studio installer package cache. Removing it can free significant space but may affect repair, modify, or uninstall operations.'

    return $targets
}

function Get-CPanOldQuarantineTargets {
    $systemDrive = Get-CPanSystemDrive
    $targets = @()
    $definitions = @(
        [pscustomobject]@{ Parent = "$systemDrive\Windows\SoftwareDistribution"; Pattern = 'Download.codex-cleanup-*' },
        [pscustomobject]@{ Parent = "$systemDrive\Windows\SoftwareDistribution"; Pattern = 'Download.cpancleaner-quarantine-*' },
        [pscustomobject]@{ Parent = "$systemDrive\"; Pattern = '$WINDOWS.~BT.codex-cleanup-*' },
        [pscustomobject]@{ Parent = "$systemDrive\"; Pattern = '$Windows.~WS.codex-cleanup-*' },
        [pscustomobject]@{ Parent = "$systemDrive\"; Pattern = 'Windows10Upgrade.codex-cleanup-*' },
        [pscustomobject]@{ Parent = "$systemDrive\"; Pattern = '$WINDOWS.~BT.cpancleaner-quarantine-*' },
        [pscustomobject]@{ Parent = "$systemDrive\"; Pattern = '$Windows.~WS.cpancleaner-quarantine-*' },
        [pscustomobject]@{ Parent = "$systemDrive\"; Pattern = 'Windows10Upgrade.cpancleaner-quarantine-*' }
    )

    foreach ($definition in $definitions) {
        if (-not (Test-Path -LiteralPath $definition.Parent)) {
            continue
        }

        $matches = Get-ChildItem -LiteralPath $definition.Parent -Force -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like $definition.Pattern }

        foreach ($match in $matches) {
            $targets += New-CPanTarget `
                -Id ('OldQuarantine:' + $match.Name) `
                -Name ('Old isolated cleanup directory: ' + $match.Name) `
                -Path $match.FullName `
                -Kind 'DirectorySelf' `
                -Risk 'Medium' `
                -Category 'OldQuarantine' `
                -Default $false `
                -RequiresAdmin $true `
                -UseAgeFilter $false `
                -Description 'Old cleanup isolation directory created by a previous maintenance run.'
        }
    }

    return $targets
}

function Get-CPanCodexPreviousRuntimeTargets {
    $userProfile = ConvertTo-CPanFullPath $env:USERPROFILE
    if (-not $userProfile) {
        return @()
    }

    $runtimeRoot = Join-Path $userProfile '.cache\codex-runtimes'
    if (-not (Test-Path -LiteralPath $runtimeRoot)) {
        return @()
    }

    $targets = @()
    $matches = Get-ChildItem -LiteralPath $runtimeRoot -Force -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'codex-primary-runtime.previous-*' }

    foreach ($match in $matches) {
        $targets += New-CPanTarget `
            -Id ('CodexPreviousRuntime:' + $match.Name) `
            -Name ('Old Codex runtime cache: ' + $match.Name) `
            -Path $match.FullName `
            -Kind 'DirectorySelf' `
            -Risk 'Low' `
            -Category 'CodexRuntimeCache' `
            -Default $true `
            -RequiresAdmin $false `
            -UseAgeFilter $false `
            -Description 'Old Codex runtime cache directory. Current runtime directories are kept.'
    }

    return $targets
}

function Get-CPanCleanerTarget {
    param(
        [string[]] $Include = @('Default')
    )

    if (-not $Include -or $Include.Count -eq 0) {
        $Include = @('Default')
    }

    $knownIncludes = @(
        'Default',
        'Temp',
        'DiagnosticsCache',
        'InternetCache',
        'CrashDumps',
        'CodexRuntimeCache',
        'WindowsUpdate',
        'DeliveryOptimization',
        'RecycleBin',
        'OldQuarantine',
        'NetLimiterStats',
        'VisualStudioPackageCache',
        'All'
    )

    $normalized = @($Include | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $targets = @(Get-CPanStaticTargets)
    if ($normalized -contains 'Default' -or $normalized -contains 'CodexRuntimeCache' -or $normalized -contains 'All' -or @($normalized | Where-Object { $_ -like 'CodexPreviousRuntime:*' }).Count -gt 0) {
        $targets += @(Get-CPanCodexPreviousRuntimeTargets)
    }

    if ($normalized -contains 'OldQuarantine' -or $normalized -contains 'All' -or @($normalized | Where-Object { $_ -like 'OldQuarantine:*' }).Count -gt 0) {
        $targets += @(Get-CPanOldQuarantineTargets)
    }

    $invalid = @($normalized | Where-Object {
        $includeItem = $_
        $knownIncludes -notcontains $includeItem -and
        @($targets | Where-Object { $_.Id -eq $includeItem }).Count -eq 0
    })

    if ($invalid.Count -gt 0) {
        throw ('Unknown Include value(s): {0}' -f ($invalid -join ', '))
    }

    if ($normalized -contains 'All') {
        return $targets
    }

    $selected = @()
    if ($normalized -contains 'Default') {
        $selected += $targets | Where-Object { $_.Default }
    }

    foreach ($includeItem in $normalized) {
        if ($includeItem -eq 'Default') {
            continue
        }

        $selected += $targets | Where-Object {
            $_.Category -eq $includeItem -or $_.Id -eq $includeItem
        }
    }

    return $selected | Sort-Object Id -Unique
}

function Get-CPanCandidateItems {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Target,

        [int] $MinimumAgeDays = 1,
        [int] $MinimumAgeHours = -1
    )

    if (-not $Target.Path -or -not (Test-Path -LiteralPath $Target.Path)) {
        return @()
    }

    if ($Target.Kind -eq 'DirectorySelf' -or $Target.Kind -eq 'FileSelf') {
        return @(Get-Item -LiteralPath $Target.Path -Force -ErrorAction SilentlyContinue)
    }

    if ($Target.Kind -ne 'DirectoryChildren') {
        return @()
    }

    $items = @(Get-ChildItem -LiteralPath $Target.Path -Force -ErrorAction SilentlyContinue)
    if ($Target.UseAgeFilter) {
        $cutoff = if ($MinimumAgeHours -ge 0) {
            (Get-Date).AddHours(-1 * $MinimumAgeHours)
        } else {
            (Get-Date).AddDays(-1 * [Math]::Max(0, $MinimumAgeDays))
        }
        $items = @($items | Where-Object { $_.LastWriteTime -le $cutoff })
    }

    return $items
}

function Measure-CPanFileSystemItem {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileSystemInfo] $Item,

        [int] $MaxScanItems = 100000
    )

    $bytes = [int64] 0
    $count = [int64] 0
    $truncated = $false

    if (-not $Item.PSIsContainer) {
        $fileInfo = [System.IO.FileInfo] $Item
        return [pscustomobject]@{
            Bytes = [int64] $fileInfo.Length
            Count = [int64] 1
            Truncated = $false
        }
    }

    $children = Get-ChildItem -LiteralPath $Item.FullName -Recurse -Force -ErrorAction SilentlyContinue
    foreach ($child in $children) {
        $count++
        if ($child -is [System.IO.FileInfo]) {
            $bytes += [int64] $child.Length
        }

        if ($count -ge $MaxScanItems) {
            $truncated = $true
            break
        }
    }

    return [pscustomobject]@{
        Bytes = $bytes
        Count = $count
        Truncated = $truncated
    }
}

function Measure-CPanTarget {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Target,

        [int] $MinimumAgeDays = 1,
        [int] $MinimumAgeHours = -1,
        [int] $MaxScanItems = 100000
    )

    $exists = $Target.Path -and (Test-Path -LiteralPath $Target.Path)
    $bytes = [int64] 0
    $count = [int64] 0
    $truncated = $false
    $notes = @()

    if ($exists -and $Target.Kind -eq 'RecycleBin') {
        $measurement = Measure-CPanDirectoryByPath -Path $Target.Path -MaxScanItems $MaxScanItems
        $bytes = $measurement.Bytes
        $count = $measurement.Count
        $truncated = $measurement.Truncated
    } elseif ($exists) {
        $candidates = @(Get-CPanCandidateItems -Target $Target -MinimumAgeDays $MinimumAgeDays -MinimumAgeHours $MinimumAgeHours)
        foreach ($candidate in $candidates) {
            $measurement = Measure-CPanFileSystemItem -Item $candidate -MaxScanItems $MaxScanItems
            $bytes += $measurement.Bytes
            $count += $measurement.Count
            if ($measurement.Truncated) {
                $truncated = $true
            }
        }
    }

    if ($truncated) {
        $notes += "Size estimate stopped after $MaxScanItems scanned items."
    }

    return [pscustomobject]@{
        Id = $Target.Id
        Name = $Target.Name
        Category = $Target.Category
        Risk = $Target.Risk
        RequiresAdmin = $Target.RequiresAdmin
        Exists = [bool] $exists
        Path = $Target.Path
        Kind = $Target.Kind
        EstimatedBytes = $bytes
        EstimatedMB = [Math]::Round(($bytes / 1MB), 2)
        ItemCount = $count
        Notes = ($notes -join ' ')
        Description = $Target.Description
    }
}

function Measure-CPanDirectoryByPath {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [int] $MaxScanItems = 100000
    )

    $bytes = [int64] 0
    $count = [int64] 0
    $truncated = $false

    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ Bytes = [int64] 0; Count = [int64] 0; Truncated = $false }
    }

    foreach ($child in Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue) {
        $count++
        if ($child -is [System.IO.FileInfo]) {
            $bytes += [int64] $child.Length
        }

        if ($count -ge $MaxScanItems) {
            $truncated = $true
            break
        }
    }

    return [pscustomobject]@{ Bytes = $bytes; Count = $count; Truncated = $truncated }
}

function Invoke-CPanWindowsUpdatePause {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Context
    )

    $services = @('UsoSvc', 'wuauserv', 'DoSvc')
    foreach ($service in $services) {
        try {
            Write-CPanLog -Context $Context -Level 'INFO' -Message "Stopping service $service before cache cleanup."
            & sc.exe stop $service | Out-Null
        } catch {
            Write-CPanLog -Context $Context -Level 'WARN' -Message "Could not stop service ${service}: $($_.Exception.Message)"
        }
    }
}

function Stop-CPanNetLimiterService {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Context
    )

    $serviceName = 'NLSvc'
    $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if (-not $service) {
        Write-CPanLog -Context $Context -Level 'WARN' -Message 'NetLimiter service NLSvc was not found; continuing with file cleanup.'
        return [pscustomobject]@{
            ServiceFound = $false
            WasRunning = $false
            Stopped = $true
            ServiceName = $serviceName
        }
    }

    $wasRunning = $service.Status -eq 'Running'
    if (-not $wasRunning) {
        Write-CPanLog -Context $Context -Level 'INFO' -Message "NetLimiter service $serviceName is $($service.Status); no stop needed."
        return [pscustomobject]@{
            ServiceFound = $true
            WasRunning = $false
            Stopped = $true
            ServiceName = $serviceName
        }
    }

    try {
        Write-CPanLog -Context $Context -Level 'INFO' -Message "Stopping NetLimiter service $serviceName before deleting traffic statistics."
        Stop-Service -Name $serviceName -Force -ErrorAction Stop

        $stopped = $false
        for ($i = 0; $i -lt 15; $i++) {
            Start-Sleep -Seconds 1
            $current = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
            if ($current -and $current.Status -eq 'Stopped') {
                $stopped = $true
                break
            }
        }

        if (-not $stopped) {
            Write-CPanLog -Context $Context -Level 'WARN' -Message "NetLimiter service $serviceName did not stop within the wait window."
        }

        return [pscustomobject]@{
            ServiceFound = $true
            WasRunning = $true
            Stopped = $stopped
            ServiceName = $serviceName
        }
    } catch {
        $current = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        $stoppedAfterError = $current -and $current.Status -eq 'Stopped'
        Write-CPanLog -Context $Context -Level 'WARN' -Message "Could not stop NetLimiter service ${serviceName}: $($_.Exception.Message)"
        return [pscustomobject]@{
            ServiceFound = $true
            WasRunning = $true
            Stopped = [bool] $stoppedAfterError
            ServiceName = $serviceName
        }
    }
}

function Restore-CPanNetLimiterService {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Context,

        [Parameter(Mandatory = $true)]
        [pscustomobject] $State
    )

    if (-not $State.ServiceFound -or -not $State.WasRunning -or -not $State.Stopped) {
        return
    }

    try {
        Write-CPanLog -Context $Context -Level 'INFO' -Message "Restarting NetLimiter service $($State.ServiceName)."
        Start-Service -Name $State.ServiceName -ErrorAction Stop
    } catch {
        Write-CPanLog -Context $Context -Level 'WARN' -Message "Could not restart NetLimiter service $($State.ServiceName): $($_.Exception.Message)"
    }
}

function Remove-CPanSafeItem {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileSystemInfo] $Item,

        [Parameter(Mandatory = $true)]
        [string] $AllowedRoot,

        [Parameter(Mandatory = $true)]
        [pscustomobject] $Context,

        [switch] $AllowRootItself
    )

    if (-not (Test-CPanPathSafety -Path $Item.FullName -AllowedRoot $AllowedRoot -AllowRootItself:$AllowRootItself)) {
        Write-CPanLog -Context $Context -Level 'WARN' -Message "Blocked unsafe deletion candidate: $($Item.FullName)"
        return [pscustomobject]@{ Removed = $false; Path = $Item.FullName; Error = 'Blocked by safety policy' }
    }

    try {
        Remove-Item -LiteralPath $Item.FullName -Recurse -Force -ErrorAction Stop
        Write-CPanLog -Context $Context -Level 'INFO' -Message "Removed $($Item.FullName)"
        return [pscustomobject]@{ Removed = $true; Path = $Item.FullName; Error = $null }
    } catch {
        Write-CPanLog -Context $Context -Level 'WARN' -Message "Failed to remove $($Item.FullName): $($_.Exception.Message)"
        return [pscustomobject]@{ Removed = $false; Path = $Item.FullName; Error = $_.Exception.Message }
    }
}

function Invoke-CPanCleanTarget {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Target,

        [Parameter(Mandatory = $true)]
        [pscustomobject] $Context,

        [int] $MinimumAgeDays = 1,
        [int] $MinimumAgeHours = -1,
        [switch] $Apply,
        [bool] $IsAdmin
    )

    $measurement = Measure-CPanTarget -Target $Target -MinimumAgeDays $MinimumAgeDays -MinimumAgeHours $MinimumAgeHours
    $mode = if ($Apply) { 'Apply' } else { 'DryRun' }
    $status = 'WouldClean'
    $removedCount = [int64] 0
    $errors = @()

    if (-not $measurement.Exists) {
        $status = 'Missing'
        return [pscustomobject]@{
            Id = $Target.Id
            Name = $Target.Name
            Category = $Target.Category
            Risk = $Target.Risk
            Mode = $mode
            Status = $status
            Exists = $measurement.Exists
            EstimatedMB = $measurement.EstimatedMB
            ItemCount = $measurement.ItemCount
            RemovedCount = $removedCount
            Path = $Target.Path
            Message = 'Path does not exist.'
        }
    }

    if ($Target.RequiresAdmin -and -not $IsAdmin) {
        $status = 'NeedsAdministrator'
        Write-CPanLog -Context $Context -Level 'WARN' -Message "Skipping $($Target.Id) because administrator rights are required."
        return [pscustomobject]@{
            Id = $Target.Id
            Name = $Target.Name
            Category = $Target.Category
            Risk = $Target.Risk
            Mode = $mode
            Status = $status
            Exists = $measurement.Exists
            EstimatedMB = $measurement.EstimatedMB
            ItemCount = $measurement.ItemCount
            RemovedCount = $removedCount
            Path = $Target.Path
            Message = 'Run again as Administrator, or use the wrapper -Elevate switch.'
        }
    }

    if (-not $Apply) {
        Write-CPanLog -Context $Context -Level 'INFO' -Message "Dry-run: $($Target.Id) would clean $($measurement.EstimatedMB) MB from $($Target.Path)"
        return [pscustomobject]@{
            Id = $Target.Id
            Name = $Target.Name
            Category = $Target.Category
            Risk = $Target.Risk
            Mode = $mode
            Status = $status
            Exists = $measurement.Exists
            EstimatedMB = $measurement.EstimatedMB
            ItemCount = $measurement.ItemCount
            RemovedCount = $removedCount
            Path = $Target.Path
            Message = 'Dry-run only. Pass -Apply to remove candidates.'
        }
    }

    if ($Target.Category -eq 'WindowsUpdate') {
        Invoke-CPanWindowsUpdatePause -Context $Context
    }

    $netLimiterState = $null
    if ($Target.Category -eq 'NetLimiterStats') {
        $netLimiterState = Stop-CPanNetLimiterService -Context $Context
        if ($netLimiterState.WasRunning -and -not $netLimiterState.Stopped) {
            Restore-CPanNetLimiterService -Context $Context -State $netLimiterState
            return [pscustomobject]@{
                Id = $Target.Id
                Name = $Target.Name
                Category = $Target.Category
                Risk = $Target.Risk
                Mode = $mode
                Status = 'PartialOrFailed'
                Exists = $measurement.Exists
                EstimatedMB = $measurement.EstimatedMB
                ItemCount = $measurement.ItemCount
                RemovedCount = $removedCount
                Path = $Target.Path
                Message = 'NLSvc could not be stopped safely; nlstats.db was not removed.'
            }
        }
    }

    try {
        if ($Target.Kind -eq 'RecycleBin') {
            try {
                Clear-RecycleBin -DriveLetter (Get-CPanSystemDrive).TrimEnd(':') -Force -ErrorAction Stop
                $status = 'Cleaned'
                Write-CPanLog -Context $Context -Level 'INFO' -Message 'Emptied C drive recycle bin.'
            } catch {
                $status = 'PartialOrFailed'
                $errors += $_.Exception.Message
                Write-CPanLog -Context $Context -Level 'WARN' -Message "Failed to empty recycle bin: $($_.Exception.Message)"
            }
        } else {
            $candidates = @(Get-CPanCandidateItems -Target $Target -MinimumAgeDays $MinimumAgeDays -MinimumAgeHours $MinimumAgeHours)
            foreach ($candidate in $candidates) {
                $allowRoot = $Target.Kind -eq 'DirectorySelf' -or $Target.Kind -eq 'FileSelf'
                $result = Remove-CPanSafeItem -Item $candidate -AllowedRoot $Target.Path -Context $Context -AllowRootItself:$allowRoot
                if ($result.Removed) {
                    $removedCount++
                } elseif ($result.Error) {
                    $errors += $result.Error
                }
            }

            $status = if ($errors.Count -eq 0) { 'Cleaned' } else { 'PartialOrFailed' }
        }
    } finally {
        if ($netLimiterState) {
            Restore-CPanNetLimiterService -Context $Context -State $netLimiterState
        }
    }

    return [pscustomobject]@{
        Id = $Target.Id
        Name = $Target.Name
        Category = $Target.Category
        Risk = $Target.Risk
        Mode = $mode
        Status = $status
        Exists = $measurement.Exists
        EstimatedMB = $measurement.EstimatedMB
        ItemCount = $measurement.ItemCount
        RemovedCount = $removedCount
        Path = $Target.Path
        Message = ($errors -join ' | ')
    }
}

function Get-CPanDiagnostics {
    param(
        [string] $RepositoryPath
    )

    $findings = @()

    try {
        $processes = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
        $gitProcesses = $processes | Where-Object {
            ($_.Name -eq 'git.exe' -or $_.Name -eq 'git-remote-http.exe') -and
            ($_.CommandLine -match 'fsmonitor--daemon|git fetch|git remote-http')
        }

        foreach ($process in $gitProcesses) {
            $findings += [pscustomobject]@{
                Type = 'GitProcess'
                Severity = 'Info'
                Name = $process.Name
                Id = $process.ProcessId
                Message = 'Git background fetch/fsmonitor process found. Diagnose before stopping it.'
                Detail = $process.CommandLine
            }
        }

        $condaProcesses = $processes | Where-Object {
            $_.Name -eq 'python.exe' -and
            $_.CommandLine -match 'conda-script.py shell.powershell (hook|activate)'
        }

        foreach ($process in $condaProcesses) {
            $findings += [pscustomobject]@{
                Type = 'CondaProcess'
                Severity = 'Info'
                Name = $process.Name
                Id = $process.ProcessId
                Message = 'Conda PowerShell initialization helper is still running.'
                Detail = $process.CommandLine
            }
        }
    } catch {
        $findings += [pscustomobject]@{
            Type = 'Diagnostics'
            Severity = 'Warning'
            Name = 'ProcessQuery'
            Id = $null
            Message = 'Process diagnostics could not be collected.'
            Detail = $_.Exception.Message
        }
    }

    if ($RepositoryPath -and (Test-Path -LiteralPath $RepositoryPath)) {
        try {
            $gitDir = & git -C $RepositoryPath rev-parse --git-dir 2>$null
            if ($LASTEXITCODE -eq 0 -and $gitDir) {
                $fsmonitor = & git -C $RepositoryPath config --get core.fsmonitor 2>$null
                $untrackedCache = & git -C $RepositoryPath config --get core.untrackedCache 2>$null
                $findings += [pscustomobject]@{
                    Type = 'GitConfig'
                    Severity = 'Info'
                    Name = 'core.fsmonitor'
                    Id = $null
                    Message = 'Repository Git fsmonitor setting.'
                    Detail = if ($fsmonitor) { $fsmonitor } else { '<unset>' }
                }
                $findings += [pscustomobject]@{
                    Type = 'GitConfig'
                    Severity = 'Info'
                    Name = 'core.untrackedCache'
                    Id = $null
                    Message = 'Repository Git untracked cache setting.'
                    Detail = if ($untrackedCache) { $untrackedCache } else { '<unset>' }
                }
            }
        } catch {
            $findings += [pscustomobject]@{
                Type = 'GitConfig'
                Severity = 'Warning'
                Name = 'Repository'
                Id = $null
                Message = 'Git repository diagnostics failed.'
                Detail = $_.Exception.Message
            }
        }
    }

    if ($findings.Count -eq 0) {
        $findings += [pscustomobject]@{
            Type = 'Diagnostics'
            Severity = 'Info'
            Name = 'NoFindings'
            Id = $null
            Message = 'No stale Git fsmonitor/fetch or Conda PowerShell helper processes were found.'
            Detail = ''
        }
    }

    return $findings
}

function Invoke-CPanCleaner {
    [CmdletBinding()]
    param(
        [ValidateSet('Scan', 'Clean', 'Diagnose')]
        [string] $Action = 'Scan',

        [string[]] $Include = @('Default'),

        [switch] $Apply,
        [switch] $DryRun,
        [int] $MinimumAgeDays = 1,
        [int] $MinimumAgeHours = -1,
        [int] $MaxScanItems = 100000,
        [string] $LogDirectory,
        [string] $CsvPath,
        [string] $RepositoryPath = (Get-Location).Path,
        [switch] $Quiet
    )

    if ($Apply -and $DryRun) {
        throw 'Use either -Apply or -DryRun, not both.'
    }

    $context = New-CPanRunContext -LogDirectory $LogDirectory -Quiet:$Quiet
    $isAdmin = Test-CPanAdministrator
    $effectiveApply = [bool] $Apply

    Write-CPanLog -Context $context -Level 'INFO' -Message "CPanCleaner $script:CleanerVersion started. Action=$Action Apply=$effectiveApply IsAdmin=$isAdmin"

    $items = @()
    $diagnostics = @()

    if ($Action -eq 'Diagnose') {
        $diagnostics = @(Get-CPanDiagnostics -RepositoryPath $RepositoryPath)
    } else {
        $targets = @(Get-CPanCleanerTarget -Include $Include)
        if ($Action -eq 'Scan') {
            foreach ($target in $targets) {
                $items += Measure-CPanTarget -Target $target -MinimumAgeDays $MinimumAgeDays -MinimumAgeHours $MinimumAgeHours -MaxScanItems $MaxScanItems
            }
        } elseif ($Action -eq 'Clean') {
            foreach ($target in $targets) {
                $items += Invoke-CPanCleanTarget -Target $target -Context $context -MinimumAgeDays $MinimumAgeDays -MinimumAgeHours $MinimumAgeHours -Apply:$effectiveApply -IsAdmin $isAdmin
            }
        }
    }

    $effectiveCsvPath = $null
    if ($items.Count -gt 0) {
        $effectiveCsvPath = if ([string]::IsNullOrWhiteSpace($CsvPath)) {
            [System.IO.Path]::ChangeExtension($context.LogPath, '.csv')
        } else {
            $CsvPath
        }

        $csvDirectory = Split-Path -Parent $effectiveCsvPath
        if ($csvDirectory) {
            New-Item -ItemType Directory -Force -Path $csvDirectory | Out-Null
        }

        $items | Export-Csv -LiteralPath $effectiveCsvPath -NoTypeInformation -Encoding UTF8
        Write-CPanLog -Context $context -Level 'INFO' -Message "CSV report: $effectiveCsvPath"
    }

    $summary = [pscustomobject]@{
        Version = $script:CleanerVersion
        Action = $Action
        Mode = if ($Action -eq 'Clean' -and $effectiveApply) { 'Apply' } elseif ($Action -eq 'Clean') { 'DryRun' } else { 'ReadOnly' }
        IsAdministrator = $isAdmin
        Include = ($Include -join ',')
        MinimumAgeDays = $MinimumAgeDays
        MinimumAgeHours = $MinimumAgeHours
        LogPath = $context.LogPath
        CsvPath = $effectiveCsvPath
        Items = $items
        Diagnostics = $diagnostics
    }

    Write-CPanLog -Context $context -Level 'INFO' -Message "CPanCleaner finished. Log=$($context.LogPath)"
    return $summary
}

function Format-CPanBytes {
    param([int64] $Bytes)

    if ($Bytes -ge 1GB) {
        return ('{0:N2} GB' -f ($Bytes / 1GB))
    }
    if ($Bytes -ge 1MB) {
        return ('{0:N2} MB' -f ($Bytes / 1MB))
    }
    if ($Bytes -ge 1KB) {
        return ('{0:N2} KB' -f ($Bytes / 1KB))
    }
    return "$Bytes B"
}

Export-ModuleMember -Function @(
    'Get-CPanCleanerTarget',
    'Get-CPanDiagnostics',
    'Invoke-CPanCleaner',
    'Test-CPanAdministrator',
    'Test-CPanPathSafety',
    'ConvertTo-CPanFullPath',
    'Format-CPanBytes'
)
