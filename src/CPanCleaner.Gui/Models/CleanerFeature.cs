using System.Text.Json.Serialization;

namespace CPanCleaner.Gui.Models;

public sealed class CleanerFeature
{
    public string Id { get; set; } = string.Empty;
    public string Title { get; set; } = string.Empty;
    public string Risk { get; set; } = "Low";
    public string Group { get; set; } = string.Empty;
    public string Summary { get; set; } = string.Empty;
    public string Principle { get; set; } = string.Empty;
    public string Impact { get; set; } = string.Empty;
    public string Safeguards { get; set; } = string.Empty;
    public string History { get; set; } = string.Empty;
    public string OperationKind { get; set; } = "Cleaner";
    public string Action { get; set; } = "Clean";
    public string[] Includes { get; set; } = Array.Empty<string>();
    public string[] AffectedPaths { get; set; } = Array.Empty<string>();
    public bool RequiresAdministrator { get; set; }
    public bool SupportsApply { get; set; } = true;
    public bool RestartExplorer { get; set; }
    public bool SupportsSchedule { get; set; }
    public string GuardName { get; set; } = string.Empty;
    public int DefaultIntervalMinutes { get; set; } = 15;
    public string PreviewLabel { get; set; } = "扫描 / 预览";
    public string ApplyLabel { get; set; } = "执行所选功能";
    public string ApplyWarning { get; set; } = string.Empty;

    [JsonIgnore]
    public string RiskText => Risk switch
    {
        "Low" => "低风险",
        "Medium" => "中等风险",
        "High" => "高风险",
        _ => Risk
    };

    [JsonIgnore]
    public string AccentBrush => Risk switch
    {
        "Low" => "#16794C",
        "Medium" => "#B45309",
        "High" => "#B42318",
        _ => "#475467"
    };

    [JsonIgnore]
    public string AdministratorText => RequiresAdministrator ? "需要管理员权限" : "普通权限可运行";

    [JsonIgnore]
    public string ScheduleText => SupportsSchedule ? $"可设置周期（默认 {DefaultIntervalMinutes} 分钟）" : string.Empty;
}
