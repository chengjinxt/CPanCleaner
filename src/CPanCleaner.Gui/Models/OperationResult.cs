using System.ComponentModel;

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

public sealed class OperationItem : INotifyPropertyChanged
{
    private bool _isSelected;

    public event PropertyChangedEventHandler? PropertyChanged;

    public string Type { get; set; } = string.Empty;
    public string Name { get; set; } = string.Empty;
    public string Status { get; set; } = string.Empty;
    public string Risk { get; set; } = string.Empty;
    public double? EstimatedMB { get; set; }
    public long SizeOnDiskBytes { get; set; }
    public long ReclaimableBytes { get; set; }
    public string Path { get; set; } = string.Empty;
    public string Message { get; set; } = string.Empty;
    public string Recommendation { get; set; } = string.Empty;
    public string ProcessBlockers { get; set; } = string.Empty;
    public string MigrationSupport { get; set; } = string.Empty;
    public bool CanSelect { get; set; }
    public string[] CleanupTargetIds { get; set; } = Array.Empty<string>();
    public string IdentityToken { get; set; } = string.Empty;
    public string Sha256 { get; set; } = string.Empty;
    public string Publisher { get; set; } = string.Empty;
    public string LastWriteTime { get; set; } = string.Empty;
    public string Extension { get; set; } = string.Empty;

    public bool IsSelected
    {
        get => _isSelected;
        set
        {
            if (_isSelected == value || !CanSelect)
            {
                return;
            }
            _isSelected = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(IsSelected)));
        }
    }

    public string DisplaySize => SizeOnDiskBytes > 0
        ? SizeOnDiskBytes >= 1024L * 1024L * 1024L
            ? $"{SizeOnDiskBytes / 1024d / 1024d / 1024d:N2} GB"
            : $"{SizeOnDiskBytes / 1024d / 1024d:N2} MB"
        : EstimatedMB is null ? string.Empty : $"{EstimatedMB:N2} MB";

    public string DetailText => string.Join("；", new[] { Recommendation, Message }
        .Where(value => !string.IsNullOrWhiteSpace(value)));
}
