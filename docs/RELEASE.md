# 发布与跨电脑使用

## 发布前验证

在项目根目录执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Test-CPanCleaner.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action Scan
powershell -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action Clean
Get-FileHash .\CPanCleaner.ps1 -Algorithm SHA256
```

测试、扫描和 dry-run 均通过后再发布。发布说明中记录版本号、Git 提交号和 SHA256。

## 发布内容

最终交付只包含一个文件：

```text
CPanCleaner.ps1
```

README、测试、日志和历史脚本不需要复制到使用者电脑。建议使用 Git tag，例如 `v1.0.0`，并把该提交中的 `CPanCleaner.ps1` 作为发布附件。

## 其他电脑首次使用

1. 将 `CPanCleaner.ps1` 放到一个普通目录。
2. 将本机计算出的 SHA256 与发布说明对比。
3. 如果 Windows 标记文件来自互联网，执行 `Unblock-File .\CPanCleaner.ps1`。
4. 先运行 `Scan`，再运行不带 `-Apply` 的 `Clean`。
5. 确认候选路径和估算容量后，才运行 `Clean -Apply`；需要系统缓存时加 `-Elevate`。

```powershell
Get-FileHash .\CPanCleaner.ps1 -Algorithm SHA256
powershell -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action Scan
powershell -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action Clean
powershell -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action Clean -Apply -Elevate
```

## 回滚

清理删除的缓存通常由系统或应用按需重建，但删除动作本身不可撤销。遇到异常时停止使用新版本，换回上一个已发布的 `CPanCleaner.ps1`；不要通过扩大脚本权限或手工删除受保护目录来补救。
