# 关闭 Windows 小组件/天气面板

截图中的「早上好」「天气」「市场」面板是 Windows 11 Widgets（小组件）面板。它可能由任务栏天气入口、`Win+W`、通知或误触打开。

## 快速关闭当前面板

在仓库根目录运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Close-WindowsWidgets.ps1
```

或者直接双击：

```text
Run-Close-WindowsWidgets.bat
```

这个命令只关闭当前 `Widgets` / `WidgetService` 进程，不会重启电脑，也不会删除文件。Windows 可能会重新拉起后台进程，但可见面板通常会被关掉。

## 尝试隐藏任务栏入口

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Close-WindowsWidgets.ps1 -PersistUserSettings
```

它会尝试写入当前用户设置：

```text
HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDa = 0
HKCU\Software\Policies\Microsoft\Dsh\AllowNewsAndInterests = 0
```

如果注册表被系统策略保护，脚本会打印 `Failed to set ... Access is denied`。这种情况下使用下面的图形界面方式更稳。

## 图形界面关闭入口

1. 打开 Windows「设置」。
2. 进入「个性化」->「任务栏」。
3. 关闭「小组件」。

如果主要是天气预警通知烦人：

1. 打开 Windows「设置」。
2. 进入「系统」->「通知」。
3. 找到「Widgets」或「天气」，关闭通知。

## 彻底禁用小组件策略

管理员 PowerShell 中运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Close-WindowsWidgets.ps1 -PersistMachinePolicy -RestartExplorer
```

脚本会尝试写入：

```text
HKLM\SOFTWARE\Policies\Microsoft\Dsh\AllowNewsAndInterests = 0
HKLM\SOFTWARE\Policies\Microsoft\Dsh\DisableWidgetsBoard = 1
HKLM\SOFTWARE\Policies\Microsoft\Dsh\DisableWidgetsOnLockScreen = 1
```

某些机器即使当前账号是管理员，也可能因为注册表 ACL、公司策略或系统保护而拒绝写入。这时不要强行改权限，优先使用「设置」里的任务栏/通知开关。

## 恢复方式

需要恢复时，把「设置」->「个性化」->「任务栏」->「小组件」重新打开即可。

如果之前成功写入了策略值，可以在管理员 PowerShell 中删除这些值后重启 Explorer 或注销重登：

```powershell
reg delete HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced /v TaskbarDa /f
reg delete HKCU\Software\Policies\Microsoft\Dsh /v AllowNewsAndInterests /f
reg delete HKLM\SOFTWARE\Policies\Microsoft\Dsh /v AllowNewsAndInterests /f
reg delete HKLM\SOFTWARE\Policies\Microsoft\Dsh /v DisableWidgetsBoard /f
reg delete HKLM\SOFTWARE\Policies\Microsoft\Dsh /v DisableWidgetsOnLockScreen /f
```
