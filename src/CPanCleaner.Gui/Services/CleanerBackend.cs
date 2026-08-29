using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using CPanCleaner.Gui.Models;

namespace CPanCleaner.Gui.Services;

public sealed class CleanerBackend
{
    private readonly string _cleanerScript;
    private readonly string _widgetsScript;

    public CleanerBackend()
    {
        _cleanerScript = FindBackendFile("CPanCleaner.ps1");
        _widgetsScript = FindBackendFile(Path.Combine("scripts", "Close-WindowsWidgets.ps1"));
    }

    public string LogsDirectory => Path.Combine(Path.GetDirectoryName(_cleanerScript)!, "logs");

    public static bool IsAdministrator()
    {
        using var identity = WindowsIdentity.GetCurrent();
        var principal = new WindowsPrincipal(identity);
        return principal.IsInRole(WindowsBuiltInRole.Administrator);
    }

    public async Task<OperationResult> RunAsync(
        CleanerFeature feature,
        bool apply,
        int minimumAgeDays,
        CancellationToken cancellationToken,
        string? guardOperation = null,
        int guardIntervalMinutes = 15)
    {
        var script = feature.OperationKind.Equals("Widgets", StringComparison.OrdinalIgnoreCase)
            ? _widgetsScript
            : _cleanerScript;
        var requiresElevation = apply && feature.RequiresAdministrator && !IsAdministrator();
        var resultDirectory = Path.Combine(Path.GetTempPath(), "CPanCleaner", "operation-results");
        Directory.CreateDirectory(resultDirectory);
        var resultPath = Path.Combine(resultDirectory, $"result-{Guid.NewGuid():N}.json");
        var arguments = BuildArguments(feature, apply, minimumAgeDays, script, resultPath, guardOperation, guardIntervalMinutes);

        if (requiresElevation)
        {
            return await RunElevatedAsync(feature, arguments, resultPath, cancellationToken);
        }

        var startInfo = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            WorkingDirectory = Path.GetDirectoryName(script)!,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8
        };

        foreach (var argument in arguments)
        {
            startInfo.ArgumentList.Add(argument);
        }

