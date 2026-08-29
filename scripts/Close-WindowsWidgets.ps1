[CmdletBinding()]
param(
    [ValidateSet('Close', 'PersistUser', 'PersistMachine')]
    [string] $Action = 'Close',

    [switch] $Apply,
    [switch] $DryRun,
    [switch] $RestartExplorer,

    # Backward-compatible switches from the historical helper.
    [switch] $PersistUserSettings,
    [switch] $PersistMachinePolicy,
    [string] $JsonOutputPath,
    [switch] $Json
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ($Apply -and $DryRun) {
    throw 'Use either -Apply or -DryRun, not both.'
}

if ($PersistMachinePolicy) {
    $Action = 'PersistMachine'
} elseif ($PersistUserSettings) {
    $Action = 'PersistUser'
}

$effectiveApply = [bool] ($Apply -and -not $DryRun)
$records = @()

function Test-WidgetsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Add-WidgetsRecord {
    param(
        [string] $Name,
        [string] $Status,
        [string] $Message,
        [string] $Detail = ''
    )

    $script:records += [pscustomobject]@{
        Type = 'WindowsWidgets'
        Severity = if ($Status -in @('Failed', 'NeedsAdministrator')) { 'Error' } elseif ($Status -eq 'Warning') { 'Warning' } else { 'Info' }
        Name = $Name
        Status = $Status
        Message = $Message
        Detail = $Detail
    }
}

function Set-WidgetsDWord {
    param(
        [string] $Path,
        [string] $Name,
        [int] $Value
    )

    $display = "$Path\$Name=$Value"
    if (-not $effectiveApply) {
        Add-WidgetsRecord -Name $Name -Status 'WouldSet' -Message 'Dry-run: registry value would be set.' -Detail $display
        return
    }

    try {
        if (-not (Test-Path -LiteralPath $Path)) {
            New-Item -Path $Path -Force | Out-Null
        }
        New-ItemProperty -Path $Path -Name $Name -PropertyType DWord -Value $Value -Force | Out-Null
        Add-WidgetsRecord -Name $Name -Status 'Completed' -Message 'Registry value was set.' -Detail $display
    } catch {
        Add-WidgetsRecord -Name $Name -Status 'Failed' -Message 'Registry value could not be set.' -Detail $_.Exception.Message
    }
}

function Invoke-CloseWidgets {
    $widgets = @(Get-Process -Name 'Widgets', 'WidgetService' -ErrorAction SilentlyContinue)
    if ($widgets.Count -eq 0) {
        Add-WidgetsRecord -Name 'WidgetsProcess' -Status 'NotRunning' -Message 'Windows Widgets processes are not running.'
        return
    }

    foreach ($process in $widgets) {
        $detail = "$($process.ProcessName) PID=$($process.Id)"
        if (-not $effectiveApply) {
            Add-WidgetsRecord -Name 'WidgetsProcess' -Status 'WouldClose' -Message 'Dry-run: the current Widgets process would be closed.' -Detail $detail
            continue
        }

        try {
            Stop-Process -Id $process.Id -Force
            Add-WidgetsRecord -Name 'WidgetsProcess' -Status 'Completed' -Message 'The current Widgets process was closed.' -Detail $detail
        } catch {
            Add-WidgetsRecord -Name 'WidgetsProcess' -Status 'Failed' -Message 'The Widgets process could not be closed.' -Detail $_.Exception.Message
        }
    }
}

$isAdmin = Test-WidgetsAdministrator
Invoke-CloseWidgets

if ($Action -eq 'PersistUser' -or $Action -eq 'PersistMachine') {
    Set-WidgetsDWord -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'TaskbarDa' -Value 0
    Set-WidgetsDWord -Path 'HKCU:\Software\Policies\Microsoft\Dsh' -Name 'AllowNewsAndInterests' -Value 0
}

if ($Action -eq 'PersistMachine') {
    if (-not $isAdmin) {
        Add-WidgetsRecord -Name 'MachinePolicy' -Status 'NeedsAdministrator' -Message 'Machine-wide Widgets policy requires administrator rights.'
    } else {
        Set-WidgetsDWord -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' -Name 'AllowNewsAndInterests' -Value 0
        Set-WidgetsDWord -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' -Name 'DisableWidgetsBoard' -Value 1
        Set-WidgetsDWord -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' -Name 'DisableWidgetsOnLockScreen' -Value 1
    }
}

if ($RestartExplorer) {
    if (-not $effectiveApply) {
        Add-WidgetsRecord -Name 'Explorer' -Status 'WouldRestart' -Message 'Dry-run: Explorer would be restarted so taskbar settings take effect.'
    } else {
        try {
            Get-Process -Name explorer -ErrorAction SilentlyContinue | Stop-Process -Force
            Start-Process explorer.exe
            Add-WidgetsRecord -Name 'Explorer' -Status 'Completed' -Message 'Explorer was restarted.'
        } catch {
            Add-WidgetsRecord -Name 'Explorer' -Status 'Failed' -Message 'Explorer could not be restarted.' -Detail $_.Exception.Message
        }
    }
}

$summary = [pscustomobject]@{
    Version = '2.0.0'
    Action = "Widgets:$Action"
    Mode = if ($effectiveApply) { 'Apply' } else { 'DryRun' }
    IsAdministrator = $isAdmin
    Items = @()
    Diagnostics = @($records)
}

$jsonResult = $null
if ($Json -or $JsonOutputPath) {
    $jsonResult = $summary | ConvertTo-Json -Depth 6
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

$summary.Diagnostics | Format-Table Name, Status, Message, Detail -AutoSize
if (-not $effectiveApply) {
    Write-Host ''
    Write-Host 'Dry-run complete. Re-run with -Apply to make the listed Widgets changes.'
}
