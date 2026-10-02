using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.CompilerServices;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Input;
using System.Windows.Media;
using CPanCleaner.Gui.Models;
using CPanCleaner.Gui.Services;
using MessageBox = System.Windows.MessageBox;

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

    private static void BindFeatureList(System.Windows.Controls.ListBox listBox, IEnumerable<CleanerFeature> features)
    {
        var collection = new ObservableCollection<CleanerFeature>(
            features.OrderBy(feature => feature.Group).ThenBy(feature => feature.Title));
        var view = new ListCollectionView(collection);
        view.GroupDescriptions.Add(new PropertyGroupDescription(nameof(CleanerFeature.Group)));
        listBox.ItemsSource = view;
    }

    private async void FeatureList_OnSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (sender is not System.Windows.Controls.ListBox selectedList || selectedList.SelectedItem is not CleanerFeature feature)
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
        Results.Clear();
        UpdateButtonState();
        var usesMinimumAge = feature.Action.Equals("Clean", StringComparison.OrdinalIgnoreCase) ||
                             feature.Action.Equals("Scan", StringComparison.OrdinalIgnoreCase);
        MinimumAgePanel.Visibility = usesMinimumAge ? Visibility.Visible : Visibility.Collapsed;
        GuardSchedulePanel.Visibility = feature.SupportsSchedule ? Visibility.Visible : Visibility.Collapsed;
        DestinationPanel.Visibility = feature.RequiresDestination ? Visibility.Visible : Visibility.Collapsed;
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
        if (SelectedFeature is null || !SelectedFeature.SupportsApply)
        {
            return;
        }
        if (SelectedFeature.OperationKind.Equals("Guidance", StringComparison.OrdinalIgnoreCase))
        {
            var executable = Environment.ExpandEnvironmentVariables(SelectedFeature.GuidanceExecutable);
            if (!string.IsNullOrWhiteSpace(executable) && File.Exists(executable))
            {
                Process.Start(new ProcessStartInfo { FileName = executable, UseShellExecute = true });
                StatusText = $"已打开 {SelectedFeature.Title} 对应的官方管理程序；CPanCleaner 未移动或删除数据。";
            }
            else if (Uri.TryCreate(SelectedFeature.GuidanceUrl, UriKind.Absolute, out var guidanceUri))
            {
                Process.Start(new ProcessStartInfo { FileName = guidanceUri.AbsoluteUri, UseShellExecute = true });
                StatusText = $"已打开 {SelectedFeature.Title} 的官方说明；CPanCleaner 未修改任何数据。";
            }
            return;
        }
        if (SelectedFeature.RequiresDestination && string.IsNullOrWhiteSpace(DestinationPathBox.Text))
        {
            MessageBox.Show(this, "请先选择非 C 盘本地 NTFS 空目录。", "缺少迁移目标", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }
        if (SelectedFeature.SelectableResults && !Results.Any(item => item.CanSelect && item.IsSelected))
        {
            MessageBox.Show(this, "请先在预览结果中勾选要清理的白名单缓存或要永久删除的文件。", "尚未选择项目", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }
        if (!ConfirmApply(SelectedFeature))
        {
            return;
        }
        await RunSelectedFeatureAsync(apply: true, guardOperation: SelectedFeature.SupportsSchedule ? "Enable" : null);
    }

    private void BrowseDestinationButton_OnClick(object sender, RoutedEventArgs e)
    {
        using var dialog = new System.Windows.Forms.FolderBrowserDialog
        {
            Description = "选择非 C 盘本地 NTFS 空目录",
            UseDescriptionForTitle = true,
            ShowNewFolderButton = true
        };
        if (dialog.ShowDialog() == System.Windows.Forms.DialogResult.OK)
        {
            DestinationPathBox.Text = dialog.SelectedPath;
        }
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

        var selectedTokens = apply && feature.SelectableResults
            ? Results.Where(item => item.CanSelect && item.IsSelected && !string.IsNullOrWhiteSpace(item.IdentityToken))
                .Select(item => item.IdentityToken).ToArray()
            : Array.Empty<string>();
        var selectedCleanupTargetIds = apply && feature.Action.Equals("AnalyzeStorage", StringComparison.OrdinalIgnoreCase)
            ? OperationSelection.GetCleanupTargetIds(Results)
            : Array.Empty<string>();
        Results.Clear();
        _operationCancellation?.Cancel();
        var operationCancellation = new CancellationTokenSource();
        _operationCancellation = operationCancellation;
        IsBusy = true;
        StatusText = automaticStatusRefresh ? $"正在读取 {feature.GuardName} 状态…" : apply ? $"正在执行：{feature.Title}…" : $"正在预览：{feature.Title}…";

        try
        {
            var result = await _backend.RunAsync(
                feature,
                apply,
                minimumAgeDays,
                operationCancellation.Token,
                guardOperation,
                guardIntervalMinutes,
                feature.RequiresDestination ? DestinationPathBox.Text.Trim() : null,
                selectedTokens,
                selectedCleanupTargetIds);
            if (!ReferenceEquals(SelectedFeature, feature))
            {
                return;
            }
            foreach (var item in result.Items)
            {
                item.PropertyChanged += OperationItem_OnPropertyChanged;
                Results.Add(item);
            }
            UpdateButtonState();
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
        if (feature.Action.Equals("AnalyzeStorage", StringComparison.OrdinalIgnoreCase))
        {
            var selected = Results.Where(item => item.CanSelect && item.IsSelected).ToArray();
            if (selected.Any(item => item.Risk.Equals("High", StringComparison.OrdinalIgnoreCase)))
            {
                MessageBox.Show(this, "空间分析页不允许直接执行高风险建议；请使用对应的高风险功能或官方迁移入口。", "不能直接清理", MessageBoxButton.OK, MessageBoxImage.Warning);
                return false;
            }
            var reclaimable = selected.Sum(item => item.ReclaimableBytes);
            var riskText = selected.Any(item => item.Risk.Equals("Medium", StringComparison.OrdinalIgnoreCase))
                ? "包含中等风险缓存，清理后可能需要重新下载或重建。"
                : "所选项目均映射到低风险精确缓存白名单。";
            var details = string.Join("\n", selected.Take(8).Select(item => $"• {item.Name}：{item.Recommendation}"));
            if (selected.Length > 8)
            {
                details += $"\n…另有 {selected.Length - 8} 项";
            }
            var analysisMessage = $"将按建议清理 {selected.Length} 项可重建缓存，预计最多释放 {reclaimable / 1024d / 1024d / 1024d:N2} GB。\n\n{riskText}\n\n{details}\n\n只会执行结果携带的精确白名单目标，不会删除表格中的整个用户数据目录；仍被进程占用的目标会安全跳过。确认继续吗？";
            return MessageBox.Show(this, analysisMessage, "确认清理所选建议", MessageBoxButton.YesNo, MessageBoxImage.Warning) == MessageBoxResult.Yes;
        }

        if (feature.Risk == "High")
        {
            var selected = Results.Where(item => item.CanSelect && item.IsSelected).ToArray();
            var details = selected.Length == 0
                ? null
                : $"本次明确勾选 {selected.Length} 个文件，共 {selected.Sum(item => item.SizeOnDiskBytes) / 1024d / 1024d / 1024d:N2} GB：\n" +
                  string.Join("\n", selected.Take(8).Select(item => "• " + item.Name)) +
                  (selected.Length > 8 ? $"\n…另有 {selected.Length - 8} 个文件" : string.Empty);
            var dialog = new HighRiskConfirmationWindow(feature, details) { Owner = this };
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

    private void OperationItem_OnPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(OperationItem.IsSelected))
        {
            UpdateButtonState();
        }
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

    private void ResultGrid_OnPreviewMouseRightButtonDown(object sender, MouseButtonEventArgs e)
    {
        var current = e.OriginalSource as DependencyObject;
        while (current is not null && current is not DataGridRow)
        {
            current = GetParentObject(current);
        }

        if (current is DataGridRow row)
        {
            ResultGrid.SelectedItem = row.Item;
            row.Focus();
        }
        else
        {
            ResultGrid.SelectedItem = null;
        }
    }

    private void ResultContextMenu_OnOpened(object sender, RoutedEventArgs e)
    {
        var canOpen = TryResolveResultLocation(ResultGrid.SelectedItem as OperationItem, out _, out _);
        OpenResultLocationMenuItem.IsEnabled = canOpen;
        OpenResultLocationMenuItem.ToolTip = canOpen
            ? null
            : "所选结果不是当前存在的本地文件或文件夹。";
    }

    private void OpenResultLocationMenuItem_OnClick(object sender, RoutedEventArgs e)
    {
        if (!TryResolveResultLocation(ResultGrid.SelectedItem as OperationItem, out var location, out var isFile))
        {
            MessageBox.Show(this, "所选结果没有可打开的本地文件位置。", "无法打开位置", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }

        try
        {
            var startInfo = new ProcessStartInfo
            {
                FileName = "explorer.exe",
                UseShellExecute = true
            };
            if (isFile)
            {
                startInfo.ArgumentList.Add("/select,");
            }
            startInfo.ArgumentList.Add(location);
            Process.Start(startInfo);
        }
        catch (Exception exception)
        {
            MessageBox.Show(this, $"无法打开所在文件夹：{exception.Message}", "打开失败", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private static bool TryResolveResultLocation(OperationItem? item, out string location, out bool isFile)
    {
        location = string.Empty;
        isFile = false;
        if (item is null || string.IsNullOrWhiteSpace(item.Path))
        {
            return false;
        }

        try
        {
            var candidate = Environment.ExpandEnvironmentVariables(item.Path.Trim().Trim('"'));
            if (!Path.IsPathFullyQualified(candidate))
            {
                return false;
            }

            var fullPath = Path.GetFullPath(candidate);
            if (Directory.Exists(fullPath))
            {
                location = fullPath;
                return true;
            }
            if (File.Exists(fullPath))
            {
                location = fullPath;
                isFile = true;
                return true;
            }
        }
        catch (Exception exception) when (exception is ArgumentException or NotSupportedException or PathTooLongException or IOException or UnauthorizedAccessException)
        {
            return false;
        }

        return false;
    }

    private static DependencyObject? GetParentObject(DependencyObject child)
    {
        if (child is ContentElement contentElement)
        {
            var contentParent = ContentOperations.GetParent(contentElement);
            if (contentParent is not null)
            {
                return contentParent;
            }
            if (contentElement is FrameworkContentElement frameworkContentElement)
            {
                return frameworkContentElement.Parent;
            }
        }

        return VisualTreeHelper.GetParent(child);
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
        ApplyButton.IsEnabled = SelectedFeature is { SupportsApply: true } &&
                                !IsBusy &&
                                (SelectedFeature.SelectableResults == false || Results.Any(item => item.CanSelect && item.IsSelected));
    }

    private void OnPropertyChanged([CallerMemberName] string? propertyName = null)
    {
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
    }
}
