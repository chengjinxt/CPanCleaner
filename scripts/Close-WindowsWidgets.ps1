param(
  [switch] $PersistUserSettings,
  [switch] $PersistMachinePolicy,
  [switch] $RestartExplorer
)

$ErrorActionPreference = 'Continue'

function Write-Step {
  param([string] $Message)
  Write-Host "[WindowsWidgets] $Message"
}

function Set-DwordValue {
  param(
    [Parameter(Mandatory = $true)][string] $Path,
    [Parameter(Mandatory = $true)][string] $Name,
    [Parameter(Mandatory = $true)][int] $Value
  )

  try {
    if (-not (Test-Path -LiteralPath $Path)) {
      New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
    }

    New-ItemProperty -Path $Path -Name $Name -PropertyType DWord -Value $Value -Force -ErrorAction Stop | Out-Null
    Write-Step "Set $Path\$Name = $Value"
  } catch {
    Write-Warning "Failed to set ${Path}\${Name}: $($_.Exception.Message)"
  }
}

Write-Step "Closing the current Widgets board/processes..."
Get-Process -Name Widgets,WidgetService -ErrorAction SilentlyContinue |
  Stop-Process -Force -ErrorAction SilentlyContinue

if ($PersistUserSettings) {
  Write-Step "Applying current-user settings to hide/disable Widgets entry points..."
  Set-DwordValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'TaskbarDa' -Value 0
  Set-DwordValue -Path 'HKCU:\Software\Policies\Microsoft\Dsh' -Name 'AllowNewsAndInterests' -Value 0
}

if ($PersistMachinePolicy) {
  $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
  )

  if (-not $isAdmin) {
    Write-Warning "Machine policy requires an elevated PowerShell session."
  } else {
    Write-Step "Applying machine policy to disable Widgets..."
    Set-DwordValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' -Name 'AllowNewsAndInterests' -Value 0
    Set-DwordValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' -Name 'DisableWidgetsBoard' -Value 1
    Set-DwordValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' -Name 'DisableWidgetsOnLockScreen' -Value 1
  }
}

if ($RestartExplorer) {
  Write-Step "Restarting Explorer so taskbar settings can take effect..."
  Get-Process -Name explorer -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Process explorer.exe
}

Start-Sleep -Milliseconds 500
$remaining = Get-Process -Name Widgets,WidgetService -ErrorAction SilentlyContinue
if ($remaining) {
  Write-Warning "Widgets background process is still present or was restarted by Windows. The visible board should still be closed."
  $remaining | Select-Object ProcessName,Id,Path
} else {
  Write-Step "Widgets board/processes are closed."
}
