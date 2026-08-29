namespace CPanCleaner.Gui.Models;

public sealed class OperationResult
{
    public string Version { get; set; } = string.Empty;
    public string Action { get; set; } = string.Empty;
    public string Mode { get; set; } = string.Empty;
    public bool IsAdministrator { get; set; }
    public string LogPath { get; set; } = string.Empty;
    public string RawOutput { get; set; } = string.Empty;
    public bool WasElevated { get; set; }
    public List<OperationItem> Items { get; } = new();
}

public sealed class OperationItem
{
    public string Type { get; set; } = string.Empty;
    public string Name { get; set; } = string.Empty;
    public string Status { get; set; } = string.Empty;
    public string Risk { get; set; } = string.Empty;
    public double? EstimatedMB { get; set; }
    public string Path { get; set; } = string.Empty;
    public string Message { get; set; } = string.Empty;
}
