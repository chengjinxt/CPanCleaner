using System.Text.Json;
using System.IO;
using CPanCleaner.Gui.Models;

namespace CPanCleaner.Gui.Services;

public static class FeatureCatalog
{
    public static IReadOnlyList<CleanerFeature> Load()
    {
        var path = FindFile(Path.Combine("Resources", "features.json"));
        var json = File.ReadAllText(path);
        var features = JsonSerializer.Deserialize<List<CleanerFeature>>(json, new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true,
            AllowTrailingCommas = true,
            ReadCommentHandling = JsonCommentHandling.Skip
        });

        if (features is null || features.Count == 0)
        {
            throw new InvalidDataException("功能目录 Resources/features.json 为空。");
        }

        return features;
    }

    private static string FindFile(string relativePath)
    {
        var outputPath = Path.Combine(AppContext.BaseDirectory, relativePath);
        if (File.Exists(outputPath))
        {
            return outputPath;
        }

        var cursor = new DirectoryInfo(AppContext.BaseDirectory);
        for (var i = 0; i < 8 && cursor is not null; i++, cursor = cursor.Parent)
        {
            var candidate = Path.Combine(cursor.FullName, "src", "CPanCleaner.Gui", relativePath);
            if (File.Exists(candidate))
            {
                return candidate;
            }
        }

        throw new FileNotFoundException($"找不到功能目录：{relativePath}");
    }
}
