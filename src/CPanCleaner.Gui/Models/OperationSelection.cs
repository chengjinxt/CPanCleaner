namespace CPanCleaner.Gui.Models;

public static class OperationSelection
{
    public static IReadOnlyList<string> GetCleanupTargetIds(IEnumerable<OperationItem> items)
    {
        return items
            .Where(item => item.CanSelect && item.IsSelected)
            .SelectMany(item => item.CleanupTargetIds)
            .Where(targetId => !string.IsNullOrWhiteSpace(targetId))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();
    }
}
