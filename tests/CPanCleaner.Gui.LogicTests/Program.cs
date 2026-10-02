using System.Reflection;
using CPanCleaner.Gui.Models;
using CPanCleaner.Gui.Services;

var failures = new List<string>();

Run("分析结果保留精确清理目标", () =>
{
    var cleanupTargetIdsProperty = typeof(OperationItem).GetProperty("CleanupTargetIds")
        ?? throw new InvalidOperationException("OperationItem 缺少 CleanupTargetIds。 ");
    var parseResult = typeof(CleanerBackend).GetMethod("ParseResult", BindingFlags.NonPublic | BindingFlags.Static)
        ?? throw new InvalidOperationException("找不到 CleanerBackend.ParseResult。 ");
    const string json = """
        {
          "Version": "test",
          "Action": "AnalyzeStorage",
          "Mode": "ReadOnly",
          "Items": [
            {
              "Id": "ChromeData",
              "Name": "Google Chrome 用户数据",
              "CanSelect": true,
              "CleanupTargetIds": ["ChromeDefaultCache", "ChromeProfile1CodeCache"]
            }
          ]
        }
        """;

    var result = (OperationResult?)parseResult.Invoke(null, new object?[] { json, string.Empty })
        ?? throw new InvalidOperationException("ParseResult 未返回结果。 ");
    Equal(1, result.Items.Count, "应解析一个分析结果");
    True(result.Items[0].CanSelect, "可安全清理的分析结果应可勾选");
    var targetIds = (string[]?)cleanupTargetIdsProperty.GetValue(result.Items[0]) ?? Array.Empty<string>();
    SequenceEqual(new[] { "ChromeDefaultCache", "ChromeProfile1CodeCache" }, targetIds, "精确清理目标应完整保留");
});

Run("只汇总已勾选且允许选择的目标", () =>
{
    var operationSelection = typeof(OperationItem).Assembly.GetType("CPanCleaner.Gui.Models.OperationSelection")
        ?? throw new InvalidOperationException("缺少 OperationSelection。 ");
    var getCleanupTargetIds = operationSelection.GetMethod("GetCleanupTargetIds", BindingFlags.Public | BindingFlags.Static)
        ?? throw new InvalidOperationException("缺少 OperationSelection.GetCleanupTargetIds。 ");
    var cleanupTargetIdsProperty = typeof(OperationItem).GetProperty("CleanupTargetIds")
        ?? throw new InvalidOperationException("OperationItem 缺少 CleanupTargetIds。 ");

    var selected = new OperationItem { Name = "selected", CanSelect = true, IsSelected = true };
    cleanupTargetIdsProperty.SetValue(selected, new[] { "ChromeDefaultCache", "NpmCache" });
    var duplicate = new OperationItem { Name = "duplicate", CanSelect = true, IsSelected = true };
    cleanupTargetIdsProperty.SetValue(duplicate, new[] { "ChromeDefaultCache" });
    var uncheckedItem = new OperationItem { Name = "unchecked", CanSelect = true };
    cleanupTargetIdsProperty.SetValue(uncheckedItem, new[] { "QoderIndex" });
    var blockedSelection = new OperationItem { Name = "not-selectable", CanSelect = false };
    cleanupTargetIdsProperty.SetValue(blockedSelection, new[] { "UnsafeTarget" });
    typeof(OperationItem).GetField("_isSelected", BindingFlags.NonPublic | BindingFlags.Instance)!
        .SetValue(blockedSelection, true);

    var targetIds = (IReadOnlyList<string>?)getCleanupTargetIds.Invoke(
        null,
        new object?[] { new[] { selected, duplicate, uncheckedItem, blockedSelection } })
        ?? throw new InvalidOperationException("GetCleanupTargetIds 未返回结果。 ");
    SequenceEqual(new[] { "ChromeDefaultCache", "NpmCache" }, targetIds, "只能执行用户明确勾选的去重白名单目标");
});

