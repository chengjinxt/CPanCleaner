

# Windows Management Instrumentation CPU占用高

`Windows Management Instrumentation` 一直运行本身正常；持续占 CPU 的主要原因，是向日葵守护进程 `awesun_guard.exe` 注册了每 4 秒扫描一次进程创建/退出的 WMI 查询。CPanCleaner 已把它降为 `BelowNormal`，但没有消除这个查询