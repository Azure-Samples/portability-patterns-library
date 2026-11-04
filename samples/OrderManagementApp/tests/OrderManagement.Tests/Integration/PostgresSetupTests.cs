using Npgsql;
using OrderManagement.DbSetup;

namespace OrderManagement.Tests.Integration;

/// <summary>
/// The database setup job against a real PostgreSQL: it can run again at any time without changing
/// anything, and the inventory role signs in with its password (sent as a SCRAM verifier) and gets
/// only the rights the service uses.
/// </summary>
[Collection(PostgresCollection.Name)]
public sealed class PostgresSetupTests(PostgresFixture database)
{
    [SkippableFact]
    public async Task Changes_nothing_when_run_again()
    {
        Skip.If(database.Unavailable is not null, database.Unavailable);
        var before = await SnapshotAsync();

        await database.RunSetupAsync();

        Assert.Equal(before, await SnapshotAsync());
        Assert.Contains("0001_inventory.sql", before);
        Assert.Contains("GEN-500", before);
    }

    [SkippableFact]
    public async Task Gives_the_inventory_role_only_the_rights_the_service_uses()
    {
        Skip.If(database.Unavailable is not null, database.Unavailable);

        // Signing in at all proves the SCRAM verifier matches the password.
        await using var connection = await database.Inventory.OpenConnectionAsync();
        await using var products = new NpgsqlCommand("SELECT count(*) FROM inventory.products", connection);
        Assert.True((long)(await products.ExecuteScalarAsync())! >= 5);

        foreach (var statement in new[]
        {
            "DELETE FROM inventory.products",
            "INSERT INTO inventory.products (sku, name, unit_price, currency, available) VALUES ('X', 'X', 1, 'USD', 1)",
            "DELETE FROM inventory.reservations",
            "CREATE TABLE inventory.extra (id int)"
        })
        {
            await using var command = new NpgsqlCommand(statement, connection);
            var denied = await Assert.ThrowsAsync<PostgresException>(() => command.ExecuteNonQueryAsync());
            Assert.Equal(PostgresErrorCodes.InsufficientPrivilege, denied.SqlState);
        }
    }

    // The migrations journal, the seeded products, and the role's grants.
    private async Task<string> SnapshotAsync()
    {
        await using var command = database.Admin.CreateCommand(
            $"""
            SELECT string_agg(line, E'\n' ORDER BY line) FROM (
                SELECT 'migration ' || scriptname AS line FROM public.schemaversions
                UNION ALL SELECT 'product ' || sku || ' ' || available FROM inventory.products WHERE sku NOT LIKE 'T-%'
                UNION ALL SELECT 'grant ' || table_name || ' ' || privilege_type FROM information_schema.role_table_grants
                    WHERE grantee = '{PostgresSetup.Role}'
            ) AS state
            """);
        return (string)(await command.ExecuteScalarAsync())!;
    }
}
