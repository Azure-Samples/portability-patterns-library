using System.Text.Json;
using Dapper;
using OrderManagement.Shared.Models;

namespace OrderManagement.Shared.Persistence;

/// <summary>SQL Server and Azure SQL Database implementation of <see cref="IOrderStore"/>.</summary>
public sealed class SqlOrderStore(SqlConnectionFactory connections) : IOrderStore
{
    // Inserts the order once: a redelivered message finds it there and changes nothing. HOLDLOCK
    // keeps the key range locked from the check to the insert, so two deliveries of the same order at
    // once can't both find it missing.
    private const string RecordSql = """
        MERGE dbo.Orders WITH (HOLDLOCK) AS target
        USING (SELECT @OrderId AS OrderId) AS source
        ON target.OrderId = source.OrderId
        WHEN NOT MATCHED THEN
            INSERT (OrderId, CustomerId, CustomerName, LineCount, Total, Currency, LinesJson,
                    PlacedAt, ArchiveUri, ProcessedAt, Status, StatusReason)
            VALUES (@OrderId, @CustomerId, @CustomerName, @LineCount, @Total, @Currency, @LinesJson,
                    @PlacedAt, @ArchiveUri, @ProcessedAt, @Status, @StatusReason);
        """;

    private const string SelectColumns = """
        OrderId, CustomerName, Total, Currency, LinesJson, PlacedAt, ArchiveUri, ProcessedAt, Status, StatusReason
        """;

    public async Task RecordAsync(
        Order order, string archiveUri, string status, string? statusReason, CancellationToken cancellationToken)
    {
        await using var connection = await connections.OpenAsync(cancellationToken).ConfigureAwait(false);
        await connection.ExecuteAsync(new CommandDefinition(RecordSql, new
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
            ProcessedAt = DateTimeOffset.UtcNow,
            Status = status,
            StatusReason = statusReason
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
        await using var connection = await connections.OpenAsync(cancellationToken).ConfigureAwait(false);
        return await connection.QueryAsync<OrderRow>(
            new CommandDefinition(sql, parameters, cancellationToken: cancellationToken)).ConfigureAwait(false);
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
        ArchiveUri = row.ArchiveUri,
        Status = row.Status,
        StatusReason = row.StatusReason
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
        public string Status { get; init; } = OrderStatus.Processed;
        public string? StatusReason { get; init; }
    }
}
