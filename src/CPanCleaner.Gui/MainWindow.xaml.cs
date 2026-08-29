using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.CompilerServices;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using CPanCleaner.Gui.Models;
using CPanCleaner.Gui.Services;

namespace CPanCleaner.Gui;

public partial class MainWindow : Window, INotifyPropertyChanged
{
    private readonly CleanerBackend _backend;
    private CancellationTokenSource? _operationCancellation;
    private CleanerFeature? _selectedFeature;
    private string _driveText = "读取中…";
    private string _administratorText = string.Empty;
    private string _statusText = "选择左侧功能查看原理和影响，然后先运行预览。";
    private bool _isBusy;

    public MainWindow()
    {
        InitializeComponent();
        DataContext = this;

        try
        {
            _backend = new CleanerBackend();
            var features = FeatureCatalog.Load();
            BindFeatureList(LowRiskList, features.Where(feature => feature.Risk == "Low"));
            BindFeatureList(MediumRiskList, features.Where(feature => feature.Risk == "Medium"));
            BindFeatureList(HighRiskList, features.Where(feature => feature.Risk == "High"));
            LowRiskList.SelectedIndex = 0;
        }
        catch (Exception exception)
        {
            MessageBox.Show(this, exception.Message, "CPanCleaner 初始化失败", MessageBoxButton.OK, MessageBoxImage.Error);
            _backend = null!;
            PreviewButton.IsEnabled = false;
            ApplyButton.IsEnabled = false;
            StatusText = exception.Message;
        }

        AdministratorText = CleanerBackend.IsAdministrator() ? "管理员" : "标准用户（需要时触发 UAC）";
        RefreshDriveStatus();
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    public ObservableCollection<OperationItem> Results { get; } = new();

    public CleanerFeature? SelectedFeature
    {
        get => _selectedFeature;
        private set
        {
            if (ReferenceEquals(_selectedFeature, value))
            {
                return;
            }
            _selectedFeature = value;
            OnPropertyChanged();
            UpdateButtonState();
        }
    }

    public string DriveText
    {
        get => _driveText;
        private set { _driveText = value; OnPropertyChanged(); }
    }

    public string AdministratorText
    {
        get => _administratorText;
        private set { _administratorText = value; OnPropertyChanged(); }
    }

    public string StatusText
    {
        get => _statusText;
        private set { _statusText = value; OnPropertyChanged(); }
    }

    public bool IsBusy
    {
        get => _isBusy;
        private set
        {
            _isBusy = value;
            OnPropertyChanged();
            UpdateButtonState();
        }
    }

    private static void BindFeatureList(ListBox listBox, IEnumerable<CleanerFeature> features)
    {
        var collection = new ObservableCollection<CleanerFeature>(
            features.OrderBy(feature => feature.Group).ThenBy(feature => feature.Title));
        var view = new ListCollectionView(collection);
        view.GroupDescriptions.Add(new PropertyGroupDescription(nameof(CleanerFeature.Group)));
        listBox.ItemsSource = view;
    }

    private async void FeatureList_OnSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (sender is not ListBox selectedList || selectedList.SelectedItem is not CleanerFeature feature)
        {
            return;
        }

        foreach (var list in new[] { LowRiskList, MediumRiskList, HighRiskList })
        {
            if (!ReferenceEquals(list, selectedList))
            {
                list.SelectedItem = null;
            }
        }
        SelectedFeature = feature;
        var usesMinimumAge = feature.Action.Equals("Clean", StringComparison.OrdinalIgnoreCase) ||
                             feature.Action.Equals("Scan", StringComparison.OrdinalIgnoreCase);
        MinimumAgePanel.Visibility = usesMinimumAge ? Visibility.Visible : Visibility.Collapsed;
        GuardSchedulePanel.Visibility = feature.SupportsSchedule ? Visibility.Visible : Visibility.Collapsed;
        DisableGuardButton.Visibility = feature.SupportsSchedule ? Visibility.Visible : Visibility.Collapsed;
        if (feature.SupportsSchedule)
        {
            GuardIntervalMinutesBox.Text = feature.DefaultIntervalMinutes.ToString();
        }
        StatusText = $"已选择：{feature.Title}。建议先运行“{feature.PreviewLabel}”。";
        if (feature.SupportsSchedule)
        {
            await RunSelectedFeatureAsync(apply: false, guardOperation: "Status", automaticStatusRefresh: true);
        }
    }

