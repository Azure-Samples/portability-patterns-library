using OrderManagement.DbSetup;

namespace OrderManagement.Tests;

/// <summary>The migration scripts the database setup job carries, and the order DbUp applies them in.</summary>
public sealed class MigrationsTests
{
    [Theory]
    [InlineData("SqlServer", new[] { "0001_orders.sql" })]
    [InlineData("Postgres", new[] { "0001_inventory.sql", "0002_products.sql" })]
    public void Carries_each_database_s_scripts_numbered_in_order(string folder, string[] expected)
    {
        var prefix = $"{typeof(Migrations).Namespace}.Migrations.{folder}.";
        var scripts = typeof(Migrations).Assembly.GetManifestResourceNames()
            .Where(name => name.StartsWith(prefix, StringComparison.Ordinal))
            .Select(name => name[prefix.Length..])
            .Order(StringComparer.Ordinal)
            .ToArray();

        Assert.Equal(expected, scripts);
    }
}
