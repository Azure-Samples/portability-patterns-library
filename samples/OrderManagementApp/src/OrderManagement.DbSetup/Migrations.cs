using System.Reflection;
using DbUp.Builder;
using Microsoft.Extensions.Logging;

namespace OrderManagement.DbSetup;

/// <summary>
/// Applies a database's migrations: the numbered .sql files under Migrations/&lt;database&gt;, each run
/// once, in name order, in its own transaction, and recorded in the database's journal table, so a
/// later run applies only the files added since. A schema change is a new file; files already
/// applied are never edited.
/// </summary>
public static class Migrations
{
    public static void Apply(UpgradeEngineBuilder target, string folder, ILoggerFactory loggerFactory)
    {
        var prefix = $"{typeof(Migrations).Namespace}.Migrations.{folder}.";
        var result = target
            .WithScriptsEmbeddedInAssembly(Assembly.GetExecutingAssembly(), name => name.StartsWith(prefix, StringComparison.Ordinal))
            .WithTransactionPerScript()
            .LogTo(loggerFactory)
            .Build()
            .PerformUpgrade();

        if (!result.Successful)
        {
            throw new InvalidOperationException(
                $"Migration {result.ErrorScript?.Name ?? "(unknown)"} failed: {result.Error?.Message}", result.Error);
        }
    }
}
