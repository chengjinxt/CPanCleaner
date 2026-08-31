Set-StrictMode -Version 2.0

$script:CleanerVersion = '2.4.0'

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

    $isRootItself = [string]::Equals($fullPath, $rootPath, $comparison)
    if ($isRootItself -and -not $AllowRootItself) {
        return $false
    }

    if (-not $isRootItself -and -not $fullPath.StartsWith($rootWithSlash, $comparison)) {
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
    Add-Content -LiteralPath $Context.LogPath -Value $line -Encoding UTF8
    if (-not $Context.Quiet) {
        Write-Verbose $line
    }
}

function New-CPanDiagnosticRecord {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Type,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Info', 'Warning', 'Error')]
        [string] $Severity,

        [Parameter(Mandatory = $true)]
        [string] $Name,

        [object] $Id = $null,

        [Parameter(Mandatory = $true)]
        [string] $Message,

        [string] $Detail = ''
    )

    return [pscustomobject]@{
        Type = $Type
        Severity = $Severity
        Name = $Name
        Id = $Id
        Message = $Message
        Detail = $Detail
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
        [string] $Description = '',
        [string[]] $ProcessNames = @(),
        [string] $Recommendation = '',
        [string] $MigrationSupport = 'None'
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
        ProcessNames = @($ProcessNames)
        Recommendation = $Recommendation
        MigrationSupport = $MigrationSupport
    }
}

function Get-CPanProcessBlockers {
    param([string[]] $ProcessNames = @())

    if (-not $ProcessNames -or $ProcessNames.Count -eq 0) {
        return @()
    }

    $wanted = @($ProcessNames | ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_) } | Where-Object { $_ } | Sort-Object -Unique)
    $blockers = @()
    foreach ($processName in $wanted) {
        $blockers += @(Get-Process -Name $processName -ErrorAction SilentlyContinue | ForEach-Object {
            '{0} (PID {1})' -f $_.ProcessName, $_.Id
        })
    }
    return @($blockers | Sort-Object -Unique)
}

