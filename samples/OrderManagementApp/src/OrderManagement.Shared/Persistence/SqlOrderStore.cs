using System.Text.Json;
using OrderManagement.Shared.Models;
using Dapper;
using Microsoft.Data.SqlClient;

namespace OrderManagement.Shared.Persistence;

/// <summary>SQL Server and Azure SQL Database implementation of <see cref="IOrderStore"/>.</summary>
public sealed class SqlOrderStore(SqlConnectionFactory connections) : IOrderStore
{
    // SQL Server error 208: invalid object name. The processor creates the table on start-up, so a
    // reader that gets here first has simply nothing to show yet.
    private const int InvalidObjectName = 208;

    private const string CreateTableSql = """
        IF OBJECT_ID(N'dbo.Orders', N'U') IS NULL
        BEGIN
            CREATE TABLE dbo.Orders
            (
                OrderId         UNIQUEIDENTIFIER NOT NULL PRIMARY KEY,
                CustomerId      NVARCHAR(128)    NOT NULL,
                CustomerName    NVARCHAR(256)    NOT NULL,
                LineCount       INT              NOT NULL,
                Total           DECIMAL(18, 2)   NOT NULL,
                Currency        NCHAR(3)         NOT NULL,
                LinesJson       NVARCHAR(MAX)    NOT NULL,
                PlacedAt        DATETIMEOFFSET   NOT NULL,
                ArchiveUri      NVARCHAR(1000)   NOT NULL,
                ProcessedAt     DATETIMEOFFSET   NOT NULL
            );

            CREATE INDEX IX_Orders_Customer_PlacedAt ON dbo.Orders (CustomerId, PlacedAt DESC);
        END
        """;

    private const string UpsertSql = """
        MERGE dbo.Orders AS target
        USING (SELECT @OrderId AS OrderId) AS source
        ON target.OrderId = source.OrderId
        WHEN NOT MATCHED THEN
            INSERT (OrderId, CustomerId, CustomerName, LineCount, Total, Currency, LinesJson,
                    PlacedAt, ArchiveUri, ProcessedAt)
            VALUES (@OrderId, @CustomerId, @CustomerName, @LineCount, @Total, @Currency, @LinesJson,
                    @PlacedAt, @ArchiveUri, @ProcessedAt);
        """;

    private const string SelectColumns = """
        OrderId, CustomerName, Total, Currency, LinesJson, PlacedAt, ArchiveUri, ProcessedAt
        """;

    public Task InitializeAsync(CancellationToken cancellationToken) =>
        connections.EnsureSchemaAsync(CreateTableSql, "orders", cancellationToken);

    public async Task RecordAsync(Order order, string archiveUri, CancellationToken cancellationToken)
    {
        await using var connection = await connections.OpenAsync(cancellationToken).ConfigureAwait(false);

        // MERGE keeps the processor idempotent: queue redelivery must not create duplicate rows.
        await connection.ExecuteAsync(new CommandDefinition(UpsertSql, new
        {
            order.OrderId,
            order.CustomerId,
            order.CustomerName,
            LineCount = order.Lines.Count,
            order.Total,
            order.Currency,
            LinesJson = JsonSerializer.Serialize(order.Lines, Order.SerializerOptions),
            order.PlacedAt,
            ArchiveUri = archiveUri,
            ProcessedAt = DateTimeOffset.UtcNow
        }, cancellationToken: cancellationToken)).ConfigureAwait(false);
    }

    public async Task<IReadOnlyList<StoredOrder>> ListForCustomerAsync(
        string customerId, int top, CancellationToken cancellationToken)
    {
        var sql = $"SELECT TOP (@top) {SelectColumns} FROM dbo.Orders WHERE CustomerId = @customerId ORDER BY PlacedAt DESC;";
        var rows = await QueryAsync(sql, new { top, customerId }, cancellationToken).ConfigureAwait(false);
        return rows.Select(ToStoredOrder).ToList();
    }

    public async Task<StoredOrder?> GetForCustomerAsync(Guid orderId, string customerId, CancellationToken cancellationToken)
    {
        var sql = $"SELECT {SelectColumns} FROM dbo.Orders WHERE OrderId = @orderId AND CustomerId = @customerId;";
        var rows = await QueryAsync(sql, new { orderId, customerId }, cancellationToken).ConfigureAwait(false);
        return rows.Select(ToStoredOrder).FirstOrDefault();
    }

    private async Task<IEnumerable<OrderRow>> QueryAsync(string sql, object parameters, CancellationToken cancellationToken)
    {
        try
        {
            await using var connection = await connections.OpenAsync(cancellationToken).ConfigureAwait(false);
            return await connection.QueryAsync<OrderRow>(
                new CommandDefinition(sql, parameters, cancellationToken: cancellationToken)).ConfigureAwait(false);
        }
        catch (SqlException ex) when (ex.Number == InvalidObjectName)
        {
            return [];
        }
    }

    private static StoredOrder ToStoredOrder(OrderRow row) => new()
    {
        OrderId = row.OrderId,
        CustomerName = row.CustomerName,
        Lines = JsonSerializer.Deserialize<List<OrderLine>>(row.LinesJson, Order.SerializerOptions) ?? [],
        Total = row.Total,
        Currency = row.Currency.Trim(),
        PlacedAt = row.PlacedAt,
        ProcessedAt = row.ProcessedAt,
        ArchiveUri = row.ArchiveUri
    };

    private sealed class OrderRow
    {
        public Guid OrderId { get; init; }
        public string CustomerName { get; init; } = string.Empty;
        public decimal Total { get; init; }
        public string Currency { get; init; } = string.Empty;
        public string LinesJson { get; init; } = "[]";
        public DateTimeOffset PlacedAt { get; init; }
        public string ArchiveUri { get; init; } = string.Empty;
        public DateTimeOffset ProcessedAt { get; init; }
    }
}