        try
        {
            using var process = new Process { StartInfo = startInfo };
            process.Start();
            var outputTask = process.StandardOutput.ReadToEndAsync();
            var errorTask = process.StandardError.ReadToEndAsync();

            try
            {
                await process.WaitForExitAsync(cancellationToken);
            }
            catch (OperationCanceledException)
            {
                TryKill(process);
                throw;
            }

            var output = await outputTask;
            var error = await errorTask;
            if (process.ExitCode != 0)
            {
                throw new InvalidOperationException(string.IsNullOrWhiteSpace(error) ? output : error);
            }
            if (!File.Exists(resultPath))
            {
                throw new InvalidDataException("后端没有写回 UTF-8 结构化结果，请查看 backend\\logs。");
            }

            return ParseResult(await File.ReadAllTextAsync(resultPath, cancellationToken), error);
        }
        finally
        {
            TryDeleteResultFile(resultPath);
        }
    }

    private async Task<OperationResult> RunElevatedAsync(
        CleanerFeature feature,
        IReadOnlyList<string> arguments,
        string resultPath,
        CancellationToken cancellationToken)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            UseShellExecute = true,
            Verb = "runas",
            WindowStyle = ProcessWindowStyle.Hidden,
            WorkingDirectory = Path.GetDirectoryName(
                feature.OperationKind.Equals("Widgets", StringComparison.OrdinalIgnoreCase)
                    ? _widgetsScript
                    : _cleanerScript)!
        };
        foreach (var argument in arguments)
        {
            startInfo.ArgumentList.Add(argument);
        }

        try
        {
            using var process = Process.Start(startInfo)
                ?? throw new InvalidOperationException("无法启动管理员 PowerShell 进程。");

            try
            {
                await process.WaitForExitAsync(cancellationToken);
            }
            catch (OperationCanceledException)
            {
                TryKill(process);
                throw;
            }

            if (process.ExitCode != 0)
            {
                throw new InvalidOperationException($"管理员进程退出，代码：{process.ExitCode}。如果取消了 UAC，请重新预览后再执行。");
            }
            if (!File.Exists(resultPath))
            {
                throw new InvalidDataException("管理员后端没有写回结构化结果，请查看 backend\\logs。 ");
            }

            var result = ParseResult(await File.ReadAllTextAsync(resultPath, cancellationToken), string.Empty);
            result.WasElevated = true;
            return result;
        }
        finally
        {
            TryDeleteResultFile(resultPath);
        }
    }

    private static void TryDeleteResultFile(string resultPath)
    {
        try
        {
            if (File.Exists(resultPath))
            {
                File.Delete(resultPath);
            }
        }
        catch
        {
            // A stale result file contains only this operation's JSON and can be cleaned later.
        }
    }

    private static IReadOnlyList<string> BuildArguments(
        CleanerFeature feature,
        bool apply,
        int minimumAgeDays,
        string script,
        string? jsonOutputPath,
        string? guardOperation,
        int guardIntervalMinutes)
    {
        var arguments = new List<string>
        {
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", script,
            "-Action", feature.Action
        };

        if (feature.OperationKind.Equals("Cleaner", StringComparison.OrdinalIgnoreCase))
        {
            if (feature.Includes.Length > 0)
            {
                arguments.Add("-Include");
                arguments.Add(string.Join(",", feature.Includes));
            }
            arguments.Add("-MinimumAgeDays");
            arguments.Add(minimumAgeDays.ToString(CultureInfo.InvariantCulture));
            arguments.Add("-MaxScanItems");
            arguments.Add("100000");
            arguments.Add("-RepositoryPath");
            arguments.Add(Environment.CurrentDirectory);
        }

        if (feature.SupportsSchedule)
        {
            arguments.Add("-GuardName");
            arguments.Add(feature.GuardName);
            arguments.Add("-GuardOperation");
            arguments.Add(guardOperation ?? "Status");
            arguments.Add("-GuardIntervalMinutes");
            arguments.Add(guardIntervalMinutes.ToString(CultureInfo.InvariantCulture));
        }

        if (feature.RestartExplorer)
        {
            arguments.Add("-RestartExplorer");
        }

        if (apply)
        {
            arguments.Add("-Apply");
        }
        else if (!feature.Action.Equals("Diagnose", StringComparison.OrdinalIgnoreCase) &&
                 !(feature.SupportsSchedule && string.Equals(guardOperation, "Status", StringComparison.OrdinalIgnoreCase)))
        {
            arguments.Add("-DryRun");
        }

        if (!string.IsNullOrWhiteSpace(jsonOutputPath))
        {
            arguments.Add("-JsonOutputPath");
            arguments.Add(jsonOutputPath);
        }

        arguments.Add("-Json");
        return arguments;
    }

    private static OperationResult ParseResult(string output, string error)
    {
        var json = ExtractJson(output);
        using var document = JsonDocument.Parse(json);
        var root = document.RootElement;
        var result = new OperationResult
        {
            Version = GetString(root, "Version"),
            Action = GetString(root, "Action"),
            Mode = GetString(root, "Mode"),
            IsAdministrator = GetBoolean(root, "IsAdministrator"),
            LogPath = GetString(root, "LogPath"),
            RawOutput = string.IsNullOrWhiteSpace(error) ? output.Trim() : $"{output.Trim()}\n{error.Trim()}"
        };

        if (TryGetProperty(root, "Items", out var items) && items.ValueKind == JsonValueKind.Array)
        {
            foreach (var item in items.EnumerateArray())
            {
                result.Items.Add(new OperationItem
                {
                    Type = "Target",
                    Name = Coalesce(GetString(item, "Name"), GetString(item, "Id")),
                    Status = Coalesce(GetString(item, "Status"), GetString(item, "Mode")),
                    Risk = GetString(item, "Risk"),
                    EstimatedMB = GetNullableDouble(item, "EstimatedMB"),
                    Path = GetString(item, "Path"),
                    Message = Coalesce(GetString(item, "Message"), GetString(item, "Notes"))
                });
            }
        }

        if (TryGetProperty(root, "Diagnostics", out var diagnostics) && diagnostics.ValueKind == JsonValueKind.Array)
        {
            foreach (var item in diagnostics.EnumerateArray())
            {
                result.Items.Add(new OperationItem
                {
                    Type = Coalesce(GetString(item, "Type"), "Diagnostic"),
                    Name = Coalesce(GetString(item, "Name"), GetString(item, "Action")),
                    Status = Coalesce(GetString(item, "Status"), GetString(item, "Severity")),
                    Risk = GetString(item, "Severity"),
                    Path = GetString(item, "Detail"),
                    Message = GetString(item, "Message")
                });
            }
        }

        return result;
    }

    private static string ExtractJson(string output)
    {
        var start = output.IndexOf('{');
        var end = output.LastIndexOf('}');
        if (start < 0 || end <= start)
        {
            throw new InvalidDataException($"后端没有返回有效 JSON。输出：{output}");
        }
        return output[start..(end + 1)];
    }

    private static string FindBackendFile(string relativePath)
    {
        var packaged = Path.Combine(AppContext.BaseDirectory, "backend", relativePath);
        if (File.Exists(packaged))
        {
            return packaged;
        }

        var cursor = new DirectoryInfo(AppContext.BaseDirectory);
        for (var i = 0; i < 8 && cursor is not null; i++, cursor = cursor.Parent)
        {
            var candidate = Path.Combine(cursor.FullName, relativePath);
            if (File.Exists(candidate))
            {
                return candidate;
            }
        }

        throw new FileNotFoundException($"找不到 PowerShell 后端：{relativePath}");
    }

    private static void TryKill(Process process)
    {
        try
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
            }
        }
        catch
        {
            // Best-effort cancellation; elevated processes may already have exited.
        }
    }

    private static bool TryGetProperty(JsonElement element, string name, out JsonElement value)
    {
        foreach (var property in element.EnumerateObject())
        {
            if (property.Name.Equals(name, StringComparison.OrdinalIgnoreCase))
            {
                value = property.Value;
                return true;
            }
        }
        value = default;
        return false;
    }

    private static string GetString(JsonElement element, string name)
    {
        if (!TryGetProperty(element, name, out var value) || value.ValueKind is JsonValueKind.Null or JsonValueKind.Undefined)
        {
            return string.Empty;
        }
        return value.ValueKind == JsonValueKind.String ? value.GetString() ?? string.Empty : value.ToString();
    }

    private static bool GetBoolean(JsonElement element, string name)
    {
        return TryGetProperty(element, name, out var value) &&
               (value.ValueKind == JsonValueKind.True ||
                value.ValueKind == JsonValueKind.String && bool.TryParse(value.GetString(), out var parsed) && parsed);
    }

    private static double? GetNullableDouble(JsonElement element, string name)
    {
        if (!TryGetProperty(element, name, out var value))
        {
            return null;
        }
        if (value.ValueKind == JsonValueKind.Number && value.TryGetDouble(out var number))
        {
            return number;
        }
        return double.TryParse(value.ToString(), NumberStyles.Any, CultureInfo.InvariantCulture, out number) ? number : null;
    }

    private static string Coalesce(string first, string second) => string.IsNullOrWhiteSpace(first) ? second : first;
}
