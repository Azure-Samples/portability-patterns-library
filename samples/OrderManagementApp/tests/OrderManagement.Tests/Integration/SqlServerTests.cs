using Microsoft.Data.SqlClient;
using OrderManagement.Shared.Models;
using OrderManagement.Shared.Persistence;

namespace OrderManagement.Tests.Integration;

/// <summary>
/// The orders database against a real SQL Server, set up by the database setup job: running the
/// job again changes nothing, the processor records an order once however often it is delivered, and
/// each service's login has only the rights its statements need.
/// </summary>
[Collection(SqlServerCollection.Name)]
public sealed class SqlServerTests(SqlServerFixture database)
{
    [SkippableFact]
    public async Task Setup_changes_nothing_when_run_again()
    {
        SkipWithoutContainers();
        var before = await SnapshotAsync();

        await database.RunSetupAsync();

        Assert.Equal(before, await SnapshotAsync());
        Assert.Contains("0001_orders.sql", before);
    }

    [SkippableFact]
    public async Task Records_an_order_once_however_often_it_is_delivered()
    {
        SkipWithoutContainers();
        var processor = new SqlOrderStore(database.ConnectAs("processor"));
        var order = NewOrder();

        // Deliveries at once, then a late redelivery.
        await Task.WhenAll(Enumerable.Range(0, 8).Select(_ =>
            processor.RecordAsync(order, "archive/1.json", OrderStatus.Processed, null, CancellationToken.None)));
        await processor.RecordAsync(order, "archive/2.json", OrderStatus.Rejected, OrderStatus.OutOfStockReason, CancellationToken.None);

        var stored = await new SqlOrderStore(database.ConnectAs("api")).GetForCustomerAsync(order.OrderId, order.CustomerId, CancellationToken.None);
        Assert.NotNull(stored);
        Assert.Equal(OrderStatus.Processed, stored.Status);
        Assert.Equal("archive/1.json", stored.ArchiveUri);
        Assert.Equal(1, await database.QueryAsAdminAsync<int>($"SELECT COUNT(*) FROM omsdb.dbo.Orders WHERE OrderId = '{order.OrderId}'"));
    }

    [SkippableFact]
    public async Task Shows_customers_only_their_own_orders()
    {
        SkipWithoutContainers();
        var processor = new SqlOrderStore(database.ConnectAs("processor"));
        var api = new SqlOrderStore(database.ConnectAs("api"));
        var mine = NewOrder();
        await processor.RecordAsync(mine, "archive/mine.json", OrderStatus.Processed, null, CancellationToken.None);

        Assert.Contains(await api.ListForCustomerAsync(mine.CustomerId, 50, CancellationToken.None), order => order.OrderId == mine.OrderId);
        Assert.Null(await api.GetForCustomerAsync(mine.OrderId, "someone-else", CancellationToken.None));
    }

    [SkippableTheory]
    [InlineData("api", "INSERT INTO dbo.Orders (OrderId, CustomerId, CustomerName, LineCount, Total, Currency, LinesJson, PlacedAt, ArchiveUri, ProcessedAt) VALUES (NEWID(), 'c', 'n', 1, 1, 'USD', '[]', SYSDATETIMEOFFSET(), 'a', SYSDATETIMEOFFSET())")]
    [InlineData("api", "DELETE FROM dbo.Orders")]
    [InlineData("processor", "UPDATE dbo.Orders SET Status = N'Rejected'")]
    [InlineData("processor", "DELETE FROM dbo.Orders")]
    [InlineData("processor", "CREATE TABLE dbo.Extra (Id INT)")]
    public async Task Refuses_what_a_service_does_not_do(string login, string statement)
    {
        SkipWithoutContainers();
        await using var connection = await database.ConnectAs(login).OpenAsync(CancellationToken.None);
        await using var command = new SqlCommand(statement, connection);

        var denied = await Assert.ThrowsAsync<SqlException>(() => command.ExecuteNonQueryAsync());
        // 229: permission denied on the object; 262: permission denied in the database.
        Assert.Contains(denied.Number, new[] { 229, 262 });
    }

    private void SkipWithoutContainers() => Skip.If(database.Unavailable is not null, database.Unavailable);

    private static Order NewOrder() => new()
    {
        OrderId = Guid.NewGuid(),
        CustomerId = $"customer-{Guid.NewGuid():N}",
        CustomerName = "Test Customer",
        PlacedAt = DateTimeOffset.UtcNow,
        Lines = [new OrderLine { Sku = "GEN-500", ProductName = "Generator", Quantity = 1, UnitPrice = 10m }]
    };

    // The migrations journal and the services' permissions.
    private Task<string> SnapshotAsync() => database.QueryAsAdminAsync<string>(
        """
        SELECT STRING_AGG(line, CHAR(10)) WITHIN GROUP (ORDER BY line) FROM (
            SELECT 'migration ' + ScriptName COLLATE Latin1_General_BIN2 AS line FROM omsdb.dbo.SchemaVersions
            UNION ALL
            SELECT ('grant ' + pr.name + ' ' + pe.permission_name + ' ' + OBJECT_NAME(pe.major_id, DB_ID('omsdb'))) COLLATE Latin1_General_BIN2
            FROM omsdb.sys.database_permissions AS pe
            JOIN omsdb.sys.database_principals AS pr ON pe.grantee_principal_id = pr.principal_id
            WHERE pr.name IN (N'api', N'processor') AND pe.class = 1
        ) AS state;
        """);
}