function Get-CPanBrowserCacheTargets {
    $definitions = @()
    if ($env:LOCALAPPDATA) {
        $definitions = @(
            [pscustomobject]@{ Browser = 'Chrome'; Root = (Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data'); Process = 'chrome' },
            [pscustomobject]@{ Browser = 'Edge'; Root = (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data'); Process = 'msedge' }
        )
    }

    $targets = @()
    $basicLeaves = @('Cache', 'Code Cache', 'GPUCache', 'DawnGraphiteCache', 'DawnWebGPUCache', 'GrShaderCache')
    foreach ($definition in $definitions) {
        if (-not (Test-Path -LiteralPath $definition.Root -PathType Container)) {
            continue
        }

        $profiles = @(Get-ChildItem -LiteralPath $definition.Root -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object {
                -not ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -and
                ($_.Name -eq 'Default' -or $_.Name -eq 'Guest Profile' -or $_.Name -eq 'System Profile' -or $_.Name -match '^Profile \d+$')
            })

        foreach ($profile in $profiles) {
            $safeProfile = ($profile.Name -replace '[^A-Za-z0-9]+', '')
            foreach ($leaf in $basicLeaves) {
                $leafPath = Join-Path $profile.FullName $leaf
                if (-not (Test-Path -LiteralPath $leafPath -PathType Container)) {
                    continue
                }
                $safeLeaf = ($leaf -replace '[^A-Za-z0-9]+', '')
                $targets += New-CPanTarget -Id ("{0}{1}{2}" -f $definition.Browser, $safeProfile, $safeLeaf) `
                    -Name ("{0} {1} - {2}" -f $definition.Browser, $profile.Name, $leaf) `
                    -Path $leafPath -Kind 'DirectoryChildren' -Risk 'Low' -Category 'BrowserCache' -Default $true `
                    -RequiresAdmin $false -UseAgeFilter $false -ProcessNames @($definition.Process) `
                    -Recommendation '关闭浏览器后清理。缓存会自动重建，不影响书签、Cookie、密码和扩展。' `
                    -Description '仅命中浏览器配置目录下精确白名单缓存叶目录。'
            }

            $offlineLeaves = @(
                (Join-Path $profile.FullName 'Service Worker\CacheStorage'),
                (Join-Path $profile.FullName 'ScriptCache')
            )
            foreach ($offlinePath in $offlineLeaves) {
                if (-not (Test-Path -LiteralPath $offlinePath -PathType Container)) {
                    continue
                }
                $safeLeaf = ((Split-Path -Leaf $offlinePath) -replace '[^A-Za-z0-9]+', '')
                $targets += New-CPanTarget -Id ("{0}{1}Offline{2}" -f $definition.Browser, $safeProfile, $safeLeaf) `
                    -Name ("{0} {1} - 离线网页缓存 {2}" -f $definition.Browser, $profile.Name, (Split-Path -Leaf $offlinePath)) `
                    -Path $offlinePath -Kind 'DirectoryChildren' -Risk 'Medium' -Category 'BrowserOfflineCache' -Default $false `
                    -RequiresAdmin $false -UseAgeFilter $false -ProcessNames @($definition.Process) `
                    -Recommendation '会丢失网站离线副本并触发重新下载；关闭浏览器后单独确认。' `
                    -Description 'Service Worker 或脚本离线缓存；不触碰站点 Cookie、IndexedDB、Local Storage 或账号数据。'
            }
        }
    }
    return $targets
}

function Get-CPanApplicationCacheTargets {
    $targets = @()
    $definitions = @()
    if ($env:LOCALAPPDATA) {
        $definitions += @(
            [pscustomobject]@{ Id='NpmCache'; Name='npm download cache'; Relative='npm-cache'; Category='NpmCache'; Risk='Low'; Processes=@('node','npm'); Recommendation='后续 npm 安装会重新下载依赖。' },
            [pscustomobject]@{ Id='JianyingCache'; Name='剪映可重建缓存'; Relative='JianyingPro\User Data\Cache'; Category='JianyingCache'; Risk='Low'; Processes=@('JianyingPro'); Recommendation='关闭剪映后清理；草稿和工程目录不在目标内。' },
            [pscustomobject]@{ Id='JianyingLog'; Name='剪映日志'; Relative='JianyingPro\User Data\Log'; Category='JianyingCache'; Risk='Low'; Processes=@('JianyingPro'); Recommendation='仅删除日志，不触碰草稿。' },
            [pscustomobject]@{ Id='NuGetV3Cache'; Name='NuGet HTTP v3 cache'; Relative='NuGet\v3-cache'; Category='NuGetCache'; Risk='Medium'; Processes=@('dotnet','devenv','MSBuild','nuget','VBCSCompiler'); Recommendation='优先使用官方 dotnet nuget locals 命令；后续还原包会重新下载。' },
            [pscustomobject]@{ Id='NuGetPluginsCache'; Name='NuGet plugins cache'; Relative='NuGet\plugins-cache'; Category='NuGetCache'; Risk='Medium'; Processes=@('dotnet','devenv','MSBuild','nuget','VBCSCompiler'); Recommendation='关闭 Visual Studio、dotnet 和 NuGet 进程后执行。' },
            [pscustomobject]@{ Id='PlaywrightCache'; Name='Playwright browser packages'; Relative='ms-playwright'; Category='PlaywrightCache'; Risk='Medium'; Processes=@('node','chrome','msedge'); Recommendation='后续 Playwright 测试会重新下载浏览器包。' },
            [pscustomobject]@{ Id='PlaywrightGoCache'; Name='Playwright Go browser packages'; Relative='ms-playwright-go'; Category='PlaywrightCache'; Risk='Medium'; Processes=@('node','chrome','msedge'); Recommendation='后续测试会重新下载浏览器包。' }
        )
    }
    if ($env:APPDATA) {
        $definitions += @(
            [pscustomobject]@{ Id='VSCodeVsixCache'; Name='VS Code downloaded VSIX cache'; Root=$env:APPDATA; Relative='Code\CachedExtensionVSIXs'; Category='VSCodeCache'; Risk='Low'; Processes=@('Code'); Recommendation='关闭 VS Code 后清理；已安装扩展不会被删除。' },
            [pscustomobject]@{ Id='VSCodeCrashReports'; Name='VS Code crash reports'; Root=$env:APPDATA; Relative='Code\Crashpad\reports'; Category='VSCodeCache'; Risk='Low'; Processes=@('Code'); Recommendation='删除崩溃报告，不影响设置和扩展。' },
            [pscustomobject]@{ Id='QoderIndex'; Name='Qoder local search index'; Root=$env:APPDATA; Relative='Qoder\SharedClientCache\index'; Category='QoderCache'; Risk='Medium'; Processes=@('Qoder'); Recommendation='会触发重新索引并暂时增加 CPU/磁盘占用，必须单独确认。' },
            [pscustomobject]@{ Id='QoderSharedCache'; Name='Qoder shared client cache'; Root=$env:APPDATA; Relative='Qoder\SharedClientCache\cache'; Category='QoderCache'; Risk='Medium'; Processes=@('Qoder'); Recommendation='关闭 Qoder 后单独确认；不触碰设置、聊天和历史数据。' },
            [pscustomobject]@{ Id='WpsDownloadCache'; Name='WPS download cache'; Root=$env:APPDATA; Relative='kingsoft\wps_download'; Category='WpsCache'; Risk='Low'; Processes=@('wps','wpp','et','wpspdf'); Recommendation='关闭 WPS 后清理；addons 和文档不在目标内。' },
            [pscustomobject]@{ Id='WpsOfficeCache'; Name='WPS office cache'; Root=$env:APPDATA; Relative='kingsoft\office6\cache'; Category='WpsCache'; Risk='Low'; Processes=@('wps','wpp','et','wpspdf'); Recommendation='只处理明确缓存叶目录。' },
            [pscustomobject]@{ Id='WpsOfficeLog'; Name='WPS logs'; Root=$env:APPDATA; Relative='kingsoft\office6\log'; Category='WpsCache'; Risk='Low'; Processes=@('wps','wpp','et','wpspdf'); Recommendation='只处理日志叶目录。' },
            [pscustomobject]@{ Id='WXWorkUpgradeCache'; Name='企业微信升级包'; Root=$env:APPDATA; Relative='Tencent\WXWork\upgrade'; Category='WXWorkCache'; Risk='Medium'; Processes=@('WXWork'); Recommendation='后续升级可能重新下载；聊天记录不在目标内。' },
            [pscustomobject]@{ Id='WXWorkLog'; Name='企业微信日志'; Root=$env:APPDATA; Relative='Tencent\WXWork\Log'; Category='WXWorkCache'; Risk='Medium'; Processes=@('WXWork'); Recommendation='仅处理日志，不触碰聊天记录。' },
            [pscustomobject]@{ Id='XWeChatLog'; Name='微信日志'; Root=$env:APPDATA; Relative='Tencent\xwechat\log'; Category='WXWorkCache'; Risk='Medium'; Processes=@('xwechat','WeChat'); Recommendation='仅处理日志，不触碰聊天记录。' }
        )
    }

    foreach ($definition in $definitions) {
        $root = if ($definition.PSObject.Properties.Name -contains 'Root') { $definition.Root } else { $env:LOCALAPPDATA }
        $path = Join-Path $root $definition.Relative
        $targets += New-CPanTarget -Id $definition.Id -Name $definition.Name -Path $path -Kind 'DirectoryChildren' `
            -Risk $definition.Risk -Category $definition.Category -Default $false -RequiresAdmin $false -UseAgeFilter $false `
            -ProcessNames $definition.Processes -Recommendation $definition.Recommendation `
            -Description '精确白名单中的可重建缓存、升级包或日志目录。'
    }

    if ($env:USERPROFILE) {
        $nugetUserPath = [Environment]::GetEnvironmentVariable('NUGET_PACKAGES', 'User')
        $nugetGlobalPath = if ([string]::IsNullOrWhiteSpace($nugetUserPath)) { Join-Path $env:USERPROFILE '.nuget\packages' } else { $nugetUserPath }
        $targets += New-CPanTarget -Id 'NuGetGlobalPackages' -Name 'NuGet global packages cache' `
            -Path $nugetGlobalPath -Kind 'DirectoryChildren' -Risk 'Medium' -Category 'NuGetCache' `
            -Default $false -RequiresAdmin $false -UseAgeFilter $false -ProcessNames @('dotnet','devenv','MSBuild','nuget','VBCSCompiler') `
            -Recommendation '通过官方 NuGet 缓存机制处理；所有包都可能在下次构建时重新下载。' -MigrationSupport 'Automatic' `
            -Description 'NuGet 全局包缓存。支持经过验证的非 C 盘 NTFS 迁移。'

        $extensionsRoot = Join-Path $env:USERPROFILE '.vscode\extensions'
        if (Test-Path -LiteralPath $extensionsRoot -PathType Container) {
            foreach ($temporaryExtension in Get-ChildItem -LiteralPath $extensionsRoot -Directory -Force -ErrorAction SilentlyContinue | Where-Object {
                -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -and
                ($_.Name -match '^\.[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' -or $_.Name -match '\.vsctmp$')
            }) {
                $targets += New-CPanTarget -Id ('VSCodeExtensionTemp:' + ($temporaryExtension.Name -replace '[^A-Za-z0-9]+','')) `
                    -Name ('VS Code failed extension install: ' + $temporaryExtension.Name) -Path $temporaryExtension.FullName -Kind 'DirectorySelf' `
                    -Risk 'Low' -Category 'VSCodeCache' -Default $false -RequiresAdmin $false -UseAgeFilter $false -ProcessNames @('Code') `
                    -Recommendation 'Close VS Code first. Only UUID staging directories and *.vsctmp are targeted; installed extensions and .obsolete are preserved.' `
                    -Description 'Exact failed-extension-install staging directory pattern.'
            }
        }
    }
    return $targets
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
        -RequiresAdmin $true `
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

    $targets += New-CPanTarget `
        -Id 'WindowsMinidump' `
        -Name 'Windows minidump files' `
        -Path "$systemDrive\Windows\Minidump" `
        -Kind 'DirectoryChildren' `
        -Risk 'Low' `
        -Category 'CrashDumps' `
        -Default $true `
        -RequiresAdmin $true `
        -UseAgeFilter $true `
        -Description 'Windows system crash minidumps older than the selected age.'

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

        $localCacheDefinitions = @(
            [pscustomobject]@{ Id = 'D3DSCache'; Name = 'Direct3D shader cache'; Relative = 'D3DSCache'; Category = 'GraphicsCache' },
            [pscustomobject]@{ Id = 'NvidiaDxCache'; Name = 'NVIDIA DirectX shader cache'; Relative = 'NVIDIA\DXCache'; Category = 'GraphicsCache' },
            [pscustomobject]@{ Id = 'NvidiaGlCache'; Name = 'NVIDIA OpenGL shader cache'; Relative = 'NVIDIA\GLCache'; Category = 'GraphicsCache' },
            [pscustomobject]@{ Id = 'AmdDxCache'; Name = 'AMD DirectX shader cache'; Relative = 'AMD\DxCache'; Category = 'GraphicsCache' },
            [pscustomobject]@{ Id = 'RemoteDesktopCache'; Name = 'Remote Desktop bitmap cache'; Relative = 'Microsoft\Terminal Server Client\Cache'; Category = 'RemoteDesktopCache' }
        )

        foreach ($definition in $localCacheDefinitions) {
            $targets += New-CPanTarget `
                -Id $definition.Id `
                -Name $definition.Name `
                -Path (Join-Path $env:LOCALAPPDATA $definition.Relative) `
                -Kind 'DirectoryChildren' `
                -Risk 'Low' `
                -Category $definition.Category `
                -Default $true `
                -RequiresAdmin $false `
                -UseAgeFilter $false `
                -Description 'Rebuildable application or graphics cache. User profiles, cookies, bookmarks, and saved credentials are not targeted.'
        }
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
        -Description 'Visual Studio installer state and packages. Removing children can break repair, modify, uninstall, workload detection, or offline maintenance.'

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
        'BrowserCache',
        'BrowserOfflineCache',
        'VSCodeCache',
        'NpmCache',
        'JianyingCache',
        'WpsCache',
        'QoderCache',
        'NuGetCache',
        'PlaywrightCache',
        'WXWorkCache',
        'GraphicsCache',
        'RemoteDesktopCache',
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
    $targets += @(Get-CPanBrowserCacheTargets)
    $targets += @(Get-CPanApplicationCacheTargets)
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
        # Visual Studio setup state is only available through an exact, explicit include.
        return $targets | Where-Object { $_.Category -ne 'VisualStudioPackageCache' }
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
        $item = Get-Item -LiteralPath $Target.Path -Force -ErrorAction SilentlyContinue
        if ($item -and -not ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            return @($item)
        }
        return @()
    }

    if ($Target.Kind -ne 'DirectoryChildren') {
        return @()
    }

    $items = @(Get-ChildItem -LiteralPath $Target.Path -Force -ErrorAction SilentlyContinue |
        Where-Object { -not ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) })
    if ($Target.UseAgeFilter) {
        $cutoff = if ($MinimumAgeHours -ge 0) {
            (Get-Date).AddHours(-1 * $MinimumAgeHours)
        } else {
            (Get-Date).AddDays(-1 * [Math]::Max(0, $MinimumAgeDays))
        }
        $agedItems = @()
        foreach ($item in $items) {
            if ($item.LastWriteTime -gt $cutoff) {
                continue
            }

            if ($item.PSIsContainer) {
                try {
                    $recentChild = Get-ChildItem -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop |
                        Where-Object {
                            -not ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -and
                            $_.LastWriteTime -gt $cutoff
                        } |
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

    return Measure-CPanDirectoryByPath -Path $Item.FullName -MaxScanItems $MaxScanItems
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
    $sizeOnDiskBytes = [int64] 0
    $count = [int64] 0
    $truncated = $false
    $notes = @()

    if ($exists -and -not $Target.UseAgeFilter -and $Target.Kind -in @('DirectoryChildren','DirectorySelf','FileSelf')) {
        $diskMeasurement = Measure-CPanPathSizeOnDisk -Path $Target.Path -MaxScanItems $MaxScanItems
        $bytes = [int64] $diskMeasurement.FileSizeBytes
        $sizeOnDiskBytes = [int64] $diskMeasurement.SizeOnDiskBytes
        $count = [int64] $diskMeasurement.FileCount
        $truncated = [bool] $diskMeasurement.Truncated
    } elseif ($exists -and $Target.Kind -eq 'RecycleBin') {
        $measurement = Measure-CPanDirectoryByPath -Path $Target.Path -MaxScanItems $MaxScanItems
        $bytes = $measurement.Bytes
        $sizeOnDiskBytes = $measurement.Bytes
        $count = $measurement.Count
        $truncated = $measurement.Truncated
    } elseif ($exists) {
        $candidates = @(Get-CPanCandidateItems -Target $Target -MinimumAgeDays $MinimumAgeDays -MinimumAgeHours $MinimumAgeHours)
        foreach ($candidate in $candidates) {
            $measurement = Measure-CPanFileSystemItem -Item $candidate -MaxScanItems $MaxScanItems
            $bytes += $measurement.Bytes
            $sizeOnDiskBytes += $measurement.Bytes
            $count += $measurement.Count
            if ($measurement.Truncated) {
                $truncated = $true
            }
        }
    }

    if ($truncated) {
        $notes += "Size estimate stopped after $MaxScanItems scanned items."
    }

    $blockers = @(Get-CPanProcessBlockers -ProcessNames $Target.ProcessNames)
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
        SizeOnDiskBytes = $sizeOnDiskBytes
        ReclaimableBytes = $sizeOnDiskBytes
        ItemCount = $count
        Notes = ($notes -join ' ')
        Description = $Target.Description
        Recommendation = $Target.Recommendation
        ProcessBlockers = ($blockers -join '; ')
        MigrationSupport = $Target.MigrationSupport
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

    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push((ConvertTo-CPanFullPath $Path))
    while ($pending.Count -gt 0 -and -not $truncated) {
        $current = $pending.Pop()
        foreach ($child in Get-ChildItem -LiteralPath $current -Force -ErrorAction SilentlyContinue) {
            if ($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
            $count++
            if ($child -is [System.IO.FileInfo]) { $bytes += [int64] $child.Length }
            elseif ($child.PSIsContainer) { $pending.Push($child.FullName) }
            if ($count -ge $MaxScanItems) { $truncated = $true; break }
        }
    }

    return [pscustomobject]@{ Bytes = $bytes; Count = $count; Truncated = $truncated }
}

function ConvertFrom-CPanDiskUsageCsv {
    param([string[]] $Lines)

    $records = @()
    foreach ($line in @($Lines)) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line -notmatch '^\s*(\d+),(\d+),(\d+),(.+)$') {
            continue
        }
        $records += [pscustomobject]@{
            SizeOnDiskBytes = [int64] $Matches[1]
            FileSizeBytes = [int64] $Matches[2]
            FileCount = [int64] $Matches[3]
            Path = $Matches[4].Trim().Trim('"')
        }
    }
    return $records
}

function Measure-CPanPathSizeOnDisk {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [int] $MaxScanItems = 100000
    )

    $fullPath = ConvertTo-CPanFullPath $Path
    if (-not $fullPath -or -not (Test-Path -LiteralPath $fullPath)) {
        return [pscustomobject]@{ SizeOnDiskBytes=[int64]0; FileSizeBytes=[int64]0; FileCount=[int64]0; Method='Missing'; Truncated=$false }
    }

    $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction SilentlyContinue
    if (-not $item -or ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        return [pscustomobject]@{ SizeOnDiskBytes=[int64]0; FileSizeBytes=[int64]0; FileCount=[int64]0; Method='ReparsePointRejected'; Truncated=$false }
    }

    $diskUsage = Get-Command diskusage.exe -ErrorAction SilentlyContinue
    if ($diskUsage) {
        try {
            $lines = @(& $diskUsage.Source /c /d:0 /g:0x3 $fullPath 2>$null)
            $record = @(ConvertFrom-CPanDiskUsageCsv -Lines $lines | Where-Object {
                [string]::Equals((ConvertTo-CPanFullPath $_.Path), $fullPath, [StringComparison]::OrdinalIgnoreCase)
            } | Select-Object -First 1)
            if ($record.Count -gt 0) {
                return [pscustomobject]@{
                    SizeOnDiskBytes = [int64] $record[0].SizeOnDiskBytes
                    FileSizeBytes = [int64] $record[0].FileSizeBytes
                    FileCount = [int64] $record[0].FileCount
                    Method = 'diskusage.exe'
                    Truncated = $false
                }
            }
        } catch {
            # Continue with the bounded .NET fallback.
        }
    }

    if ($item -is [System.IO.FileInfo]) {
        return [pscustomobject]@{ SizeOnDiskBytes=[int64]$item.Length; FileSizeBytes=[int64]$item.Length; FileCount=[int64]1; Method='.NET bounded fallback'; Truncated=$false }
    }
    $fallback = Measure-CPanDirectoryByPath -Path $fullPath -MaxScanItems $MaxScanItems
    return [pscustomobject]@{
        SizeOnDiskBytes = [int64] $fallback.Bytes
        FileSizeBytes = [int64] $fallback.Bytes
        FileCount = [int64] $fallback.Count
        Method = '.NET bounded fallback'
        Truncated = [bool] $fallback.Truncated
    }
}

function New-CPanStorageAnalysisItem {
    param(
        [Parameter(Mandatory = $true)] [string] $Id,
        [Parameter(Mandatory = $true)] [string] $Name,
        [Parameter(Mandatory = $true)] [string] $Path,
        [string] $Risk = 'Low',
        [string] $Recommendation = '',
        [string] $MigrationSupport = 'None',
        [string[]] $ProcessNames = @(),
        [int64] $ReclaimableBytes = 0,
        [int] $MaxScanItems = 100000
    )

    $measurement = Measure-CPanPathSizeOnDisk -Path $Path -MaxScanItems $MaxScanItems
    $blockers = @(Get-CPanProcessBlockers -ProcessNames $ProcessNames)
    $status = if ($measurement.Method -eq 'Missing') { 'Missing' } elseif ($measurement.Method -eq 'ReparsePointRejected') { 'SkippedReparsePoint' } elseif ($blockers.Count -gt 0) { 'BlockedByProcess' } else { 'Analyzed' }
    return [pscustomobject]@{
        Id = $Id
        Name = $Name
        Category = 'StorageAnalysis'
        Risk = $Risk
        Mode = 'ReadOnly'
        Status = $status
        Exists = $measurement.Method -ne 'Missing'
        EstimatedBytes = [int64] $measurement.FileSizeBytes
        EstimatedMB = [Math]::Round(($measurement.SizeOnDiskBytes / 1MB), 2)
        SizeOnDiskBytes = [int64] $measurement.SizeOnDiskBytes
        ReclaimableBytes = [Math]::Min([int64]$measurement.SizeOnDiskBytes, [Math]::Max([int64]0, $ReclaimableBytes))
        ItemCount = [int64] $measurement.FileCount
        RemovedCount = [int64] 0
        Path = ConvertTo-CPanFullPath $Path
        Message = "只读分析；方法=$($measurement.Method)" + $(if ($measurement.Truncated) { '; 回退扫描达到数量上限' } else { '' })
        Recommendation = $Recommendation
        ProcessBlockers = ($blockers -join '; ')
        MigrationSupport = $MigrationSupport
    }
}

function Get-CPanStorageAnalysis {
    param(
        [ValidateSet('Profile', 'Applications', 'All')] [string] $AnalysisScope = 'Profile',
        [int] $MaxScanItems = 100000
    )

    $items = @()
    $cleanupTargets = @(Get-CPanCleanerTarget -Include @('BrowserCache','BrowserOfflineCache','VSCodeCache','NpmCache','JianyingCache','WpsCache','QoderCache','NuGetCache','PlaywrightCache','WXWorkCache','Temp'))
    $targetSizes = @{}
    foreach ($target in $cleanupTargets) {
        $m = Measure-CPanPathSizeOnDisk -Path $target.Path -MaxScanItems $MaxScanItems
        $targetSizes[$target.Id] = [int64] $m.SizeOnDiskBytes
    }

    if ($AnalysisScope -eq 'Profile' -or $AnalysisScope -eq 'All') {
        $profileDefinitions = @()
        if ($env:LOCALAPPDATA) {
            $profileDefinitions += @(
                [pscustomobject]@{ Id='ChromeData'; Name='Google Chrome 用户数据'; Path=(Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data'); Match='Chrome'; Risk='Low'; Processes=@('chrome'); Recommendation='可清理所有配置的精确缓存白名单；不触碰账号数据。'; Migration='Guidance' },
                [pscustomobject]@{ Id='EdgeData'; Name='Microsoft Edge 用户数据'; Path=(Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data'); Match='Edge'; Risk='Low'; Processes=@('msedge'); Recommendation='可清理所有配置的精确缓存白名单。'; Migration='Guidance' },
                [pscustomobject]@{ Id='JianyingData'; Name='剪映用户数据'; Path=(Join-Path $env:LOCALAPPDATA 'JianyingPro'); Match='Jianying'; Risk='Low'; Processes=@('JianyingPro'); Recommendation='只清理 Cache 和日志；草稿、工程与安装文件保留。'; Migration='Guidance' },
                [pscustomobject]@{ Id='DockerData'; Name='Docker Desktop 数据'; Path=(Join-Path $env:LOCALAPPDATA 'Docker'); Match='NoAutomaticMatch'; Risk='High'; Processes=@('Docker Desktop','com.docker.backend'); Recommendation='仅在 Docker Settings → Resources → Advanced 修改 Disk image location。'; Migration='Guidance' },
                [pscustomobject]@{ Id='NpmData'; Name='npm 缓存'; Path=(Join-Path $env:LOCALAPPDATA 'npm-cache'); Match='Npm'; Risk='Low'; Processes=@('node'); Recommendation='缓存可重建；后续安装会重新下载。'; Migration='None' },
                [pscustomobject]@{ Id='PlaywrightData'; Name='Playwright 浏览器包'; Path=(Join-Path $env:LOCALAPPDATA 'ms-playwright'); Match='Playwright'; Risk='Medium'; Processes=@('node','chrome','msedge'); Recommendation='清理后测试会重新下载浏览器包。'; Migration='None' }
            )
        }
        if ($env:APPDATA) {
            $profileDefinitions += @(
                [pscustomobject]@{ Id='QoderData'; Name='Qoder 用户数据'; Path=(Join-Path $env:APPDATA 'Qoder'); Match='Qoder'; Risk='Medium'; Processes=@('Qoder'); Recommendation='只处理 SharedClientCache\index 和 cache；设置、聊天、历史保留。'; Migration='Guidance' },
                [pscustomobject]@{ Id='TencentData'; Name='Tencent / 企业微信数据'; Path=(Join-Path $env:APPDATA 'Tencent'); Match='WXWork|XWeChat'; Risk='Medium'; Processes=@('WXWork','xwechat','WeChat'); Recommendation='仅处理升级包和明确日志；聊天记录保留。'; Migration='Guidance' },
                [pscustomobject]@{ Id='VSCodeData'; Name='VS Code 用户数据'; Path=(Join-Path $env:APPDATA 'Code'); Match='VSCode'; Risk='Low'; Processes=@('Code'); Recommendation='只处理 VSIX 下载缓存和崩溃报告；当前扩展保留。'; Migration='Guidance' },
                [pscustomobject]@{ Id='WpsData'; Name='WPS 用户数据'; Path=(Join-Path $env:APPDATA 'kingsoft'); Match='Wps'; Risk='Low'; Processes=@('wps','wpp','et','wpspdf'); Recommendation='只清理下载缓存和日志；addons 与文档保留。'; Migration='Guidance' }
            )
        }
        if ($env:USERPROFILE) {
            $profileDefinitions += @(
                [pscustomobject]@{ Id='NuGetData'; Name='NuGet 全局包'; Path=(Join-Path $env:USERPROFILE '.nuget\packages'); Match='NuGetGlobal|NuGetV3|NuGetPlugins'; Risk='Medium'; Processes=@('dotnet','devenv','MSBuild','nuget'); Recommendation='可用内置事务流程迁移到非 C 盘本地 NTFS 空目录。'; Migration='Automatic' },
                [pscustomobject]@{ Id='DocumentsData'; Name='Documents（受保护）'; Path=(Join-Path $env:USERPROFILE 'Documents'); Match='NoAutomaticMatch'; Risk='High'; Processes=@(); Recommendation='文档、聊天和项目不自动删除或迁移；请按应用设置逐项审查。'; Migration='Guidance' },
                [pscustomobject]@{ Id='DownloadsData'; Name='Downloads（逐文件审查）'; Path=(Join-Path $env:USERPROFILE 'Downloads'); Match='NoAutomaticMatch'; Risk='High'; Processes=@(); Recommendation='只列出直接文件，默认不选；文件变化时跳过。'; Migration='None' },
                [pscustomobject]@{ Id='CodexData'; Name='Codex 用户数据（受保护）'; Path=(Join-Path $env:USERPROFILE '.codex'); Match='NoAutomaticMatch'; Risk='High'; Processes=@('Codex'); Recommendation='不自动清理或迁移当前 Codex 数据。'; Migration='Guidance' }
            )
        }

        foreach ($definition in $profileDefinitions) {
            $reclaimable = [int64] 0
            foreach ($target in $cleanupTargets | Where-Object { $_.Id -match $definition.Match -or $_.Category -match $definition.Match }) {
                $reclaimable += [int64] $targetSizes[$target.Id]
            }
            $items += New-CPanStorageAnalysisItem -Id $definition.Id -Name $definition.Name -Path $definition.Path -Risk $definition.Risk `
                -Recommendation $definition.Recommendation -MigrationSupport $definition.Migration -ProcessNames $definition.Processes `
                -ReclaimableBytes $reclaimable -MaxScanItems $MaxScanItems
        }
    }

    if ($AnalysisScope -eq 'Applications' -or $AnalysisScope -eq 'All') {
        $systemDrive = Get-CPanSystemDrive
        $applicationDefinitions = @(
            [pscustomobject]@{ Id='VisualStudio'; Name='Visual Studio 安装'; Path="$systemDrive\Program Files\Microsoft Visual Studio"; Risk='High'; Recommendation='打开 Visual Studio Installer 修改、卸载或重装；现有安装不能原地改盘符。'; Migration='Guidance'; Processes=@('devenv','MSBuild') },
            [pscustomobject]@{ Id='VisualStudioX86'; Name='Visual Studio / SDK (x86)'; Path="${systemDrive}\Program Files (x86)\Microsoft Visual Studio"; Risk='High'; Recommendation='只通过 Visual Studio Installer 管理。'; Migration='Guidance'; Processes=@('devenv','MSBuild') },
            [pscustomobject]@{ Id='WindowsKits'; Name='Windows Kits'; Path="${systemDrive}\Program Files (x86)\Windows Kits"; Risk='High'; Recommendation='禁止手工删除；通过安装器修改工作负载。'; Migration='None'; Processes=@('devenv','MSBuild') },
            [pscustomobject]@{ Id='VsPackageCache'; Name='Visual Studio Package Cache（受保护）'; Path="$systemDrive\ProgramData\Package Cache"; Risk='High'; Recommendation='禁止整目录删除；仅使用工具现有的精确 Include 功能。'; Migration='None'; Processes=@('vs_installer','setup') },
            [pscustomobject]@{ Id='WindowsApps'; Name='WindowsApps（受保护）'; Path="$systemDrive\Program Files\WindowsApps"; Risk='High'; Recommendation='禁止手工删除；通过“已安装的应用”移动或卸载。'; Migration='Guidance'; Processes=@() }
        )
        foreach ($definition in $applicationDefinitions) {
            $items += New-CPanStorageAnalysisItem -Id $definition.Id -Name $definition.Name -Path $definition.Path -Risk $definition.Risk `
                -Recommendation $definition.Recommendation -MigrationSupport $definition.Migration -ProcessNames $definition.Processes `
                -ReclaimableBytes 0 -MaxScanItems $MaxScanItems
        }
        $packagesRoot = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Packages' } else { $null }
        if ($packagesRoot -and (Test-Path -LiteralPath $packagesRoot -PathType Container)) {
            foreach ($package in Get-ChildItem -LiteralPath $packagesRoot -Directory -Force -ErrorAction SilentlyContinue | Where-Object {
                -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -and (Test-Path -LiteralPath (Join-Path $_.FullName 'LocalState\ext4.vhdx') -PathType Leaf)
            }) {
                $items += New-CPanStorageAnalysisItem -Id ('Wsl:' + $package.Name) -Name ('WSL: ' + $package.Name) -Path (Join-Path $package.FullName 'LocalState') -Risk 'High' `
                    -Recommendation '仅提供官方 export/import 向导；验证备份前不注销原发行版。' -MigrationSupport 'Guidance' `
                    -ProcessNames @('wsl','wslservice','vmmemWSL') -ReclaimableBytes 0 -MaxScanItems $MaxScanItems
            }
        }
    }
    return $items
}

function ConvertTo-CPanDownloadIdentityToken {
    param([Parameter(Mandatory = $true)] [System.IO.FileInfo] $File)

    $identity = [pscustomobject]@{
        Path = $File.FullName
        Length = [int64] $File.Length
        LastWriteTimeUtcTicks = [int64] $File.LastWriteTimeUtc.Ticks
    }
    $json = $identity | ConvertTo-Json -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    return [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+','-').Replace('/','_')
}

function ConvertFrom-CPanDownloadIdentityToken {
    param([Parameter(Mandatory = $true)] [string] $Token)

    $base64 = $Token.Replace('-','+').Replace('_','/')
    switch ($base64.Length % 4) {
        2 { $base64 += '==' }
        3 { $base64 += '=' }
    }
    try {
        return ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($base64)) | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Test-CPanDownloadFileSafety {
    param([Parameter(Mandatory = $true)] [string] $Path)

    if (-not $env:USERPROFILE) { return $false }
    $downloads = ConvertTo-CPanFullPath (Join-Path $env:USERPROFILE 'Downloads')
    $fullPath = ConvertTo-CPanFullPath $Path
    if (-not $downloads -or -not $fullPath -or -not [string]::Equals((Split-Path -Parent $fullPath), $downloads, [StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }
    if ([System.IO.Path]::GetExtension($fullPath).ToLowerInvariant() -notin @('.exe','.msi','.zip','.crdownload')) {
        return $false
    }
    $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction SilentlyContinue
    return $item -is [System.IO.FileInfo] -and -not ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
}

function Invoke-CPanDownloadReview {
    param(
        [Parameter(Mandatory = $true)] [pscustomobject] $Context,
        [string[]] $SelectedItemTokens = @(),
        [switch] $Apply
    )

    $downloads = if ($env:USERPROFILE) { Join-Path $env:USERPROFILE 'Downloads' } else { $null }
    if (-not $downloads -or -not (Test-Path -LiteralPath $downloads -PathType Container)) { return @() }
    $items = @()
    if (-not $Apply) {
        foreach ($file in Get-ChildItem -LiteralPath $downloads -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension.ToLowerInvariant() -in @('.exe','.msi','.zip','.crdownload') } |
            Sort-Object Length -Descending) {
            if ($file.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
            $sha = if ($file.Length -le 256MB) { (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash } else { 'DeferredUntilApply' }
            $signature = if ($file.Extension.ToLowerInvariant() -in @('.exe','.msi')) { Get-AuthenticodeSignature -LiteralPath $file.FullName -ErrorAction SilentlyContinue } else { $null }
            $publisher = if ($signature -and $signature.SignerCertificate) { $signature.SignerCertificate.Subject } elseif ($signature) { $signature.Status.ToString() } else { 'NotApplicable' }
            $items += [pscustomobject]@{
                Id = 'DownloadFile'
                Name = $file.Name
                Category = 'DownloadsReview'
                Risk = 'High'
                Mode = 'DryRun'
                Status = 'ReviewRequired'
                Exists = $true
                EstimatedBytes = [int64] $file.Length
                EstimatedMB = [Math]::Round(($file.Length / 1MB), 2)
                SizeOnDiskBytes = [int64] $file.Length
                ReclaimableBytes = [int64] $file.Length
                ItemCount = [int64] 1
                RemovedCount = [int64] 0
                Path = $file.FullName
                Message = "类型=$($file.Extension); 修改时间=$($file.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')); 发布者=$publisher; SHA256=$sha"
                Recommendation = '默认不选。确认文件不再需要后逐项勾选；永久删除前会再次校验路径、大小和修改时间。'
                ProcessBlockers = ''
                MigrationSupport = 'None'
                CanSelect = $true
                IdentityToken = ConvertTo-CPanDownloadIdentityToken -File $file
                Sha256 = $sha
                Publisher = $publisher
                LastWriteTime = $file.LastWriteTime.ToString('o')
                Extension = $file.Extension
            }
        }
        return $items
    }

    foreach ($token in @($SelectedItemTokens | Where-Object { $_ })) {
        $identity = ConvertFrom-CPanDownloadIdentityToken -Token $token
        $path = if ($identity) { [string] $identity.Path } else { '' }
        $status = 'ChangedSkipped'
        $message = '文件身份令牌无效或文件状态已变化，已跳过。'
        $bytes = [int64] 0
        $sha = ''
        if ($identity -and (Test-CPanDownloadFileSafety -Path $path)) {
            $file = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            if ($file -is [System.IO.FileInfo] -and [int64]$file.Length -eq [int64]$identity.Length -and [int64]$file.LastWriteTimeUtc.Ticks -eq [int64]$identity.LastWriteTimeUtcTicks) {
                $bytes = [int64] $file.Length
                $sha = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256 -ErrorAction Stop).Hash
                try {
                    Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
                    $status = 'Deleted'
                    $message = "已永久删除；执行前 SHA256=$sha"
                    Write-CPanLog -Context $Context -Level 'INFO' -Message "Deleted selected Downloads file: $($file.FullName); SHA256=$sha"
                } catch {
                    $status = 'Failed'
                    $message = $_.Exception.Message
                }
            }
        }
        $items += [pscustomobject]@{
            Id='DownloadFile'; Name=$(if ($path) { Split-Path -Leaf $path } else { 'InvalidToken' }); Category='DownloadsReview'; Risk='High'; Mode='Apply'; Status=$status; Exists=(Test-Path -LiteralPath $path -ErrorAction SilentlyContinue)
            EstimatedBytes=$bytes; EstimatedMB=[Math]::Round(($bytes/1MB),2); SizeOnDiskBytes=$bytes; ReclaimableBytes=$(if ($status -eq 'Deleted') {[int64]0} else {$bytes}); ItemCount=[int64]1; RemovedCount=$(if ($status -eq 'Deleted') {[int64]1} else {[int64]0})
            Path=$path; Message=$message; Recommendation='状态变化的文件不会删除。'; ProcessBlockers=''; MigrationSupport='None'; CanSelect=$false; IdentityToken=''; Sha256=$sha; Publisher=''; LastWriteTime=''; Extension=[IO.Path]::GetExtension($path)
        }
    }
    return $items
}

function Get-CPanNuGetMigrationStatePath {
    $root = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'CPanCleaner\migrations' } else { Join-Path ([IO.Path]::GetTempPath()) 'CPanCleaner\migrations' }
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    return Join-Path $root 'nuget-global-packages.json'
}

function Get-CPanNuGetMigrationState {
    $path = Get-CPanNuGetMigrationStatePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try { return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

function Test-CPanNuGetMigrationDestination {
    param([Parameter(Mandatory = $true)] [string] $DestinationPath)

    $destination = ConvertTo-CPanFullPath $DestinationPath
    if (-not $destination -or -not (Test-Path -LiteralPath $destination -PathType Container)) { throw '迁移目标必须是已经创建的空目录。' }
    $item = Get-Item -LiteralPath $destination -Force -ErrorAction Stop
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw '迁移目标不能是重解析点、符号链接或目录联接。' }
    if ((Get-ChildItem -LiteralPath $destination -Force -ErrorAction Stop | Select-Object -First 1)) { throw '迁移目标必须为空目录。' }
    $root = [IO.Path]::GetPathRoot($destination)
    if ([string]::Equals($root.TrimEnd('\'), (Get-CPanSystemDrive), [StringComparison]::OrdinalIgnoreCase)) { throw '迁移目标必须位于非 C 盘。' }
    $drive = New-Object IO.DriveInfo($root)
    if ($drive.DriveType -ne [IO.DriveType]::Fixed -or -not $drive.IsReady) { throw '迁移目标必须位于已就绪的本地固定磁盘。' }
    $volume = Get-Volume -DriveLetter $drive.Name.Substring(0,1) -ErrorAction SilentlyContinue
    if (-not $volume -or $volume.FileSystem -ne 'NTFS') { throw '迁移目标必须位于 NTFS 分区。' }
    return [pscustomobject]@{ Path=$destination; Drive=$drive }
}

function Copy-CPanDirectoryVerified {
    param([Parameter(Mandatory=$true)][string]$Source,[Parameter(Mandatory=$true)][string]$Destination)

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $null = & robocopy.exe $Source $Destination /E /COPY:DAT /DCOPY:DAT /XJ /R:1 /W:1 /NFL /NDL /NJH /NJS /NP
    if ($LASTEXITCODE -gt 7) { throw "robocopy 失败，退出代码 $LASTEXITCODE。" }
    $sourceMeasure = Measure-CPanDirectoryByPath -Path $Source -MaxScanItems 1000000
    $destinationMeasure = Measure-CPanDirectoryByPath -Path $Destination -MaxScanItems 1000000
    if ($sourceMeasure.Truncated -or $destinationMeasure.Truncated -or $destinationMeasure.Count -lt $sourceMeasure.Count -or $destinationMeasure.Bytes -lt $sourceMeasure.Bytes) {
        throw '迁移副本的文件数量或逻辑大小校验失败。'
    }
    $missingChecksums = @(Get-ChildItem -LiteralPath $Source -Filter '*.nupkg.sha512' -File -Recurse -ErrorAction SilentlyContinue | Where-Object {
        $relative = $_.FullName.Substring($Source.TrimEnd('\').Length).TrimStart('\')
        -not (Test-Path -LiteralPath (Join-Path $Destination $relative) -PathType Leaf)
    } | Select-Object -First 1)
    if ($missingChecksums.Count -gt 0) { throw 'NuGet 包校验文件复制不完整。' }
    return [pscustomobject]@{ SourceBytes=[int64]$sourceMeasure.Bytes; SourceCount=[int64]$sourceMeasure.Count; DestinationBytes=[int64]$destinationMeasure.Bytes; DestinationCount=[int64]$destinationMeasure.Count }
}

function Invoke-CPanNuGetMigration {
    param(
        [Parameter(Mandatory=$true)][pscustomobject]$Context,
        [ValidateSet('Preview','Prepare','RemoveSource','Rollback')][string]$MigrationOperation='Preview',
        [string]$DestinationPath,
        [switch]$Apply
    )

    $source = ConvertTo-CPanFullPath (Join-Path $env:USERPROFILE '.nuget\packages')
    $statePath = Get-CPanNuGetMigrationStatePath
    $state = Get-CPanNuGetMigrationState
    $blockers = @(Get-CPanProcessBlockers -ProcessNames @('dotnet','devenv','MSBuild','nuget','VBCSCompiler'))
    $status = 'Ready'
    $message = ''
    $destination = if ($DestinationPath) { ConvertTo-CPanFullPath $DestinationPath } elseif ($state) { [string]$state.Destination } else { '' }
    $sourceMeasure = Measure-CPanPathSizeOnDisk -Path $source -MaxScanItems 1000000

    if (-not $Apply) {
        if ($MigrationOperation -eq 'Prepare' -and $DestinationPath) {
            $validated = Test-CPanNuGetMigrationDestination -DestinationPath $DestinationPath
            if ($validated.Drive.AvailableFreeSpace -lt ($sourceMeasure.FileSizeBytes + 1GB)) { $status='InsufficientSpace'; $message='目标盘剩余空间不足（要求源逻辑大小再预留 1GB）。' }
            else { $message='预检通过；执行后将复制、校验并切换用户级 NUGET_PACKAGES，原缓存仍保留。' }
        } elseif ($MigrationOperation -eq 'RemoveSource') {
            $status = if ($state) { 'SeparateConfirmationRequired' } else { 'NoMigrationState' }
            $message = '仅在迁移副本和新进程解析均验证后，单独确认删除原缓存。'
        } elseif ($MigrationOperation -eq 'Rollback') {
            $status = if ($state) { 'RollbackAvailable' } else { 'NoMigrationState' }
            $message = '回滚会恢复原用户级配置；若原缓存已删除，会先复制回 C 盘。目标副本不会自动删除。'
        } else {
            $message = '选择非 C 盘本地 NTFS 空目录后执行迁移预检。'
        }
    } elseif ($blockers.Count -gt 0) {
        $status='BlockedByProcess'; $message='关闭 Visual Studio、dotnet、MSBuild、NuGet 相关进程后重试；程序不会自动结束它们。'
    } elseif ($MigrationOperation -eq 'Prepare') {
        $validated = Test-CPanNuGetMigrationDestination -DestinationPath $DestinationPath
        if ($validated.Drive.AvailableFreeSpace -lt ($sourceMeasure.FileSizeBytes + 1GB)) { throw '目标盘剩余空间不足（要求源逻辑大小再预留 1GB）。' }
        $previousUserValue = [Environment]::GetEnvironmentVariable('NUGET_PACKAGES','User')
        $stagingPath = $validated.Path + '.cpancleaner-staging-' + [guid]::NewGuid().ToString('N')
        $stagingRoot = [IO.Path]::GetPathRoot($stagingPath)
        if (-not [string]::Equals($stagingRoot, [IO.Path]::GetPathRoot($validated.Path), [StringComparison]::OrdinalIgnoreCase)) { throw '迁移暂存目录必须与最终目标位于同一分区。' }
        try {
            $verification = Copy-CPanDirectoryVerified -Source $source -Destination $stagingPath
            if ((Get-ChildItem -LiteralPath $validated.Path -Force -ErrorAction Stop | Select-Object -First 1)) { throw '最终目标在复制期间变为非空，拒绝提交。' }
            Remove-Item -LiteralPath $validated.Path -Force -ErrorAction Stop
            Move-Item -LiteralPath $stagingPath -Destination $validated.Path -ErrorAction Stop
        } catch {
            if (-not (Test-Path -LiteralPath $validated.Path)) { New-Item -ItemType Directory -Path $validated.Path -Force | Out-Null }
            $resolvedStage = ConvertTo-CPanFullPath $stagingPath
            $expectedStagePrefix = (ConvertTo-CPanFullPath $validated.Path) + '.cpancleaner-staging-'
            if ($resolvedStage -and $resolvedStage.StartsWith($expectedStagePrefix, [StringComparison]::OrdinalIgnoreCase) -and
                [string]::Equals((Split-Path -Parent $resolvedStage), (Split-Path -Parent $validated.Path), [StringComparison]::OrdinalIgnoreCase) -and
                (Test-Path -LiteralPath $resolvedStage -PathType Container)) {
                Remove-Item -LiteralPath $resolvedStage -Recurse -Force -ErrorAction SilentlyContinue
            }
            throw
        }
        $manifest = [pscustomobject]@{ Version='2.4.0'; Source=$source; Destination=$validated.Path; PreviousUserValue=$previousUserValue; SourceBytes=$verification.SourceBytes; SourceCount=$verification.SourceCount; CopyVerified=$true; SourceRemoved=$false; PreparedAt=(Get-Date).ToString('o') }
        $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $statePath -Encoding UTF8
        try {
            [Environment]::SetEnvironmentVariable('NUGET_PACKAGES',$validated.Path,'User')
            $oldProcessValue=$env:NUGET_PACKAGES
            $env:NUGET_PACKAGES=$validated.Path
            $resolved = (& dotnet nuget locals global-packages --list 2>&1 | Out-String).Trim()
            $env:NUGET_PACKAGES=$oldProcessValue
            if ($LASTEXITCODE -ne 0 -or $resolved -notlike "*$($validated.Path)*") { throw "新进程 NuGet 路径验证失败：$resolved" }
            $status='PreparedAndSwitched'; $message='复制和校验完成，用户级 NUGET_PACKAGES 已切换；原缓存仍保留，需使用单独功能确认删除。'
        } catch {
            [Environment]::SetEnvironmentVariable('NUGET_PACKAGES',$previousUserValue,'User')
            throw
        }
    } elseif ($MigrationOperation -eq 'RemoveSource') {
        if (-not $state -or -not $state.CopyVerified) { throw '找不到已验证的 NuGet 迁移状态。' }
        $expectedSource = ConvertTo-CPanFullPath (Join-Path $env:USERPROFILE '.nuget\packages')
        if (-not [string]::Equals((ConvertTo-CPanFullPath $state.Source),$expectedSource,[StringComparison]::OrdinalIgnoreCase)) { throw '迁移清单中的源路径不符合固定安全边界。' }
        $currentUserValue=[Environment]::GetEnvironmentVariable('NUGET_PACKAGES','User')
        if (-not [string]::Equals((ConvertTo-CPanFullPath $currentUserValue),(ConvertTo-CPanFullPath $state.Destination),[StringComparison]::OrdinalIgnoreCase)) { throw '当前用户级 NUGET_PACKAGES 与迁移清单不一致。' }
        $verification = Copy-CPanDirectoryVerified -Source $state.Source -Destination $state.Destination
        $target = New-CPanTarget -Id 'NuGetMigrationSource' -Name 'NuGet original global packages' -Path $state.Source -Kind 'DirectoryChildren' -Risk 'Medium' -Category 'NuGetMigration' -UseAgeFilter $false
        foreach ($candidate in @(Get-CPanCandidateItems -Target $target)) { $removed=Remove-CPanSafeItem -Item $candidate -AllowedRoot $state.Source -Context $Context; if (-not $removed.Removed) { throw "无法删除原缓存：$($removed.Error)" } }
        $state.SourceRemoved=$true; $state | Add-Member -NotePropertyName SourceRemovedAt -NotePropertyValue (Get-Date).ToString('o') -Force; $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $statePath -Encoding UTF8
        $status='SourceRemoved'; $message='原 NuGet 缓存已删除；目标副本和回滚清单已保留。'
    } elseif ($MigrationOperation -eq 'Rollback') {
        if (-not $state) { throw '找不到 NuGet 迁移状态。' }
        if ($state.SourceRemoved) {
            $systemDriveInfo=New-Object IO.DriveInfo((Get-CPanSystemDrive)+'\')
            if ($systemDriveInfo.AvailableFreeSpace -lt ([int64]$state.SourceBytes + 1GB)) { throw 'C 盘空间不足，无法安全复制回原缓存。' }
            Copy-CPanDirectoryVerified -Source $state.Destination -Destination $state.Source | Out-Null
        }
        [Environment]::SetEnvironmentVariable('NUGET_PACKAGES',$state.PreviousUserValue,'User')
        $state | Add-Member -NotePropertyName RolledBackAt -NotePropertyValue (Get-Date).ToString('o') -Force; $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $statePath -Encoding UTF8
        $status='RolledBack'; $message='用户级 NuGet 路径已恢复；目标副本未删除，可人工确认后处理。'
    }

    return [pscustomobject]@{
        Id='NuGetPackagesMigration'; Name='NuGet 全局包迁移'; Category='Migration'; Risk='Medium'; Mode=$(if($Apply){'Apply'}else{'DryRun'}); Status=$status; Exists=(Test-Path -LiteralPath $source)
        EstimatedBytes=[int64]$sourceMeasure.FileSizeBytes; EstimatedMB=[Math]::Round(($sourceMeasure.SizeOnDiskBytes/1MB),2); SizeOnDiskBytes=[int64]$sourceMeasure.SizeOnDiskBytes; ReclaimableBytes=$(if($MigrationOperation -eq 'RemoveSource'){[int64]$sourceMeasure.SizeOnDiskBytes}else{[int64]0})
        ItemCount=[int64]$sourceMeasure.FileCount; RemovedCount=[int64]0; Path=$(if($destination){$destination}else{$source}); Message=$message; Recommendation='迁移 Prepare 不删除源；RemoveSource 和 Rollback 分开确认。'; ProcessBlockers=($blockers -join '; '); MigrationSupport='Automatic'; StatePath=$statePath
    }
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

function Get-CPanServiceControlSnapshot {
    param(
        [string[]] $Name = @('wuauserv', 'UsoSvc', 'DoSvc', 'bits', 'WaaSMedicSvc')
    )

    foreach ($serviceName in $Name) {
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if ($service) {
            [pscustomobject]@{
                Name = $service.Name
                DisplayName = $service.DisplayName
                Status = $service.Status.ToString()
                StartType = $service.StartType.ToString()
            }
        } else {
            [pscustomobject]@{
                Name = $serviceName
                DisplayName = ''
                Status = 'Missing'
                StartType = ''
            }
        }
    }
}

function Set-CPanRegistryDWord {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [int] $Value,

        [Parameter(Mandatory = $true)]
        [pscustomobject] $Context
    )

    try {
        $nativePath = $Path.Replace('HKLM:\', 'HKLM\')
        $output = & reg.exe add $nativePath /v $Name /t REG_DWORD /d $Value /f 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw (($output | Out-String).Trim())
        }
        Write-CPanLog -Context $Context -Level 'INFO' -Message "Set registry policy $Path\$Name=$Value."
        return New-CPanDiagnosticRecord -Type 'WindowsUpdatePolicy' -Severity 'Info' -Name $Name -Message 'Policy value was set.' -Detail "$Path\$Name=$Value"
    } catch {
        Write-CPanLog -Context $Context -Level 'WARN' -Message "Could not set registry policy $Path\${Name}: $($_.Exception.Message)"
        return New-CPanDiagnosticRecord -Type 'WindowsUpdatePolicy' -Severity 'Warning' -Name $Name -Message 'Policy value could not be set.' -Detail $_.Exception.Message
    }
}

function Invoke-CPanScCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string[]] $Arguments,

        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [string] $Message,

        [Parameter(Mandatory = $true)]
        [pscustomobject] $Context
    )

    try {
        $output = & sc.exe @Arguments 2>&1
        $detail = ($output | Out-String).Trim()
        $severity = if ($LASTEXITCODE -eq 0) { 'Info' } else { 'Warning' }
        Write-CPanLog -Context $Context -Level ($(if ($LASTEXITCODE -eq 0) { 'INFO' } else { 'WARN' })) -Message "$Message $detail"
        return New-CPanDiagnosticRecord -Type 'WindowsUpdateService' -Severity $severity -Name $Name -Message $Message -Detail $detail
    } catch {
        Write-CPanLog -Context $Context -Level 'WARN' -Message "${Message}: $($_.Exception.Message)"
        return New-CPanDiagnosticRecord -Type 'WindowsUpdateService' -Severity 'Warning' -Name $Name -Message $Message -Detail $_.Exception.Message
    }
}

function Disable-CPanWindowsUpdateTask {
    param(
        [Parameter(Mandatory = $true)]
        [string] $TaskPath,

        [Parameter(Mandatory = $true)]
        [string] $TaskName,

        [Parameter(Mandatory = $true)]
        [pscustomobject] $Context
    )

    $displayName = "$TaskPath$TaskName"
    try {
        $output = & schtasks.exe /Change /TN $displayName /Disable 2>&1
        $detail = ($output | Out-String).Trim()
        $severity = if ($LASTEXITCODE -eq 0) { 'Info' } else { 'Warning' }
        Write-CPanLog -Context $Context -Level ($(if ($LASTEXITCODE -eq 0) { 'INFO' } else { 'WARN' })) -Message "Scheduled task disable result for ${displayName}: $detail"
        return New-CPanDiagnosticRecord -Type 'WindowsUpdateTask' -Severity $severity -Name $displayName -Message 'Scheduled task disable was requested.' -Detail $detail
    } catch {
        Write-CPanLog -Context $Context -Level 'WARN' -Message "Could not disable scheduled task ${displayName}: $($_.Exception.Message)"
        return New-CPanDiagnosticRecord -Type 'WindowsUpdateTask' -Severity 'Warning' -Name $displayName -Message 'Scheduled task could not be disabled.' -Detail $_.Exception.Message
    }
}

function Invoke-CPanBitsReset {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Context
    )

    try {
        $output = & bitsadmin.exe /reset /allusers 2>&1
        $detail = ($output | Out-String).Trim()
        $severity = if ($LASTEXITCODE -eq 0) { 'Info' } else { 'Warning' }
        Write-CPanLog -Context $Context -Level ($(if ($LASTEXITCODE -eq 0) { 'INFO' } else { 'WARN' })) -Message "BITS reset result: $detail"
        return New-CPanDiagnosticRecord -Type 'WindowsUpdateBits' -Severity $severity -Name 'BITS' -Message 'BITS jobs were reset for all users.' -Detail $detail
    } catch {
        Write-CPanLog -Context $Context -Level 'WARN' -Message "Could not reset BITS jobs: $($_.Exception.Message)"
        return New-CPanDiagnosticRecord -Type 'WindowsUpdateBits' -Severity 'Warning' -Name 'BITS' -Message 'BITS jobs could not be reset.' -Detail $_.Exception.Message
    }
}

function Set-CPanServiceStartRegistry {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ServiceName,

        [int] $Start = 4,

        [Parameter(Mandatory = $true)]
        [pscustomobject] $Context
    )

    $keyPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName"
    if (-not (Test-Path -LiteralPath $keyPath)) {
        return New-CPanDiagnosticRecord -Type 'WindowsUpdateService' -Severity 'Warning' -Name $ServiceName -Message 'Service registry key was not found.' -Detail $keyPath
    }

    try {
        New-ItemProperty -LiteralPath $keyPath -Name 'Start' -Value $Start -PropertyType DWord -Force | Out-Null
        if ($ServiceName -eq 'UsoSvc' -or $ServiceName -eq 'DoSvc') {
            New-ItemProperty -LiteralPath $keyPath -Name 'DelayedAutoStart' -Value 0 -PropertyType DWord -Force | Out-Null
        }
        Write-CPanLog -Context $Context -Level 'INFO' -Message "Set service registry $ServiceName Start=$Start."
        return New-CPanDiagnosticRecord -Type 'WindowsUpdateService' -Severity 'Info' -Name $ServiceName -Message 'Service registry start value was set.' -Detail "Start=$Start"
    } catch {
        Write-CPanLog -Context $Context -Level 'WARN' -Message "Could not set service registry ${ServiceName}: $($_.Exception.Message)"
        return New-CPanDiagnosticRecord -Type 'WindowsUpdateService' -Severity 'Warning' -Name $ServiceName -Message 'Service registry start value could not be set.' -Detail $_.Exception.Message
    }
}

function Invoke-CPanSystemWindowsUpdateHardening {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Context
    )

    $logDirectory = Split-Path -Parent $Context.LogPath
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $scriptPath = Join-Path $logDirectory "wu-system-hardening-$stamp.ps1"
    $resultPath = Join-Path $logDirectory "wu-system-hardening-$stamp.json"
    $taskName = "CPanCleanerWindowsUpdateHardening-$stamp"
    $escapedResultPath = $resultPath.Replace('\', '\\')

    $script = @"
`$ErrorActionPreference = 'Continue'
`$results = @()
function Add-Result {
    param([string]`$Type,[string]`$Name,[string]`$Status,[string]`$Detail='')
    `$script:results += [pscustomobject]@{ Time = (Get-Date).ToString('s'); Type = `$Type; Name = `$Name; Status = `$Status; Detail = `$Detail }
}
foreach (`$svc in @('wuauserv','UsoSvc','DoSvc','WaaSMedicSvc')) {
    try {
        reg.exe add "HKLM\SYSTEM\CurrentControlSet\Services\`$svc" /v Start /t REG_DWORD /d 4 /f | Out-Null
        if (`$svc -eq 'UsoSvc' -or `$svc -eq 'DoSvc') {
            reg.exe add "HKLM\SYSTEM\CurrentControlSet\Services\`$svc" /v DelayedAutoStart /t REG_DWORD /d 0 /f | Out-Null
        }
        Add-Result -Type 'ServiceRegistry' -Name `$svc -Status 'Start=4'
    } catch { Add-Result -Type 'ServiceRegistry' -Name `$svc -Status 'Failed' -Detail `$_.Exception.Message }
}
foreach (`$svc in @('wuauserv','UsoSvc','DoSvc','WaaSMedicSvc')) {
    try {
        `$out = & sc.exe stop `$svc 2>&1 | Out-String
        Add-Result -Type 'ServiceStop' -Name `$svc -Status 'Requested' -Detail `$out.Trim()
    } catch { Add-Result -Type 'ServiceStop' -Name `$svc -Status 'Failed' -Detail `$_.Exception.Message }
}
try {
    `$bits = & bitsadmin.exe /reset /allusers 2>&1 | Out-String
    Add-Result -Type 'BITS' -Name 'reset' -Status 'Requested' -Detail `$bits.Trim()
} catch { Add-Result -Type 'BITS' -Name 'reset' -Status 'Failed' -Detail `$_.Exception.Message }
`$tasks = @(
    @{Path='\Microsoft\Windows\WindowsUpdate\'; Name='Scheduled Start'},
    @{Path='\Microsoft\Windows\WindowsUpdate\'; Name='Refresh Group Policy Cache'},
    @{Path='\Microsoft\Windows\UpdateOrchestrator\'; Name='Report policies'},
    @{Path='\Microsoft\Windows\UpdateOrchestrator\'; Name='Schedule Maintenance Work'},
    @{Path='\Microsoft\Windows\UpdateOrchestrator\'; Name='Schedule Scan'},
    @{Path='\Microsoft\Windows\UpdateOrchestrator\'; Name='Schedule Scan Static Task'},
    @{Path='\Microsoft\Windows\UpdateOrchestrator\'; Name='Schedule Wake To Work'},
    @{Path='\Microsoft\Windows\UpdateOrchestrator\'; Name='Schedule Work'},
    @{Path='\Microsoft\Windows\UpdateOrchestrator\'; Name='Start Oobe Expedite Work'},
    @{Path='\Microsoft\Windows\UpdateOrchestrator\'; Name='StartOobeAppsScan'},
    @{Path='\Microsoft\Windows\UpdateOrchestrator\'; Name='StartOobeAppsScan_LicenseAccepted'},
    @{Path='\Microsoft\Windows\UpdateOrchestrator\'; Name='StartOobeAppsScanAfterUpdate'},
    @{Path='\Microsoft\Windows\UpdateOrchestrator\'; Name='UIEOrchestrator'},
    @{Path='\Microsoft\Windows\UpdateOrchestrator\'; Name='USO_UxBroker'},
    @{Path='\Microsoft\Windows\UpdateOrchestrator\'; Name='UUS Failover Task'},
    @{Path='\Microsoft\Windows\WaaSMedic\'; Name='DeferredWork'},
    @{Path='\Microsoft\Windows\WaaSMedic\'; Name='MaintenanceWork'},
    @{Path='\Microsoft\Windows\WaaSMedic\'; Name='PerformRemediation'}
)
foreach (`$task in `$tasks) {
    `$full = "`$(`$task.Path)`$(`$task.Name)"
    try {
        `$out = & schtasks.exe /Change /TN `$full /Disable 2>&1 | Out-String
        Add-Result -Type 'ScheduledTask' -Name `$full -Status ("SchtasksExit=`$LASTEXITCODE") -Detail `$out.Trim()
    } catch { Add-Result -Type 'ScheduledTask' -Name `$full -Status 'SchtasksFailed' -Detail `$_.Exception.Message }
}
foreach (`$svc in @('wuauserv','UsoSvc','DoSvc','WaaSMedicSvc','bits')) {
    try {
        `$s = Get-Service -Name `$svc -ErrorAction Stop
        Add-Result -Type 'ServiceFinal' -Name `$svc -Status `$s.Status.ToString() -Detail ('StartType=' + `$s.StartType.ToString())
    } catch { Add-Result -Type 'ServiceFinal' -Name `$svc -Status 'MissingOrFailed' -Detail `$_.Exception.Message }
}
`$results | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath '$escapedResultPath' -Encoding UTF8
"@

    try {
        Set-Content -LiteralPath $scriptPath -Value $script -Encoding UTF8
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
        $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(10)
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
        Start-ScheduledTask -TaskName $taskName

        $deadline = (Get-Date).AddMinutes(3)
        while ((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath $resultPath)) {
            Start-Sleep -Seconds 2
        }

        if (-not (Test-Path -LiteralPath $resultPath)) {
            return @(New-CPanDiagnosticRecord -Type 'WindowsUpdateSystemHardening' -Severity 'Warning' -Name 'SYSTEM task' -Message 'SYSTEM hardening task did not produce a result file before timeout.' -Detail $scriptPath)
        }

        $systemResultsJson = Get-Content -LiteralPath $resultPath -Encoding UTF8 -Raw
        $convertedSystemResults = ConvertFrom-Json -InputObject $systemResultsJson
        $systemResults = @()
        if ($convertedSystemResults -is [array]) {
            $systemResults = @($convertedSystemResults)
        } elseif ($convertedSystemResults -and ($convertedSystemResults.PSObject.Properties.Name -contains 'Type') -and ($convertedSystemResults.Type -is [array])) {
            $resultCount = @($convertedSystemResults.Type).Count
            for ($index = 0; $index -lt $resultCount; $index++) {
                $systemResults += [pscustomobject]@{
                    Time = @($convertedSystemResults.Time)[$index]
                    Type = @($convertedSystemResults.Type)[$index]
                    Name = @($convertedSystemResults.Name)[$index]
                    Status = @($convertedSystemResults.Status)[$index]
                    Detail = @($convertedSystemResults.Detail)[$index]
                }
            }
        } elseif ($convertedSystemResults) {
            $systemResults = @($convertedSystemResults)
        }

        $records = @()
        foreach ($result in $systemResults) {
            $severity = if ($result.Status -match 'Failed|Exit=1') { 'Warning' } else { 'Info' }
            $records += New-CPanDiagnosticRecord -Type ('WindowsUpdateSystem' + [string] $result.Type) -Severity $severity -Name ([string] $result.Name) -Message ([string] $result.Status) -Detail ([string] $result.Detail)
        }
        return $records
    } catch {
        return @(New-CPanDiagnosticRecord -Type 'WindowsUpdateSystemHardening' -Severity 'Warning' -Name 'SYSTEM task' -Message 'SYSTEM hardening task failed.' -Detail $_.Exception.Message)
    } finally {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    }
}

function Install-CPanWindowsUpdateGuardTask {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Context,

        [ValidateRange(5, 1440)]
        [int] $IntervalMinutes = 15
    )

    try {
        $taskPath = '\CPanCleaner\'
        $taskName = 'WindowsUpdateGuard'
        Unregister-ScheduledTask -TaskPath $taskPath -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

        $registryPlans = @(
            [pscustomobject]@{ Path = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; Name = 'DisableWindowsUpdateAccess'; Value = 1 },
            [pscustomobject]@{ Path = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; Name = 'SetDisableUXWUAccess'; Value = 1 },
            [pscustomobject]@{ Path = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; Name = 'DoNotConnectToWindowsUpdateInternetLocations'; Value = 1 },
            [pscustomobject]@{ Path = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; Name = 'ExcludeWUDriversInQualityUpdate'; Value = 1 },
            [pscustomobject]@{ Path = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'; Name = 'NoAutoUpdate'; Value = 1 },
            [pscustomobject]@{ Path = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'; Name = 'AUOptions'; Value = 2 },
            [pscustomobject]@{ Path = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'; Name = 'DODownloadMode'; Value = 0 },
            [pscustomobject]@{ Path = 'HKLM\SYSTEM\CurrentControlSet\Services\wuauserv'; Name = 'Start'; Value = 4 },
            [pscustomobject]@{ Path = 'HKLM\SYSTEM\CurrentControlSet\Services\UsoSvc'; Name = 'Start'; Value = 4 },
            [pscustomobject]@{ Path = 'HKLM\SYSTEM\CurrentControlSet\Services\UsoSvc'; Name = 'DelayedAutoStart'; Value = 0 },
            [pscustomobject]@{ Path = 'HKLM\SYSTEM\CurrentControlSet\Services\DoSvc'; Name = 'Start'; Value = 4 },
            [pscustomobject]@{ Path = 'HKLM\SYSTEM\CurrentControlSet\Services\DoSvc'; Name = 'DelayedAutoStart'; Value = 0 },
            [pscustomobject]@{ Path = 'HKLM\SYSTEM\CurrentControlSet\Services\WaaSMedicSvc'; Name = 'Start'; Value = 4 }
        )

        $actions = foreach ($plan in $registryPlans) {
            New-ScheduledTaskAction -Execute 'reg.exe' -Argument ('add "{0}" /v {1} /t REG_DWORD /d {2} /f' -f $plan.Path, $plan.Name, $plan.Value)
        }
        $startupTrigger = New-ScheduledTaskTrigger -AtStartup
        $repeatTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) -RepetitionDuration (New-TimeSpan -Days 3650)
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 2)

        Register-ScheduledTask -TaskPath $taskPath -TaskName $taskName -Action $actions -Trigger @($startupTrigger, $repeatTrigger) -Principal $principal -Settings $settings -Force | Out-Null
        Start-ScheduledTask -TaskPath $taskPath -TaskName $taskName

        $detail = "Actions=$($registryPlans.Count) registry writes; Schedule=AtStartup+Every${IntervalMinutes}Minutes"
        Write-CPanLog -Context $Context -Level 'INFO' -Message "Installed CPanCleaner Windows Update guard task. $detail"
        return New-CPanDiagnosticRecord -Type 'WindowsUpdateGuard' -Severity 'Info' -Name "$taskPath$taskName" -Message 'Persistent Windows Update guard task was installed and started.' -Detail $detail
    } catch {
        Write-CPanLog -Context $Context -Level 'WARN' -Message "Could not install Windows Update guard task: $($_.Exception.Message)"
        return New-CPanDiagnosticRecord -Type 'WindowsUpdateGuard' -Severity 'Warning' -Name '\CPanCleaner\WindowsUpdateGuard' -Message 'Persistent Windows Update guard task could not be installed.' -Detail $_.Exception.Message
    }
}

function Get-CPanPerformancePriorityProcessNames {
    return @(
        'NLSvc',
        'FlClash',
        'FlClashCore',
        'SDPProxyClient',
        'CmicSDPAccessAgent',
        'CmicSDPAccessAgentDaemon',
        'CmicSDPAccessAgentTray',
        'Lenovo.Modern.ImController',
        'Lenovo.Modern.ImController.PluginHost.Device',
        'UsbClientService',
        'vss-service-x64',
        'vmware-authd',
        'SmpHelp',
        'MSPCManager',
        'MSPCManagerService',
        'NTFSWatcher',
        'NutstoreDriverSvc',
        'AweSun',
        'awesun_guard',
        'WXWorkWeb',
        'WeMail',
        'Codex',
        'codex',
        'wps',
        'wpspdf',
        'et',
        'wpscloudsvr',
        'mCloud',
        'mountSpace',
        'uploadDownload',
        'backupDisk',
        'MirrorServer',
        'SyncMirrorServer',
        'syncDisk',
        'SpaceAgent'
    )
}

function Get-CPanPerformanceGuardProcessNames {
    return @(
        @(Get-CPanPerformancePriorityProcessNames),
        @('TGitCache')
    ) | ForEach-Object { $_ } | Sort-Object -Unique
}

function Measure-CPanProcessCpuUsage {
    param(
        [Parameter(Mandatory = $true)]
        [string[]] $Name,

        [int] $SampleMilliseconds = 1000
    )

    $cores = [Environment]::ProcessorCount
    if ($cores -lt 1) {
        $cores = 1
    }

    $firstSamples = @{}
    foreach ($processName in $Name) {
        Get-Process -Name $processName -ErrorAction SilentlyContinue | ForEach-Object {
            if ($null -ne $_.CPU) {
                $firstSamples[$_.Id] = [pscustomobject]@{
                    Id = $_.Id
                    ProcessName = $_.ProcessName
                    Cpu = [double] $_.CPU
                    Path = $_.Path
                }
            }
        }
    }

    if ($firstSamples.Count -eq 0) {
        return @()
    }

    Start-Sleep -Milliseconds $SampleMilliseconds

    $intervalSeconds = [math]::Max(($SampleMilliseconds / 1000.0), 0.001)
    $ids = @($firstSamples.Keys | ForEach-Object { [int] $_ })
    $measurements = @()

    Get-Process -Id $ids -ErrorAction SilentlyContinue | ForEach-Object {
        if ($null -ne $_.CPU -and $firstSamples.ContainsKey($_.Id)) {
            $first = $firstSamples[$_.Id]
            $deltaCpuSeconds = ([double] $_.CPU) - $first.Cpu
            if ($deltaCpuSeconds -ge 0) {
                $rawPercent = [math]::Round(($deltaCpuSeconds / $intervalSeconds) * 100, 2)
                $approxTotalPercent = [math]::Round($rawPercent / $cores, 2)
                $measurements += [pscustomobject]@{
                    ProcessName = $_.ProcessName
                    Id = $_.Id
                    RawCpuPercent = $rawPercent
                    ApproxTotalCpuPercent = $approxTotalPercent
                    Path = $first.Path
                }
            }
        }
    }

    return $measurements
}

function Get-CPanPerformanceProcessCandidates {
    $records = [ordered]@{
        Git = @()
        Conda = @()
        GitShellCache = @()
        GitShellCacheCpu = @()
    }

    try {
        $processes = Get-CimInstance Win32_Process -ErrorAction Stop
        $records.Git = @($processes | Where-Object {
            ($_.Name -eq 'git.exe' -or $_.Name -eq 'git-remote-http.exe' -or $_.Name -eq 'git-remote-https.exe') -and
            $_.CommandLine -match 'fsmonitor--daemon run|git fetch|git remote-http|git remote-https|remote-http|remote-https'
        })
        $records.Conda = @($processes | Where-Object {
            $_.Name -eq 'python.exe' -and
            $_.CommandLine -match 'conda-script.py shell.powershell (hook|activate)'
        })
        $records.GitShellCache = @($processes | Where-Object {
            $_.Name -eq 'TGitCache.exe'
        })
        $records.GitShellCacheCpu = @(Measure-CPanProcessCpuUsage -Name @('TGitCache') -SampleMilliseconds 1000)
    } catch {
        $records.QueryError = $_.Exception.Message
    }

    return [pscustomobject]$records
}

function Get-CPanGitPerformanceRepositoryState {
    param(
        [string] $RepositoryPath
    )

    if (-not $RepositoryPath -or -not (Test-Path -LiteralPath $RepositoryPath)) {
        return $null
    }

    try {
        $gitDir = (& git -C $RepositoryPath rev-parse --git-dir 2>$null)
        if ($LASTEXITCODE -ne 0 -or -not $gitDir) {
            return $null
        }
        $repositoryRoot = (& git -C $RepositoryPath rev-parse --show-toplevel 2>$null)
        if ($LASTEXITCODE -ne 0 -or -not $repositoryRoot) {
            $repositoryRoot = $RepositoryPath
        }
        $repositoryRoot = ConvertTo-CPanFullPath $repositoryRoot

        $gitDirPath = if ([System.IO.Path]::IsPathRooted($gitDir)) {
            $gitDir
        } else {
            Join-Path $RepositoryPath $gitDir
        }
        $gitDirPath = ConvertTo-CPanFullPath $gitDirPath
        $fsmonitor = (& git -C $RepositoryPath config --get core.fsmonitor 2>$null)
        $untrackedCache = (& git -C $RepositoryPath config --get core.untrackedCache 2>$null)
        $daemonPath = Join-Path $gitDirPath 'fsmonitor--daemon'

        return [pscustomobject]@{
            RepositoryPath = $repositoryRoot
            GitDir = $gitDirPath
            FsMonitor = if ($fsmonitor) { [string] $fsmonitor } else { '<unset>' }
            UntrackedCache = if ($untrackedCache) { [string] $untrackedCache } else { '<unset>' }
            HasDaemonState = (Test-Path -LiteralPath $daemonPath)
            DaemonStatePath = $daemonPath
        }
    } catch {
        return [pscustomobject]@{
            RepositoryPath = $RepositoryPath
            GitDir = ''
            FsMonitor = '<error>'
            UntrackedCache = '<error>'
            HasDaemonState = $false
            DaemonStatePath = ''
            Error = $_.Exception.Message
        }
    }
}

function Get-CPanNearbyGitPerformanceRepositoryStates {
    param(
        [string] $RepositoryPath
    )

    $states = @()
    $primaryState = Get-CPanGitPerformanceRepositoryState -RepositoryPath $RepositoryPath
    if ($primaryState) {
        $states += $primaryState
    }

    if (-not $primaryState -or -not $primaryState.RepositoryPath) {
        return $states
    }

    $parentPath = Split-Path -Parent $primaryState.RepositoryPath
    if (-not $parentPath -or -not (Test-Path -LiteralPath $parentPath)) {
        return $states
    }

    try {
        $siblingRepositories = @(Get-ChildItem -LiteralPath $parentPath -Directory -Force -ErrorAction Stop | Where-Object {
            $_.FullName -ne $primaryState.RepositoryPath -and
            (Test-Path -LiteralPath (Join-Path $_.FullName '.git\fsmonitor--daemon'))
        })

        foreach ($repository in $siblingRepositories) {
            $state = Get-CPanGitPerformanceRepositoryState -RepositoryPath $repository.FullName
            if ($state) {
                $states += $state
            }
        }
    } catch {
        $states += [pscustomobject]@{
            RepositoryPath = $parentPath
            GitDir = ''
            FsMonitor = '<error>'
            UntrackedCache = '<error>'
            HasDaemonState = $false
            DaemonStatePath = ''
            Error = $_.Exception.Message
        }
    }

    $seen = @{}
    return @($states | Where-Object {
        $key = $_.RepositoryPath
        if (-not $key -or $seen.ContainsKey($key)) {
            return $false
        }
        $seen[$key] = $true
        return $true
    })
}

function Get-CPanPerformanceSnapshot {
    $records = @()

    try {
        $samples = Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 1 -MaxSamples 3 -ErrorAction Stop
        $values = @($samples.CounterSamples | ForEach-Object { [math]::Round($_.CookedValue, 2) })
        if ($values.Count -gt 0) {
            $average = [math]::Round((($values | Measure-Object -Average).Average), 2)
            $records += New-CPanDiagnosticRecord -Type 'PerformanceCpu' -Severity 'Info' -Name 'Processor(_Total)' -Message 'Current total CPU sample.' -Detail ("Samples={0}; Average={1}%" -f ($values -join ', '), $average)
        }
    } catch {
        $records += New-CPanDiagnosticRecord -Type 'PerformanceCpu' -Severity 'Warning' -Name 'Processor(_Total)' -Message 'CPU counters could not be sampled.' -Detail $_.Exception.Message
    }

    $processSamples = @(Get-Counter '\Process(*)\% Processor Time' -SampleInterval 1 -MaxSamples 2 -ErrorAction SilentlyContinue)
    if ($processSamples.Count -gt 0) {
        $topProcesses = @($processSamples[-1].CounterSamples |
            Where-Object { $_.InstanceName -ne '_total' -and $_.InstanceName -ne 'idle' -and $_.Status -eq 0 } |
            Sort-Object CookedValue -Descending |
            Select-Object -First 12)

        foreach ($sample in $topProcesses) {
            $records += New-CPanDiagnosticRecord `
                -Type 'PerformanceTopProcess' `
                -Severity 'Info' `
                -Name $sample.InstanceName `
                -Message 'Current process CPU sample.' `
                -Detail ('CPUPercentRaw={0}' -f ([math]::Round($sample.CookedValue, 2)))
        }
    } else {
        $records += New-CPanDiagnosticRecord -Type 'PerformanceTopProcess' -Severity 'Info' -Name 'ProcessCounters' -Message 'Process CPU counters were not available for this sample.' -Detail ''
    }

    return $records
}

function Test-CPanShouldDisableRepositoryFsmonitor {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $RepositoryState
    )

    return $RepositoryState.FsMonitor -ne 'false' -or $RepositoryState.UntrackedCache -ne 'false'
}

function Invoke-CPanOptimizePerformance {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Context,

        [string] $RepositoryPath,

        [switch] $Apply
    )

    $records = @(Get-CPanPerformanceSnapshot)
    $candidates = Get-CPanPerformanceProcessCandidates

    if ($candidates.PSObject.Properties.Name -contains 'QueryError') {
        $records += New-CPanDiagnosticRecord -Type 'PerformanceProcessQuery' -Severity 'Warning' -Name 'Win32_Process' -Message 'Process candidates could not be queried.' -Detail $candidates.QueryError
    }

    $gitProcesses = @($candidates.Git)
    $condaProcesses = @($candidates.Conda)
    $gitShellCacheCpu = @($candidates.GitShellCacheCpu)
    $hotGitShellCacheIds = @($gitShellCacheCpu | Where-Object { $_.ApproxTotalCpuPercent -ge 5 } | Select-Object -ExpandProperty Id)
    $gitShellCacheProcesses = @()
    if ($gitProcesses.Count -gt 0) {
        $gitShellCacheProcesses = @($candidates.GitShellCache)
    } elseif ($hotGitShellCacheIds.Count -gt 0) {
        $gitShellCacheProcesses = @($candidates.GitShellCache | Where-Object { $hotGitShellCacheIds -contains $_.ProcessId })
    }
    $repositoryStates = @(Get-CPanNearbyGitPerformanceRepositoryStates -RepositoryPath $RepositoryPath)
    $priorityNames = Get-CPanPerformancePriorityProcessNames
    $priorityProcesses = @()
    foreach ($name in $priorityNames) {
        $priorityProcesses += @(Get-Process -Name $name -ErrorAction SilentlyContinue)
    }

    if (-not $Apply) {
        foreach ($process in $gitProcesses) {
            $records += New-CPanDiagnosticRecord -Type 'PlannedChange' -Severity 'Info' -Name $process.Name -Id $process.ProcessId -Message 'Dry-run: stale Git background process would be stopped.' -Detail $process.CommandLine
        }
        foreach ($process in $condaProcesses) {
            $records += New-CPanDiagnosticRecord -Type 'PlannedChange' -Severity 'Info' -Name $process.Name -Id $process.ProcessId -Message 'Dry-run: stuck Conda PowerShell helper would be stopped.' -Detail $process.CommandLine
        }
        foreach ($process in $gitShellCacheProcesses) {
            $cpu = @($gitShellCacheCpu | Where-Object { $_.Id -eq $process.ProcessId } | Select-Object -First 1)
            $reason = if ($gitProcesses.Count -gt 0) {
                'stale Git background work was found'
            } elseif ($cpu.Count -gt 0) {
                ('TGitCache is currently using about {0}% of total CPU' -f $cpu[0].ApproxTotalCpuPercent)
            } else {
                'TortoiseGit shell cache appears to be active during a performance run'
            }
            $records += New-CPanDiagnosticRecord -Type 'PlannedChange' -Severity 'Info' -Name $process.Name -Id $process.ProcessId -Message ('Dry-run: TortoiseGit cache helper would be stopped because {0}.' -f $reason) -Detail $process.CommandLine
        }
        foreach ($process in $priorityProcesses) {
            $records += New-CPanDiagnosticRecord -Type 'PlannedChange' -Severity 'Info' -Name $process.ProcessName -Id $process.Id -Message 'Dry-run: process priority would be set to BelowNormal.' -Detail ('CurrentPriority={0}; Path={1}' -f $process.PriorityClass, $process.Path)
        }
        foreach ($repositoryState in $repositoryStates) {
            $records += New-CPanDiagnosticRecord -Type 'GitConfig' -Severity 'Info' -Name 'Repository' -Message 'Repository Git performance state.' -Detail ("Path={0}; core.fsmonitor={1}; core.untrackedCache={2}; DaemonState={3}" -f $repositoryState.RepositoryPath, $repositoryState.FsMonitor, $repositoryState.UntrackedCache, $repositoryState.HasDaemonState)
            if (Test-CPanShouldDisableRepositoryFsmonitor -RepositoryState $repositoryState) {
                $records += New-CPanDiagnosticRecord -Type 'PlannedChange' -Severity 'Info' -Name 'Git fsmonitor' -Message 'Dry-run: repository fsmonitor and untracked cache would be disabled locally.' -Detail ("git -C `"{0}`" config core.fsmonitor false; git -C `"{0}`" config core.untrackedCache false" -f $repositoryState.RepositoryPath)
            }
        }
        $records += New-CPanDiagnosticRecord -Type 'PlannedChange' -Severity 'Info' -Name 'DNS cache' -Message 'Dry-run: DNS resolver cache would be flushed.' -Detail 'Clear-DnsClientCache and ipconfig /flushdns'
        if ($gitProcesses.Count -eq 0 -and $condaProcesses.Count -eq 0 -and $gitShellCacheProcesses.Count -eq 0 -and $priorityProcesses.Count -eq 0) {
            $records += New-CPanDiagnosticRecord -Type 'PerformanceOptimization' -Severity 'Info' -Name 'NoCandidates' -Message 'No stale Git/Conda helpers or known noisy helper processes were found.' -Detail ''
        }
        return $records
    }

    foreach ($process in ($gitProcesses + $condaProcesses + $gitShellCacheProcesses)) {
        try {
            Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
            Write-CPanLog -Context $Context -Level 'INFO' -Message "Stopped performance helper process $($process.Name) PID=$($process.ProcessId)."
            $records += New-CPanDiagnosticRecord -Type 'PerformanceStopProcess' -Severity 'Info' -Name $process.Name -Id $process.ProcessId -Message 'Process was stopped.' -Detail $process.CommandLine
        } catch {
            Write-CPanLog -Context $Context -Level 'WARN' -Message "Could not stop process $($process.Name) PID=$($process.ProcessId): $($_.Exception.Message)"
            $records += New-CPanDiagnosticRecord -Type 'PerformanceStopProcess' -Severity 'Warning' -Name $process.Name -Id $process.ProcessId -Message 'Process could not be stopped.' -Detail $_.Exception.Message
        }
    }

    foreach ($repositoryState in $repositoryStates) {
        if (-not (Test-CPanShouldDisableRepositoryFsmonitor -RepositoryState $repositoryState)) {
            continue
        }

        try {
            & git -C $repositoryState.RepositoryPath config core.fsmonitor false
            if ($LASTEXITCODE -ne 0) {
                throw 'git config core.fsmonitor false failed.'
            }
            & git -C $repositoryState.RepositoryPath config core.untrackedCache false
            if ($LASTEXITCODE -ne 0) {
                throw 'git config core.untrackedCache false failed.'
            }
            Write-CPanLog -Context $Context -Level 'INFO' -Message "Disabled Git fsmonitor/untrackedCache for $($repositoryState.RepositoryPath)."
            $records += New-CPanDiagnosticRecord -Type 'GitConfig' -Severity 'Info' -Name 'Git fsmonitor' -Message 'Repository fsmonitor and untracked cache were disabled locally.' -Detail $repositoryState.RepositoryPath
        } catch {
            Write-CPanLog -Context $Context -Level 'WARN' -Message "Could not disable Git fsmonitor for $($repositoryState.RepositoryPath): $($_.Exception.Message)"
            $records += New-CPanDiagnosticRecord -Type 'GitConfig' -Severity 'Warning' -Name 'Git fsmonitor' -Message 'Repository fsmonitor could not be disabled.' -Detail $_.Exception.Message
        }
    }

    try {
        Clear-DnsClientCache -ErrorAction Stop
        $records += New-CPanDiagnosticRecord -Type 'PerformanceDns' -Severity 'Info' -Name 'Clear-DnsClientCache' -Message 'DNS resolver cache was flushed.' -Detail ''
    } catch {
        $records += New-CPanDiagnosticRecord -Type 'PerformanceDns' -Severity 'Warning' -Name 'Clear-DnsClientCache' -Message 'DNS resolver cache could not be flushed.' -Detail $_.Exception.Message
    }

    try {
        $output = & ipconfig.exe /flushdns 2>&1
        $severity = if ($LASTEXITCODE -eq 0) { 'Info' } else { 'Warning' }
        $records += New-CPanDiagnosticRecord -Type 'PerformanceDns' -Severity $severity -Name 'ipconfig /flushdns' -Message 'ipconfig DNS flush was requested.' -Detail (($output | Out-String).Trim())
    } catch {
        $records += New-CPanDiagnosticRecord -Type 'PerformanceDns' -Severity 'Warning' -Name 'ipconfig /flushdns' -Message 'ipconfig DNS flush failed.' -Detail $_.Exception.Message
    }

    foreach ($process in $priorityProcesses) {
        try {
            $oldPriority = $process.PriorityClass
            $process.PriorityClass = 'BelowNormal'
            Write-CPanLog -Context $Context -Level 'INFO' -Message "Set priority BelowNormal for $($process.ProcessName) PID=$($process.Id)."
            $records += New-CPanDiagnosticRecord -Type 'PerformancePriority' -Severity 'Info' -Name $process.ProcessName -Id $process.Id -Message 'Process priority was set to BelowNormal.' -Detail ('OldPriority={0}; Path={1}' -f $oldPriority, $process.Path)
        } catch {
            Write-CPanLog -Context $Context -Level 'WARN' -Message "Could not set priority for $($process.ProcessName) PID=$($process.Id): $($_.Exception.Message)"
            $records += New-CPanDiagnosticRecord -Type 'PerformancePriority' -Severity 'Warning' -Name $process.ProcessName -Id $process.Id -Message 'Process priority could not be changed.' -Detail $_.Exception.Message
        }
    }

    return $records
}

function Get-CPanPerformanceHardeningRegistryPlans {
    return @(
        [pscustomobject]@{
            Path = 'HKCU:\Software\TortoiseGit'
            NativePath = 'HKCU\Software\TortoiseGit'
            Name = 'TGitCacheCheckContentMaxSize'
            Value = 0
            Message = 'Disable TortoiseGit shell-cache content hashing so Explorer status overlays use metadata instead of reading file contents.'
        },
        [pscustomobject]@{
            Path = 'HKCU:\Software\TortoiseGit'
            NativePath = 'HKCU\Software\TortoiseGit'
            Name = 'BlockStatus'
            Value = 1
            Message = 'Block shell status refresh while TortoiseGit commands are running, reducing Explorer status churn during Git operations.'
        },
        [pscustomobject]@{
            Path = 'HKCU:\Software\TortoiseGit'
            NativePath = 'HKCU\Software\TortoiseGit'
            Name = 'CacheSave'
            Value = 0
            Message = 'Avoid persisting TortoiseGit cache state to disk between sessions.'
        },
        [pscustomobject]@{
            Path = 'HKCU:\Software\TortoiseGit'
            NativePath = 'HKCU\Software\TortoiseGit'
            Name = 'ModifyExplorerTitle'
            Value = 0
            Message = 'Disable TortoiseGit Explorer-title enrichment to avoid extra repository status work in Explorer windows.'
        }
    )
}

function Get-CPanRegistryValueText {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    try {
        $item = Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop
        $value = $item.$Name
        if ($null -eq $value) {
            return '<unset>'
        }
        return [string] $value
    } catch {
        return '<unset>'
    }
}

function Set-CPanPerformanceRegistryDWord {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Plan,

        [Parameter(Mandatory = $true)]
        [pscustomobject] $Context
    )

    try {
        $oldValue = Get-CPanRegistryValueText -Path $Plan.Path -Name $Plan.Name
        $output = & reg.exe add $Plan.NativePath /v $Plan.Name /t REG_DWORD /d $Plan.Value /f 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw (($output | Out-String).Trim())
        }
        Write-CPanLog -Context $Context -Level 'INFO' -Message "Set performance registry value $($Plan.Path)\$($Plan.Name)=$($Plan.Value)."
        return New-CPanDiagnosticRecord -Type 'PerformanceHardening' -Severity 'Info' -Name $Plan.Name -Message 'Performance registry value was set.' -Detail ("OldValue={0}; NewValue={1}; {2}" -f $oldValue, $Plan.Value, $Plan.Message)
    } catch {
        Write-CPanLog -Context $Context -Level 'WARN' -Message "Could not set performance registry value $($Plan.Path)\$($Plan.Name): $($_.Exception.Message)"
        return New-CPanDiagnosticRecord -Type 'PerformanceHardening' -Severity 'Warning' -Name $Plan.Name -Message 'Performance registry value could not be set.' -Detail $_.Exception.Message
    }
}

function Get-CPanGitGlobalConfigValue {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    try {
        $value = & git config --global --get $Name 2>$null
        if ($LASTEXITCODE -eq 0 -and $value) {
            return [string] $value
        }
    } catch {
    }

    return '<unset>'
}

function Set-CPanGitGlobalFalse {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [pscustomobject] $Context
    )

    $oldValue = Get-CPanGitGlobalConfigValue -Name $Name
    try {
        & git config --global $Name false
        if ($LASTEXITCODE -ne 0) {
            throw "git config --global $Name false failed."
        }
        Write-CPanLog -Context $Context -Level 'INFO' -Message "Set global Git config $Name=false."
        return New-CPanDiagnosticRecord -Type 'PerformanceHardening' -Severity 'Info' -Name $Name -Message 'Global Git performance config was set.' -Detail ("OldValue={0}; NewValue=false" -f $oldValue)
    } catch {
        Write-CPanLog -Context $Context -Level 'WARN' -Message "Could not set global Git config ${Name}: $($_.Exception.Message)"
        return New-CPanDiagnosticRecord -Type 'PerformanceHardening' -Severity 'Warning' -Name $Name -Message 'Global Git performance config could not be set.' -Detail $_.Exception.Message
    }
}

function Set-CPanRepositoryFsmonitorFalse {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $RepositoryState,

        [Parameter(Mandatory = $true)]
        [pscustomobject] $Context
    )

    try {
        & git -C $RepositoryState.RepositoryPath config core.fsmonitor false
        if ($LASTEXITCODE -ne 0) {
            throw 'git config core.fsmonitor false failed.'
        }
        & git -C $RepositoryState.RepositoryPath config core.untrackedCache false
        if ($LASTEXITCODE -ne 0) {
            throw 'git config core.untrackedCache false failed.'
        }
        Write-CPanLog -Context $Context -Level 'INFO' -Message "Disabled Git fsmonitor/untrackedCache for $($RepositoryState.RepositoryPath)."
        return New-CPanDiagnosticRecord -Type 'GitConfig' -Severity 'Info' -Name 'Git fsmonitor' -Message 'Repository fsmonitor and untracked cache were disabled locally.' -Detail $RepositoryState.RepositoryPath
    } catch {
        Write-CPanLog -Context $Context -Level 'WARN' -Message "Could not disable Git fsmonitor for $($RepositoryState.RepositoryPath): $($_.Exception.Message)"
        return New-CPanDiagnosticRecord -Type 'GitConfig' -Severity 'Warning' -Name 'Git fsmonitor' -Message 'Repository fsmonitor could not be disabled.' -Detail $_.Exception.Message
    }
}

function Get-CPanPerformanceGuardScriptPath {
    $programData = if ($env:ProgramData) { $env:ProgramData } else { 'C:\ProgramData' }
    return (Join-Path $programData 'CPanCleaner\Set-PerformancePriority.ps1')
}

function Get-CPanPerformanceGuardScriptContent {
    $namesLiteral = (Get-CPanPerformanceGuardProcessNames | ForEach-Object { "    '$($_)'" }) -join ",`r`n"
    return @"
`$ErrorActionPreference = 'SilentlyContinue'
`$names = @(
$namesLiteral
)

foreach (`$name in `$names) {
    Get-Process -Name `$name -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            `$_.PriorityClass = 'BelowNormal'
        } catch {
        }
    }
}

`$gitProcesses = @(Get-Process -Name 'git','git-remote-http','git-remote-https' -ErrorAction SilentlyContinue)
if (`$gitProcesses.Count -gt 0) {
    try {
        `$gitProcessIds = @(`$gitProcesses | ForEach-Object { `$_.Id })
        Get-CimInstance Win32_Process -Filter "Name = 'git.exe' OR Name = 'git-remote-http.exe' OR Name = 'git-remote-https.exe'" -ErrorAction SilentlyContinue |
            Where-Object { `$_.ProcessId -in `$gitProcessIds -and `$_.CommandLine -match 'github\.com/openai/plugins\.git' } |
            ForEach-Object {
                try {
                    Stop-Process -Id `$_.ProcessId -Force -ErrorAction SilentlyContinue
                } catch {
                }
            }
    } catch {
    }
}
"@
}

function Install-CPanPerformanceGuardTask {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Context,

        [Parameter(Mandatory = $true)]
        [bool] $IsAdmin,

        [ValidateRange(5, 1440)]
        [int] $IntervalMinutes = 15
    )

    if (-not $IsAdmin) {
        return New-CPanDiagnosticRecord -Type 'PerformanceGuard' -Severity 'Error' -Name 'Administrator' -Message 'Administrator rights are required to install the performance guard scheduled task.' -Detail 'Run again as Administrator, or use -Elevate.'
    }

    $taskPath = '\CPanCleaner\'
    $taskName = 'PerformanceGuard'
    $scriptPath = Get-CPanPerformanceGuardScriptPath

    try {
        $scriptDirectory = Split-Path -Parent $scriptPath
        New-Item -ItemType Directory -Force -Path $scriptDirectory | Out-Null
        Set-Content -LiteralPath $scriptPath -Value (Get-CPanPerformanceGuardScriptContent) -Encoding UTF8

        Unregister-ScheduledTask -TaskPath $taskPath -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $scriptPath)
        $startupTrigger = New-ScheduledTaskTrigger -AtStartup
        $repeatTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) -RepetitionDuration (New-TimeSpan -Days 3650)
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 1)

        Register-ScheduledTask -TaskPath $taskPath -TaskName $taskName -Action $action -Trigger @($startupTrigger, $repeatTrigger) -Principal $principal -Settings $settings -Force | Out-Null
        Start-ScheduledTask -TaskPath $taskPath -TaskName $taskName

        $detail = "Script=$scriptPath; Processes=$((Get-CPanPerformanceGuardProcessNames) -join ','); Schedule=AtStartup+Every${IntervalMinutes}Minutes"
        Write-CPanLog -Context $Context -Level 'INFO' -Message "Installed CPanCleaner performance guard task. $detail"
        return New-CPanDiagnosticRecord -Type 'PerformanceGuard' -Severity 'Info' -Name "$taskPath$taskName" -Message 'Performance guard scheduled task was installed and started.' -Detail $detail
    } catch {
        Write-CPanLog -Context $Context -Level 'WARN' -Message "Could not install performance guard task: $($_.Exception.Message)"
        return New-CPanDiagnosticRecord -Type 'PerformanceGuard' -Severity 'Warning' -Name "$taskPath$taskName" -Message 'Performance guard scheduled task could not be installed.' -Detail $_.Exception.Message
    }
}

function Get-CPanGuardTaskStatus {
    param(
        [ValidateSet('PerformanceGuard', 'WindowsUpdateGuard')]
        [string] $GuardName
    )

    $taskPath = '\CPanCleaner\'
    $fullName = "$taskPath$GuardName"
    try {
        $task = Get-ScheduledTask -TaskPath $taskPath -TaskName $GuardName -ErrorAction Stop
        $taskInfo = Get-ScheduledTaskInfo -TaskPath $taskPath -TaskName $GuardName -ErrorAction SilentlyContinue
        $repeatTrigger = @($task.Triggers | Where-Object { $_.Repetition -and $_.Repetition.Interval }) | Select-Object -First 1
        $intervalMinutes = $null
        if ($repeatTrigger) {
            try {
                $intervalMinutes = [int][Math]::Round(([Xml.XmlConvert]::ToTimeSpan([string] $repeatTrigger.Repetition.Interval)).TotalMinutes)
            } catch {
                $intervalMinutes = [string] $repeatTrigger.Repetition.Interval
            }
        }
        $actionText = @($task.Actions | ForEach-Object { "Execute=$($_.Execute); Arguments=$($_.Arguments)" }) -join ' | '
        $nextRun = if ($taskInfo -and $taskInfo.NextRunTime -and $taskInfo.NextRunTime -gt [datetime]::MinValue) { $taskInfo.NextRunTime.ToString('s') } else { '<none>' }
        $lastRun = if ($taskInfo -and $taskInfo.LastRunTime -and $taskInfo.LastRunTime -gt [datetime]::MinValue) { $taskInfo.LastRunTime.ToString('s') } else { '<never>' }
        $lastResult = if ($taskInfo) { $taskInfo.LastTaskResult } else { '<unknown>' }
        $detail = "Installed=True; Enabled=$($task.Settings.Enabled); State=$($task.State); IntervalMinutes=$intervalMinutes; RunAs=$($task.Principal.UserId); NextRun=$nextRun; LastRun=$lastRun; LastResult=$lastResult; Storage=C:\Windows\System32\Tasks\CPanCleaner\$GuardName; $actionText"
        return New-CPanDiagnosticRecord -Type 'GuardStatus' -Severity 'Info' -Name $fullName -Message 'The scheduled task is installed.' -Detail $detail
    } catch [Microsoft.Management.Infrastructure.CimException] {
        return New-CPanDiagnosticRecord -Type 'GuardStatus' -Severity 'Info' -Name $fullName -Message 'The scheduled task is not installed. It is created only after explicit enablement in the GUI.' -Detail "Installed=False; Storage=C:\Windows\System32\Tasks\CPanCleaner\$GuardName"
    } catch {
        if ($_.Exception.Message -match 'cannot find|not found|does not exist') {
            return New-CPanDiagnosticRecord -Type 'GuardStatus' -Severity 'Info' -Name $fullName -Message 'The scheduled task is not installed. It is created only after explicit enablement in the GUI.' -Detail "Installed=False; Storage=C:\Windows\System32\Tasks\CPanCleaner\$GuardName"
        }
        return New-CPanDiagnosticRecord -Type 'GuardStatus' -Severity 'Warning' -Name $fullName -Message 'The scheduled task state could not be read.' -Detail $_.Exception.Message
    }
}

function Remove-CPanGuardTask {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Context,

        [ValidateSet('PerformanceGuard', 'WindowsUpdateGuard')]
        [string] $GuardName
    )

    $taskPath = '\CPanCleaner\'
    $fullName = "$taskPath$GuardName"
    try {
        $existing = Get-ScheduledTask -TaskPath $taskPath -TaskName $GuardName -ErrorAction SilentlyContinue
        if ($existing) {
            Unregister-ScheduledTask -TaskPath $taskPath -TaskName $GuardName -Confirm:$false -ErrorAction Stop
        }
        $removedScript = $false
        if ($GuardName -eq 'PerformanceGuard') {
            $scriptPath = Get-CPanPerformanceGuardScriptPath
            if (Test-Path -LiteralPath $scriptPath -PathType Leaf) {
                Remove-Item -LiteralPath $scriptPath -Force -ErrorAction Stop
                $removedScript = $true
            }
        }
        $detail = "TaskRemoved=$([bool]$existing); ScriptRemoved=$removedScript"
        Write-CPanLog -Context $Context -Level 'INFO' -Message "Disabled CPanCleaner guard $fullName. $detail"
        return New-CPanDiagnosticRecord -Type 'GuardControl' -Severity 'Info' -Name $fullName -Message 'The scheduled task was disabled and removed. Other settings previously written by related features were not reverted.' -Detail $detail
    } catch {
        Write-CPanLog -Context $Context -Level 'WARN' -Message "Could not remove guard $fullName`: $($_.Exception.Message)"
        return New-CPanDiagnosticRecord -Type 'GuardControl' -Severity 'Warning' -Name $fullName -Message 'The scheduled task could not be removed.' -Detail $_.Exception.Message
    }
}

function Invoke-CPanManageGuard {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Context,

        [ValidateSet('PerformanceGuard', 'WindowsUpdateGuard')]
        [string] $GuardName,

        [ValidateSet('Status', 'Enable', 'Disable')]
        [string] $GuardOperation,

        [ValidateRange(5, 1440)]
        [int] $IntervalMinutes,

        [switch] $Apply,

        [bool] $IsAdmin
    )

    if ($GuardOperation -eq 'Status') {
        return @(Get-CPanGuardTaskStatus -GuardName $GuardName)
    }

    if (-not $Apply) {
        $description = if ($GuardOperation -eq 'Enable') {
            "Dry-run: task would be installed or updated; Schedule=AtStartup+Every${IntervalMinutes}Minutes; RunAs=SYSTEM"
        } else {
            'Dry-run: task would be unregistered; the PerformanceGuard helper script would also be removed; other policies are not reverted.'
        }
        return @(
            (Get-CPanGuardTaskStatus -GuardName $GuardName),
            (New-CPanDiagnosticRecord -Type 'PlannedChange' -Severity 'Info' -Name "\CPanCleaner\$GuardName" -Message "Planned guard operation: $GuardOperation." -Detail $description)
        )
    }

    if (-not $IsAdmin) {
        return @(New-CPanDiagnosticRecord -Type 'GuardControl' -Severity 'Error' -Name 'Administrator' -Message 'Administrator rights are required to enable, update, or disable a SYSTEM scheduled task.' -Detail 'Approve the GUI UAC prompt and retry.')
    }

    if ($GuardOperation -eq 'Disable') {
        return @(
            (Remove-CPanGuardTask -Context $Context -GuardName $GuardName),
            (Get-CPanGuardTaskStatus -GuardName $GuardName)
        )
    }

    $installResult = if ($GuardName -eq 'PerformanceGuard') {
        Install-CPanPerformanceGuardTask -Context $Context -IsAdmin $IsAdmin -IntervalMinutes $IntervalMinutes
    } else {
        Install-CPanWindowsUpdateGuardTask -Context $Context -IntervalMinutes $IntervalMinutes
    }
    return @($installResult, (Get-CPanGuardTaskStatus -GuardName $GuardName))
}

function Get-CPanRunHistoryState {
    $advancedPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    $runMruPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\RunMRU'
    $userPolicyPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'
    $machinePolicyPath = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'
    $policyNames = @('NoInstrumentation', 'NoRecentDocsHistory', 'ClearRecentDocsOnExit', 'NoRunMRU')

    $advanced = Get-ItemProperty -LiteralPath $advancedPath -ErrorAction SilentlyContinue
    $runMru = Get-ItemProperty -LiteralPath $runMruPath -ErrorAction SilentlyContinue
    $userPolicy = Get-ItemProperty -LiteralPath $userPolicyPath -ErrorAction SilentlyContinue
    $machinePolicy = Get-ItemProperty -LiteralPath $machinePolicyPath -ErrorAction SilentlyContinue
    $entryNames = @()
    if ($runMru) {
        $entryNames = @($runMru.PSObject.Properties.Name | Where-Object { $_ -match '^[a-z]$' })
    }

    $userBlockers = @($policyNames | Where-Object {
        $property = if ($userPolicy) { $userPolicy.PSObject.Properties[$_] } else { $null }
        $property -and $null -ne $property.Value -and [int] $property.Value -ne 0
    })
    $machineBlockers = @($policyNames | Where-Object {
        $property = if ($machinePolicy) { $machinePolicy.PSObject.Properties[$_] } else { $null }
        $property -and $null -ne $property.Value -and [int] $property.Value -ne 0
    })
    $aclStatus = '<missing>'
    if (Test-Path -LiteralPath $runMruPath) {
        try {
            $acl = Get-Acl -LiteralPath $runMruPath -ErrorAction Stop
            $aclStatus = "Owner=$($acl.Owner); ACLReadable=True"
        } catch {
            $aclStatus = "ACLReadable=False; Error=$($_.Exception.Message)"
        }
    }

    return [pscustomobject]@{
        AdvancedPath = $advancedPath
        RunMruPath = $runMruPath
        UserPolicyPath = $userPolicyPath
        MachinePolicyPath = $machinePolicyPath
        StartTrackProgs = if ($advanced -and $advanced.PSObject.Properties['Start_TrackProgs']) { [int] $advanced.PSObject.Properties['Start_TrackProgs'].Value } else { $null }
        StartTrackDocs = if ($advanced -and $advanced.PSObject.Properties['Start_TrackDocs']) { [int] $advanced.PSObject.Properties['Start_TrackDocs'].Value } else { $null }
        RunMruExists = [bool] $runMru
        RunMruEntryCount = $entryNames.Count
        MruList = if ($runMru -and $runMru.PSObject.Properties['MRUList']) { [string] $runMru.PSObject.Properties['MRUList'].Value } else { '' }
        UserPolicyBlockers = $userBlockers
        MachinePolicyBlockers = $machineBlockers
        AclStatus = $aclStatus
    }
}

function ConvertTo-CPanRunHistoryStateDetail {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $State
    )

    return "Start_TrackProgs=$($State.StartTrackProgs); Start_TrackDocs=$($State.StartTrackDocs); RunMRUExists=$($State.RunMruExists); EntryCount=$($State.RunMruEntryCount); MRUList=$($State.MruList); UserPolicyBlockers=$($State.UserPolicyBlockers -join ','); MachinePolicyBlockers=$($State.MachinePolicyBlockers -join ','); $($State.AclStatus)"
}

function Send-CPanExplorerSettingChange {
    try {
        if (-not ('CPanCleaner.NativeMethods' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace CPanCleaner {
    public static class NativeMethods {
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr SendMessageTimeout(
            IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam,
            uint flags, uint timeout, out UIntPtr result);
    }
}
'@
        }
        $broadcast = [IntPtr] 0xffff
        $result = [UIntPtr]::Zero
        [void] [CPanCleaner.NativeMethods]::SendMessageTimeout(
            $broadcast,
            0x001A,
            [UIntPtr]::Zero,
            'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced',
            0x0002,
            3000,
            [ref] $result)
        return $true
    } catch {
        return $false
    }
}

function Invoke-CPanRepairRunHistory {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Context,

        [switch] $Apply
    )

    $before = Get-CPanRunHistoryState
    $records = @(
        (New-CPanDiagnosticRecord -Type 'RunHistoryState' -Severity 'Info' -Name 'Win+R history' -Message 'Current Run dialog history state.' -Detail (ConvertTo-CPanRunHistoryStateDetail -State $before))
    )

    if (-not $Apply) {
        $records += New-CPanDiagnosticRecord -Type 'PlannedChange' -Severity 'Info' -Name 'Start_TrackProgs' -Message 'Dry-run: application launch tracking would be enabled for the current user.' -Detail "$($before.AdvancedPath)\Start_TrackProgs: $($before.StartTrackProgs) -> 1"
        if ($before.UserPolicyBlockers.Count -gt 0) {
            $records += New-CPanDiagnosticRecord -Type 'PlannedChange' -Severity 'Info' -Name 'Current-user Explorer policies' -Message 'Dry-run: current-user policy values that suppress history would be backed up and removed.' -Detail ($before.UserPolicyBlockers -join ',')
        }
        $records += New-CPanDiagnosticRecord -Type 'PlannedChange' -Severity 'Info' -Name 'RunMRU write check' -Message 'Dry-run: RunMRU would be created if missing and tested for write access without adding a fake command.' -Detail $before.RunMruPath
        if ($before.MachinePolicyBlockers.Count -gt 0) {
            $records += New-CPanDiagnosticRecord -Type 'RunHistoryPolicy' -Severity 'Warning' -Name 'Machine policy' -Message 'Machine-level policy can override the current-user repair and will not be changed automatically.' -Detail ($before.MachinePolicyBlockers -join ',')
        }
        return $records
    }

    $backupPath = [System.IO.Path]::ChangeExtension($Context.LogPath, '.run-history-backup.json')
    try {
        $before | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $backupPath -Encoding UTF8
        Write-CPanLog -Context $Context -Level 'INFO' -Message "Saved Run history registry state to $backupPath."
        $records += New-CPanDiagnosticRecord -Type 'RunHistoryBackup' -Severity 'Info' -Name 'Registry state backup' -Message 'The pre-repair state was saved.' -Detail $backupPath
    } catch {
        Write-CPanLog -Context $Context -Level 'WARN' -Message "Could not save Run history backup: $($_.Exception.Message)"
        $records += New-CPanDiagnosticRecord -Type 'RunHistoryBackup' -Severity 'Warning' -Name 'Registry state backup' -Message 'The pre-repair state could not be saved; repair was not applied.' -Detail $_.Exception.Message
        return $records
    }

    $stage = 'Enable Start_TrackProgs'
    try {
        if (-not (Test-Path -LiteralPath $before.AdvancedPath)) {
            New-Item -Path $before.AdvancedPath -Force | Out-Null
        }
        New-ItemProperty -LiteralPath $before.AdvancedPath -Name 'Start_TrackProgs' -PropertyType DWord -Value 1 -Force | Out-Null

        $stage = 'Remove current-user policy blockers'
        foreach ($name in $before.UserPolicyBlockers) {
            Remove-ItemProperty -LiteralPath $before.UserPolicyPath -Name $name -Force -ErrorAction Stop
        }

        $stage = 'Create or open RunMRU'
        if (-not (Test-Path -LiteralPath $before.RunMruPath)) {
            New-Item -Path $before.RunMruPath -Force | Out-Null
        }
        $stage = 'Verify RunMRU write access'
        $testName = '__CPanCleanerWriteTest'
        $oldTestProperty = Get-ItemProperty -LiteralPath $before.RunMruPath -Name $testName -ErrorAction SilentlyContinue
        $oldTestValue = if ($oldTestProperty) { $oldTestProperty.$testName } else { $null }
        New-ItemProperty -LiteralPath $before.RunMruPath -Name $testName -PropertyType String -Value 'write-test' -Force | Out-Null
        Remove-ItemProperty -LiteralPath $before.RunMruPath -Name $testName -Force -ErrorAction Stop
        if ($null -ne $oldTestValue) {
            New-ItemProperty -LiteralPath $before.RunMruPath -Name $testName -PropertyType String -Value $oldTestValue -Force | Out-Null
        }

        $stage = 'Notify Explorer'
        $notified = Send-CPanExplorerSettingChange
        $stage = 'Verify repaired state'
        $after = Get-CPanRunHistoryState
        $verified = $after.StartTrackProgs -eq 1 -and $after.UserPolicyBlockers.Count -eq 0
        $severity = if ($verified -and $after.MachinePolicyBlockers.Count -eq 0) { 'Info' } else { 'Warning' }
        $message = if ($verified) { 'Run dialog history tracking was repaired for the current user.' } else { 'The repair completed, but verification still found a blocking setting.' }
        $detail = "NotifiedExplorer=$notified; Backup=$backupPath; $(ConvertTo-CPanRunHistoryStateDetail -State $after)"
        Write-CPanLog -Context $Context -Level 'INFO' -Message "Run history repair verification: $detail"
        $records += New-CPanDiagnosticRecord -Type 'RunHistoryRepair' -Severity $severity -Name 'Win+R history' -Message $message -Detail $detail
    } catch {
        Write-CPanLog -Context $Context -Level 'WARN' -Message "Run history repair failed at stage '$stage': $($_.Exception.Message)"
        $records += New-CPanDiagnosticRecord -Type 'RunHistoryRepair' -Severity 'Warning' -Name 'Win+R history' -Message 'Run dialog history repair failed.' -Detail "Stage=$stage; Error=$($_.Exception.Message); Backup=$backupPath"
    }

    return $records
}

function Invoke-CPanPreventPerformanceSpikes {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Context,

        [string] $RepositoryPath,

        [switch] $Apply,

        [bool] $IsAdmin
    )

    $records = @(Get-CPanPerformanceSnapshot)
    $registryPlans = @(Get-CPanPerformanceHardeningRegistryPlans)
    $repositoryStates = @(Get-CPanNearbyGitPerformanceRepositoryStates -RepositoryPath $RepositoryPath)
    $globalGitNames = @('core.fsmonitor', 'core.untrackedCache')
    $guardNames = @(Get-CPanPerformanceGuardProcessNames)

    if (-not $Apply) {
        foreach ($name in $globalGitNames) {
            $records += New-CPanDiagnosticRecord -Type 'PlannedChange' -Severity 'Info' -Name $name -Message 'Dry-run: global Git config would be set to false.' -Detail ("OldValue={0}; NewValue=false" -f (Get-CPanGitGlobalConfigValue -Name $name))
        }

        foreach ($repositoryState in $repositoryStates) {
            $records += New-CPanDiagnosticRecord -Type 'GitConfig' -Severity 'Info' -Name 'Repository' -Message 'Repository Git performance state.' -Detail ("Path={0}; core.fsmonitor={1}; core.untrackedCache={2}; DaemonState={3}" -f $repositoryState.RepositoryPath, $repositoryState.FsMonitor, $repositoryState.UntrackedCache, $repositoryState.HasDaemonState)
            if (Test-CPanShouldDisableRepositoryFsmonitor -RepositoryState $repositoryState) {
                $records += New-CPanDiagnosticRecord -Type 'PlannedChange' -Severity 'Info' -Name 'Git fsmonitor' -Message 'Dry-run: repository fsmonitor and untracked cache would be disabled locally.' -Detail $repositoryState.RepositoryPath
            }
        }

        foreach ($plan in $registryPlans) {
            $records += New-CPanDiagnosticRecord -Type 'PlannedChange' -Severity 'Info' -Name $plan.Name -Message 'Dry-run: TortoiseGit performance registry value would be set.' -Detail ("OldValue={0}; NewValue={1}; {2}" -f (Get-CPanRegistryValueText -Path $plan.Path -Name $plan.Name), $plan.Value, $plan.Message)
        }

        $records += New-CPanDiagnosticRecord -Type 'GuardControl' -Severity 'Info' -Name '\CPanCleaner\PerformanceGuard' -Message 'The performance guard task is managed separately in the GUI and is not installed by this action.' -Detail 'Use the PerformanceGuard feature to inspect status and choose a 5-1440 minute interval.'
        $records += New-CPanDiagnosticRecord -Type 'PlannedChange' -Severity 'Info' -Name 'Current helper priorities' -Message 'Dry-run: currently running known background helpers would be set to BelowNormal once.' -Detail ($guardNames -join ',')
        return $records
    }

    foreach ($name in $globalGitNames) {
        $records += Set-CPanGitGlobalFalse -Name $name -Context $Context
    }

    foreach ($repositoryState in $repositoryStates) {
        if (Test-CPanShouldDisableRepositoryFsmonitor -RepositoryState $repositoryState) {
            $records += Set-CPanRepositoryFsmonitorFalse -RepositoryState $repositoryState -Context $Context
        }
    }

    foreach ($plan in $registryPlans) {
        $records += Set-CPanPerformanceRegistryDWord -Plan $plan -Context $Context
    }

    foreach ($name in $guardNames) {
        Get-Process -Name $name -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $oldPriority = $_.PriorityClass
                $_.PriorityClass = 'BelowNormal'
                $records += New-CPanDiagnosticRecord -Type 'PerformancePriority' -Severity 'Info' -Name $_.ProcessName -Id $_.Id -Message 'Current process priority was set to BelowNormal.' -Detail ('OldPriority={0}; Path={1}' -f $oldPriority, $_.Path)
            } catch {
                $records += New-CPanDiagnosticRecord -Type 'PerformancePriority' -Severity 'Warning' -Name $_.ProcessName -Id $_.Id -Message 'Current process priority could not be changed.' -Detail $_.Exception.Message
            }
        }
    }

    $tgitCacheProcesses = @(Get-Process -Name TGitCache -ErrorAction SilentlyContinue)
    foreach ($process in $tgitCacheProcesses) {
        try {
            Stop-Process -Id $process.Id -Force -ErrorAction Stop
            $records += New-CPanDiagnosticRecord -Type 'PerformanceHardening' -Severity 'Info' -Name 'TGitCache' -Id $process.Id -Message 'TortoiseGit cache helper was restarted once so the new cache settings can take effect.' -Detail $process.Path
        } catch {
            $records += New-CPanDiagnosticRecord -Type 'PerformanceHardening' -Severity 'Warning' -Name 'TGitCache' -Id $process.Id -Message 'TortoiseGit cache helper could not be restarted.' -Detail $_.Exception.Message
        }
    }

    return $records
}

function Invoke-CPanDisableWindowsUpdateDownloads {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Context,

        [switch] $Apply,

        [bool] $IsAdmin
    )

    $records = @()

    foreach ($service in Get-CPanServiceControlSnapshot) {
        $records += New-CPanDiagnosticRecord `
            -Type 'WindowsUpdateService' `
            -Severity 'Info' `
            -Name $service.Name `
            -Message 'Current service state.' `
            -Detail ("Status={0}; StartType={1}; DisplayName={2}" -f $service.Status, $service.StartType, $service.DisplayName)
    }

    $policyPlans = @(
        [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; Name = 'DisableWindowsUpdateAccess'; Value = 1 },
        [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; Name = 'SetDisableUXWUAccess'; Value = 1 },
        [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; Name = 'DoNotConnectToWindowsUpdateInternetLocations'; Value = 1 },
        [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; Name = 'ExcludeWUDriversInQualityUpdate'; Value = 1 },
        [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'; Name = 'NoAutoUpdate'; Value = 1 },
        [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'; Name = 'AUOptions'; Value = 2 },
        [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'; Name = 'DODownloadMode'; Value = 0 }
    )
    $servicePlans = @(
        [pscustomobject]@{ Name = 'UsoSvc'; Start = 'disabled'; Stop = $true },
        [pscustomobject]@{ Name = 'wuauserv'; Start = 'disabled'; Stop = $true },
        [pscustomobject]@{ Name = 'DoSvc'; Start = 'disabled'; Stop = $true },
        [pscustomobject]@{ Name = 'WaaSMedicSvc'; Start = 'disabled'; Stop = $true },
        [pscustomobject]@{ Name = 'bits'; Start = '<unchanged>'; Stop = $false }
    )
    $taskPlans = @(
        [pscustomobject]@{ TaskPath = '\Microsoft\Windows\WindowsUpdate\'; TaskName = 'Scheduled Start' },
        [pscustomobject]@{ TaskPath = '\Microsoft\Windows\WindowsUpdate\'; TaskName = 'Refresh Group Policy Cache' },
        [pscustomobject]@{ TaskPath = '\Microsoft\Windows\UpdateOrchestrator\'; TaskName = 'Report policies' },
        [pscustomobject]@{ TaskPath = '\Microsoft\Windows\UpdateOrchestrator\'; TaskName = 'Schedule Maintenance Work' },
        [pscustomobject]@{ TaskPath = '\Microsoft\Windows\UpdateOrchestrator\'; TaskName = 'Schedule Scan' },
        [pscustomobject]@{ TaskPath = '\Microsoft\Windows\UpdateOrchestrator\'; TaskName = 'Schedule Scan Static Task' },
        [pscustomobject]@{ TaskPath = '\Microsoft\Windows\UpdateOrchestrator\'; TaskName = 'Schedule Wake To Work' },
        [pscustomobject]@{ TaskPath = '\Microsoft\Windows\UpdateOrchestrator\'; TaskName = 'Schedule Work' },
        [pscustomobject]@{ TaskPath = '\Microsoft\Windows\UpdateOrchestrator\'; TaskName = 'Start Oobe Expedite Work' },
        [pscustomobject]@{ TaskPath = '\Microsoft\Windows\UpdateOrchestrator\'; TaskName = 'StartOobeAppsScan' },
        [pscustomobject]@{ TaskPath = '\Microsoft\Windows\UpdateOrchestrator\'; TaskName = 'StartOobeAppsScan_LicenseAccepted' },
        [pscustomobject]@{ TaskPath = '\Microsoft\Windows\UpdateOrchestrator\'; TaskName = 'StartOobeAppsScanAfterUpdate' },
        [pscustomobject]@{ TaskPath = '\Microsoft\Windows\UpdateOrchestrator\'; TaskName = 'UIEOrchestrator' },
        [pscustomobject]@{ TaskPath = '\Microsoft\Windows\UpdateOrchestrator\'; TaskName = 'USO_UxBroker' },
        [pscustomobject]@{ TaskPath = '\Microsoft\Windows\UpdateOrchestrator\'; TaskName = 'UUS Failover Task' },
        [pscustomobject]@{ TaskPath = '\Microsoft\Windows\WaaSMedic\'; TaskName = 'DeferredWork' },
        [pscustomobject]@{ TaskPath = '\Microsoft\Windows\WaaSMedic\'; TaskName = 'MaintenanceWork' },
        [pscustomobject]@{ TaskPath = '\Microsoft\Windows\WaaSMedic\'; TaskName = 'PerformRemediation' }
    )

    if (-not $Apply) {
        foreach ($plan in $policyPlans) {
            $records += New-CPanDiagnosticRecord -Type 'PlannedChange' -Severity 'Info' -Name $plan.Name -Message 'Dry-run: policy value would be set.' -Detail ("{0}\{1}={2}" -f $plan.Path, $plan.Name, $plan.Value)
        }
        foreach ($plan in $servicePlans) {
            $records += New-CPanDiagnosticRecord -Type 'PlannedChange' -Severity 'Info' -Name $plan.Name -Message 'Dry-run: service startup/stop policy would be applied.' -Detail ("Start={0}; Stop={1}" -f $plan.Start, $plan.Stop)
        }
        foreach ($plan in $taskPlans) {
            $records += New-CPanDiagnosticRecord -Type 'PlannedChange' -Severity 'Info' -Name "$($plan.TaskPath)$($plan.TaskName)" -Message 'Dry-run: scheduled task disable would be attempted.' -Detail 'Protected tasks may return Access is denied.'
        }
        $records += New-CPanDiagnosticRecord -Type 'PlannedChange' -Severity 'Info' -Name 'BITS' -Message 'Dry-run: BITS jobs would be reset for all users.' -Detail 'BITS itself is left enabled because it is shared system infrastructure.'
        $records += New-CPanDiagnosticRecord -Type 'GuardControl' -Severity 'Info' -Name '\CPanCleaner\WindowsUpdateGuard' -Message 'The Windows Update guard task is managed separately in the GUI and is not installed by this action.' -Detail 'Use the WindowsUpdateGuard feature to inspect status and choose a 5-1440 minute interval.'
        return $records
    }

    if (-not $IsAdmin) {
        $records += New-CPanDiagnosticRecord -Type 'WindowsUpdateControl' -Severity 'Error' -Name 'Administrator' -Message 'Administrator rights are required to disable Windows Update downloads.' -Detail 'Run again as Administrator, or use -Elevate.'
        return $records
    }

    foreach ($plan in $policyPlans) {
        $records += Set-CPanRegistryDWord -Path $plan.Path -Name $plan.Name -Value $plan.Value -Context $Context
    }

    foreach ($plan in $servicePlans | Where-Object { $_.Start -eq 'disabled' }) {
        $records += Set-CPanServiceStartRegistry -ServiceName $plan.Name -Start 4 -Context $Context
    }

    foreach ($plan in $servicePlans | Where-Object { $_.Start -ne '<unchanged>' }) {
        $records += Invoke-CPanScCommand -Arguments @('config', $plan.Name, 'start=', $plan.Start) -Name $plan.Name -Message "Configured service $($plan.Name) start=$($plan.Start)." -Context $Context
    }

    foreach ($plan in $servicePlans | Where-Object { $_.Stop }) {
        $records += Invoke-CPanScCommand -Arguments @('stop', $plan.Name) -Name $plan.Name -Message "Requested stop for service $($plan.Name)." -Context $Context
    }

    $records += Invoke-CPanBitsReset -Context $Context

    foreach ($task in $taskPlans) {
        $records += Disable-CPanWindowsUpdateTask -TaskPath $task.TaskPath -TaskName $task.TaskName -Context $Context
    }

    $records += Invoke-CPanSystemWindowsUpdateHardening -Context $Context
    Start-Sleep -Seconds 2
    foreach ($service in Get-CPanServiceControlSnapshot) {
        $records += New-CPanDiagnosticRecord `
            -Type 'WindowsUpdateVerification' `
            -Severity 'Info' `
            -Name $service.Name `
            -Message 'Post-action service state.' `
            -Detail ("Status={0}; StartType={1}; DisplayName={2}" -f $service.Status, $service.StartType, $service.DisplayName)
    }

    return $records
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
    $blockers = @(Get-CPanProcessBlockers -ProcessNames $Target.ProcessNames)
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
            SizeOnDiskBytes = $measurement.SizeOnDiskBytes
            ReclaimableBytes = $measurement.ReclaimableBytes
            ItemCount = $measurement.ItemCount
            RemovedCount = $removedCount
            Path = $Target.Path
            Message = 'Path does not exist.'
            Recommendation = $Target.Recommendation
            ProcessBlockers = ($blockers -join '; ')
            MigrationSupport = $Target.MigrationSupport
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
            SizeOnDiskBytes = $measurement.SizeOnDiskBytes
            ReclaimableBytes = $measurement.ReclaimableBytes
            ItemCount = $measurement.ItemCount
            RemovedCount = $removedCount
            Path = $Target.Path
            Message = 'Run again as Administrator, or use the wrapper -Elevate switch.'
            Recommendation = $Target.Recommendation
            ProcessBlockers = ($blockers -join '; ')
            MigrationSupport = $Target.MigrationSupport
        }
    }

    if ($Apply -and $blockers.Count -gt 0) {
        Write-CPanLog -Context $Context -Level 'WARN' -Message "Skipping $($Target.Id); blocking processes: $($blockers -join ', ')"
        return [pscustomobject]@{
            Id = $Target.Id
            Name = $Target.Name
            Category = $Target.Category
            Risk = $Target.Risk
            Mode = $mode
            Status = 'BlockedByProcess'
            Exists = $measurement.Exists
            EstimatedMB = $measurement.EstimatedMB
            SizeOnDiskBytes = $measurement.SizeOnDiskBytes
            ReclaimableBytes = $measurement.ReclaimableBytes
            ItemCount = $measurement.ItemCount
            RemovedCount = $removedCount
            Path = $Target.Path
            Message = 'Close the listed application processes manually and preview again. CPanCleaner never ends them automatically.'
            Recommendation = $Target.Recommendation
            ProcessBlockers = ($blockers -join '; ')
            MigrationSupport = $Target.MigrationSupport
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
            SizeOnDiskBytes = $measurement.SizeOnDiskBytes
            ReclaimableBytes = $measurement.ReclaimableBytes
            ItemCount = $measurement.ItemCount
            RemovedCount = $removedCount
            Path = $Target.Path
            Message = 'Dry-run only. Pass -Apply to remove candidates.'
            Recommendation = $Target.Recommendation
            ProcessBlockers = ($blockers -join '; ')
            MigrationSupport = $Target.MigrationSupport
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
                SizeOnDiskBytes = $measurement.SizeOnDiskBytes
                ReclaimableBytes = $measurement.ReclaimableBytes
                ItemCount = $measurement.ItemCount
                RemovedCount = $removedCount
                Path = $Target.Path
                Message = 'NLSvc could not be stopped safely; nlstats.db was not removed.'
                Recommendation = $Target.Recommendation
                ProcessBlockers = ($blockers -join '; ')
                MigrationSupport = $Target.MigrationSupport
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
        } elseif ($Target.Category -eq 'NuGetCache') {
            $nugetCacheName = switch ($Target.Id) {
                'NuGetGlobalPackages' { 'global-packages' }
                'NuGetV3Cache' { 'http-cache' }
                'NuGetPluginsCache' { 'plugins-cache' }
                default { $null }
            }
            if (-not $nugetCacheName) {
                $status = 'PartialOrFailed'
                $errors += 'No official NuGet cache mapping exists for this target.'
            } else {
                $oldNuGetPackages = $env:NUGET_PACKAGES
                $userNuGetPackages = [Environment]::GetEnvironmentVariable('NUGET_PACKAGES', 'User')
                if (-not [string]::IsNullOrWhiteSpace($userNuGetPackages)) { $env:NUGET_PACKAGES = $userNuGetPackages }
                $nugetOutput = (& dotnet nuget locals $nugetCacheName --clear 2>&1 | Out-String).Trim()
                $nugetExitCode = $LASTEXITCODE
                $env:NUGET_PACKAGES = $oldNuGetPackages
                if ($nugetExitCode -eq 0) {
                    $status = 'Cleaned'
                    $removedCount = $measurement.ItemCount
                    Write-CPanLog -Context $Context -Level 'INFO' -Message "NuGet official cache clear completed: $nugetCacheName. $nugetOutput"
                } else {
                    $status = 'PartialOrFailed'
                    $errors += $nugetOutput
                }
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
        SizeOnDiskBytes = $measurement.SizeOnDiskBytes
        ReclaimableBytes = if ($status -eq 'Cleaned') { [int64] 0 } else { $measurement.ReclaimableBytes }
        ItemCount = $measurement.ItemCount
        RemovedCount = $removedCount
        Path = $Target.Path
        Message = ($errors -join ' | ')
        Recommendation = $Target.Recommendation
        ProcessBlockers = ($blockers -join '; ')
        MigrationSupport = $Target.MigrationSupport
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
            ($_.Name -eq 'git.exe' -or $_.Name -eq 'git-remote-http.exe' -or $_.Name -eq 'git-remote-https.exe') -and
            ($_.CommandLine -match 'fsmonitor--daemon|git fetch|git remote-http|git remote-https|remote-http|remote-https')
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

        $gitShellCacheProcesses = $processes | Where-Object {
            $_.Name -eq 'TGitCache.exe'
        }

        foreach ($process in $gitShellCacheProcesses) {
            $findings += [pscustomobject]@{
                Type = 'GitShellCache'
                Severity = 'Info'
                Name = $process.Name
                Id = $process.ProcessId
                Message = 'TortoiseGit shell cache helper is running. If Explorer or desktop file clicks are slow, OptimizePerformance can restart this cache helper.'
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
            Message = 'No stale Git fsmonitor/fetch/network helper, TortoiseGit cache, or Conda PowerShell helper processes were found.'
            Detail = ''
        }
    }

    return $findings
}

function Invoke-CPanCleaner {
    [CmdletBinding()]
    param(
        [ValidateSet('Scan', 'Clean', 'AnalyzeStorage', 'ReviewDownloads', 'Migrate', 'Diagnose', 'DisableWindowsUpdate', 'OptimizePerformance', 'PreventPerformanceSpikes', 'ManageGuard', 'RepairRunHistory')]
        [string] $Action = 'Scan',

        [string[]] $Include = @('Default'),

        [switch] $Apply,
        [switch] $DryRun,
        [int] $MinimumAgeDays = 1,
        [int] $MinimumAgeHours = -1,
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

    if ($Action -eq 'AnalyzeStorage') {
        $items = @(Get-CPanStorageAnalysis -AnalysisScope $AnalysisScope -MaxScanItems $MaxScanItems)
    } elseif ($Action -eq 'ReviewDownloads') {
        $items = @(Invoke-CPanDownloadReview -Context $context -SelectedItemTokens $SelectedItemTokens -Apply:$effectiveApply)
    } elseif ($Action -eq 'Migrate') {
        if ($MigrationTarget -ne 'NuGetPackages') { throw "Unsupported migration target: $MigrationTarget" }
        $items = @(Invoke-CPanNuGetMigration -Context $context -MigrationOperation $MigrationOperation -DestinationPath $DestinationPath -Apply:$effectiveApply)
    } elseif ($Action -eq 'Diagnose') {
        $diagnostics = @(Get-CPanDiagnostics -RepositoryPath $RepositoryPath)
    } elseif ($Action -eq 'DisableWindowsUpdate') {
        $diagnostics = @(Invoke-CPanDisableWindowsUpdateDownloads -Context $context -Apply:$effectiveApply -IsAdmin $isAdmin)
    } elseif ($Action -eq 'OptimizePerformance') {
        $diagnostics = @(Invoke-CPanOptimizePerformance -Context $context -RepositoryPath $RepositoryPath -Apply:$effectiveApply)
    } elseif ($Action -eq 'PreventPerformanceSpikes') {
        $diagnostics = @(Invoke-CPanPreventPerformanceSpikes -Context $context -RepositoryPath $RepositoryPath -Apply:$effectiveApply -IsAdmin $isAdmin)
    } elseif ($Action -eq 'ManageGuard') {
        $diagnostics = @(Invoke-CPanManageGuard -Context $context -GuardName $GuardName -GuardOperation $GuardOperation -IntervalMinutes $GuardIntervalMinutes -Apply:$effectiveApply -IsAdmin $isAdmin)
    } elseif ($Action -eq 'RepairRunHistory') {
        $diagnostics = @(Invoke-CPanRepairRunHistory -Context $context -Apply:$effectiveApply)
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
        Mode = if (($Action -in @('Clean','ReviewDownloads','Migrate','DisableWindowsUpdate','OptimizePerformance','PreventPerformanceSpikes','RepairRunHistory') -or ($Action -eq 'ManageGuard' -and $GuardOperation -ne 'Status')) -and $effectiveApply) { 'Apply' } elseif ($Action -in @('Clean','ReviewDownloads','Migrate','DisableWindowsUpdate','OptimizePerformance','PreventPerformanceSpikes','RepairRunHistory') -or ($Action -eq 'ManageGuard' -and $GuardOperation -ne 'Status')) { 'DryRun' } else { 'ReadOnly' }
        IsAdministrator = $isAdmin
        Include = ($Include -join ',')
        MinimumAgeDays = $MinimumAgeDays
        MinimumAgeHours = $MinimumAgeHours
        AnalysisScope = $AnalysisScope
        MigrationTarget = $MigrationTarget
        MigrationOperation = $MigrationOperation
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
    'Get-CPanBrowserCacheTargets',
    'Get-CPanStorageAnalysis',
    'Get-CPanProcessBlockers',
    'Get-CPanDiagnostics',
    'Invoke-CPanCleaner',
    'Test-CPanAdministrator',
    'Test-CPanPathSafety',
    'ConvertTo-CPanFullPath',
    'ConvertFrom-CPanDiskUsageCsv',
    'Measure-CPanPathSizeOnDisk',
    'Test-CPanDownloadFileSafety',
    'Invoke-CPanDownloadReview',
    'Test-CPanNuGetMigrationDestination',
    'Format-CPanBytes'
)