    private void RiskTabs_OnSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!ReferenceEquals(e.Source, RiskTabs))
        {
            return;
        }

        var list = RiskTabs.SelectedIndex switch
        {
            0 => LowRiskList,
            1 => MediumRiskList,
            2 => HighRiskList,
            _ => null
        };
        if (list is not null && list.SelectedItem is null && list.Items.Count > 0)
        {
            list.SelectedIndex = 0;
        }
    }

    private async void PreviewButton_OnClick(object sender, RoutedEventArgs e)
    {
        await RunSelectedFeatureAsync(apply: false, guardOperation: SelectedFeature?.SupportsSchedule == true ? "Status" : null);
    }

    private async void ApplyButton_OnClick(object sender, RoutedEventArgs e)
    {
        if (SelectedFeature is null || !SelectedFeature.SupportsApply || !ConfirmApply(SelectedFeature))
        {
            return;
        }
        await RunSelectedFeatureAsync(apply: true, guardOperation: SelectedFeature.SupportsSchedule ? "Enable" : null);
    }

    private async void DisableGuardButton_OnClick(object sender, RoutedEventArgs e)
    {
        var feature = SelectedFeature;
        if (feature is null || !feature.SupportsSchedule)
        {
            return;
        }

        var message = $"将关闭并移除 {feature.GuardName} 计划任务。\n\n这会停止周期执行，但不会还原它或相关功能此前写入的 Git、注册表、服务或 Windows Update 策略。\n\n确认继续吗？";
        if (MessageBox.Show(this, message, "关闭计划任务", MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes)
        {
            return;
        }
        await RunSelectedFeatureAsync(apply: true, guardOperation: "Disable");
    }

    private async Task RunSelectedFeatureAsync(bool apply, string? guardOperation = null, bool automaticStatusRefresh = false)
    {
        var feature = SelectedFeature;
        if (feature is null || _backend is null)
        {
            return;
        }

        var minimumAgeDays = 1;
        var usesMinimumAge = feature.Action.Equals("Clean", StringComparison.OrdinalIgnoreCase) ||
                             feature.Action.Equals("Scan", StringComparison.OrdinalIgnoreCase);
        if (usesMinimumAge && (!int.TryParse(MinimumAgeDaysBox.Text.Trim(), out minimumAgeDays) || minimumAgeDays is < 0 or > 3650))
        {
            MessageBox.Show(this, "最小保留天数必须是 0 到 3650 之间的整数。", "输入无效", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }

        var guardIntervalMinutes = feature.DefaultIntervalMinutes;
        if (feature.SupportsSchedule && (!int.TryParse(GuardIntervalMinutesBox.Text.Trim(), out guardIntervalMinutes) || guardIntervalMinutes is < 5 or > 1440))
        {
            MessageBox.Show(this, "计划任务执行周期必须是 5 到 1440 之间的整数（分钟）。", "输入无效", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }

        Results.Clear();
        _operationCancellation?.Cancel();
        var operationCancellation = new CancellationTokenSource();
        _operationCancellation = operationCancellation;
        IsBusy = true;
        StatusText = automaticStatusRefresh ? $"正在读取 {feature.GuardName} 状态…" : apply ? $"正在执行：{feature.Title}…" : $"正在预览：{feature.Title}…";

        try
        {
            var result = await _backend.RunAsync(feature, apply, minimumAgeDays, operationCancellation.Token, guardOperation, guardIntervalMinutes);
            if (!ReferenceEquals(SelectedFeature, feature))
            {
                return;
            }
            foreach (var item in result.Items)
            {
                Results.Add(item);
            }
            if (feature.SupportsSchedule && string.Equals(guardOperation, "Status", StringComparison.OrdinalIgnoreCase))
            {
                var intervalMatch = result.Items
                    .Select(item => Regex.Match(item.Path, @"(?:^|;) IntervalMinutes=(\d+)(?:;|$)"))
                    .FirstOrDefault(match => match.Success);
                if (intervalMatch is not null && intervalMatch.Success)
                {
                    GuardIntervalMinutesBox.Text = intervalMatch.Groups[1].Value;
                }
            }
            if (result.Items.Count == 0)
            {
                Results.Add(new OperationItem
                {
                    Type = "Summary",
                    Name = feature.Title,
                    Status = result.Mode,
                    Message = "后端未报告需要处理的目标。"
                });
            }

            var logPart = string.IsNullOrWhiteSpace(result.LogPath) ? string.Empty : $" 日志：{result.LogPath}";
            StatusText = feature.SupportsSchedule
                ? $"任务状态已更新 · {result.Mode} · {result.Items.Count} 条结果。{logPart}"
                : $"完成 · {result.Mode} · {result.Items.Count} 条结果。{logPart}";
            if (result.WasElevated)
            {
                StatusText += " 管理员操作完成；建议再次预览确认当前状态。";
            }
        }
        catch (OperationCanceledException)
        {
            StatusText = "操作已取消。已经完成的外部系统操作无法自动回滚，请查看日志确认。";
        }
        catch (Win32Exception exception) when (exception.NativeErrorCode == 1223)
        {
            StatusText = "已取消 UAC 授权，未启动管理员操作。";
        }
        catch (Exception exception)
        {
            StatusText = "执行失败：" + exception.Message;
            Results.Add(new OperationItem
            {
                Type = "Error",
                Name = feature.Title,
                Status = "Failed",
                Message = exception.Message
            });
        }
        finally
        {
            operationCancellation.Dispose();
            if (ReferenceEquals(_operationCancellation, operationCancellation))
            {
                _operationCancellation = null;
                IsBusy = false;
                RefreshDriveStatus();
            }
        }
    }

    private bool ConfirmApply(CleanerFeature feature)
    {
        if (feature.Risk == "High")
        {
            var dialog = new HighRiskConfirmationWindow(feature) { Owner = this };
            return dialog.ShowDialog() == true;
        }

        var message = feature.Risk == "Medium"
            ? $"这是中等风险操作。\n\n{feature.Impact}\n\n确认已查看预览结果并继续吗？"
            : $"将执行：{feature.Title}\n\n真实清理不可撤销，确认已查看预览结果吗？";
        return MessageBox.Show(this, message, "确认执行", MessageBoxButton.YesNo, MessageBoxImage.Warning) == MessageBoxResult.Yes;
    }

    private void CancelButton_OnClick(object sender, RoutedEventArgs e)
    {
        _operationCancellation?.Cancel();
    }

    private void OpenLogsButton_OnClick(object sender, RoutedEventArgs e)
    {
        if (_backend is null)
        {
            return;
        }
        Directory.CreateDirectory(_backend.LogsDirectory);
        Process.Start(new ProcessStartInfo
        {
            FileName = "explorer.exe",
            ArgumentList = { _backend.LogsDirectory },
            UseShellExecute = true
        });
    }

    private void RefreshDriveStatus()
    {
        try
        {
            var drive = new DriveInfo(Path.GetPathRoot(Environment.SystemDirectory) ?? "C:\\");
            var freeGb = drive.AvailableFreeSpace / 1024d / 1024d / 1024d;
            var totalGb = drive.TotalSize / 1024d / 1024d / 1024d;
            var percent = drive.TotalSize == 0 ? 0 : drive.AvailableFreeSpace * 100d / drive.TotalSize;
            DriveText = $"可用 {freeGb:N1} / {totalGb:N1} GB（{percent:N1}%）";
        }
        catch (Exception exception)
        {
            DriveText = "读取失败：" + exception.Message;
        }
    }

    private void UpdateButtonState()
    {
        if (!IsInitialized)
        {
            return;
        }
        PreviewButton.IsEnabled = SelectedFeature is not null && !IsBusy;
        ApplyButton.IsEnabled = SelectedFeature is { SupportsApply: true } && !IsBusy;
    }

    private void OnPropertyChanged([CallerMemberName] string? propertyName = null)
    {
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
    }
}