Run("分析页执行切换为精确白名单清理", () =>
{
    var buildArguments = typeof(CleanerBackend).GetMethod("BuildArguments", BindingFlags.NonPublic | BindingFlags.Static)
        ?? throw new InvalidOperationException("找不到 CleanerBackend.BuildArguments。 ");
    True(
        buildArguments.GetParameters().Any(parameter => parameter.Name == "selectedCleanupTargetIds"),
        "BuildArguments 应接收 selectedCleanupTargetIds");

    var feature = new CleanerFeature
    {
        Id = "storage-analysis",
        Action = "AnalyzeStorage",
        OperationKind = "Cleaner",
        AnalysisScope = "All"
    };
    var arguments = (IReadOnlyList<string>?)buildArguments.Invoke(
        null,
        new object?[]
        {
            feature,
            true,
            1,
            "CPanCleaner.ps1",
            "result.json",
            null,
            15,
            null,
            Array.Empty<string>(),
            new[] { "ChromeDefaultCache", "NpmCache" }
        }) ?? throw new InvalidOperationException("BuildArguments 未返回参数。 ");

    Equal("Clean", ValueAfter(arguments, "-Action"), "执行分析页选择项时后端动作应为 Clean");
    Equal("Id:ChromeDefaultCache,Id:NpmCache", ValueAfter(arguments, "-Include"), "应使用显式 Id 选择器传递精确白名单目标，避免与类别同名时扩大范围");
    True(arguments.Contains("-Apply"), "真实执行必须显式传递 -Apply");
    False(arguments.Contains("-AnalysisScope"), "清理调用不应继续作为只读分析运行");
});

Run("分析页预览仍保持只读", () =>
{
    var buildArguments = typeof(CleanerBackend).GetMethod("BuildArguments", BindingFlags.NonPublic | BindingFlags.Static)
        ?? throw new InvalidOperationException("找不到 CleanerBackend.BuildArguments。 ");
    var feature = new CleanerFeature
    {
        Id = "storage-analysis",
        Action = "AnalyzeStorage",
        OperationKind = "Cleaner",
        AnalysisScope = "All"
    };
    var arguments = (IReadOnlyList<string>?)buildArguments.Invoke(
        null,
        new object?[]
        {
            feature,
            false,
            1,
            "CPanCleaner.ps1",
            "result.json",
            null,
            15,
            null,
            Array.Empty<string>(),
            Array.Empty<string>()
        }) ?? throw new InvalidOperationException("BuildArguments 未返回参数。 ");

    Equal("AnalyzeStorage", ValueAfter(arguments, "-Action"), "预览动作必须仍是 AnalyzeStorage");
    Equal("All", ValueAfter(arguments, "-AnalysisScope"), "预览必须保留分析范围");
    False(arguments.Contains("-Apply"), "只读预览不能传递 -Apply");
});

if (failures.Count > 0)
{
    Console.Error.WriteLine($"GUI logic tests failed: {failures.Count}");
    foreach (var failure in failures)
    {
        Console.Error.WriteLine("- " + failure);
    }
    return 1;
}

Console.WriteLine("All CPanCleaner GUI logic tests passed.");
return 0;

void Run(string name, Action test)
{
    try
    {
        test();
        Console.WriteLine("PASS " + name);
    }
    catch (Exception exception)
    {
        failures.Add($"{name}: {exception.GetBaseException().Message}");
    }
}

static string ValueAfter(IReadOnlyList<string> arguments, string name)
{
    var index = arguments.IndexOf(name);
    if (index < 0 || index + 1 >= arguments.Count)
    {
        throw new InvalidOperationException($"参数中缺少 {name}。 ");
    }
    return arguments[index + 1];
}

static void True(bool condition, string message)
{
    if (!condition)
    {
        throw new InvalidOperationException(message);
    }
}

static void False(bool condition, string message) => True(!condition, message);

static void Equal<T>(T expected, T actual, string message)
{
    if (!EqualityComparer<T>.Default.Equals(expected, actual))
    {
        throw new InvalidOperationException($"{message}；期望={expected}，实际={actual}");
    }
}

static void SequenceEqual(IEnumerable<string> expected, IEnumerable<string> actual, string message)
{
    var expectedArray = expected.ToArray();
    var actualArray = actual.ToArray();
    if (!expectedArray.SequenceEqual(actualArray, StringComparer.Ordinal))
    {
        throw new InvalidOperationException($"{message}；期望={string.Join(',', expectedArray)}，实际={string.Join(',', actualArray)}");
    }
}

static class ListExtensions
{
    public static int IndexOf<T>(this IReadOnlyList<T> source, T value)
    {
        for (var index = 0; index < source.Count; index++)
        {
            if (EqualityComparer<T>.Default.Equals(source[index], value))
            {
                return index;
            }
        }
        return -1;
    }
}
