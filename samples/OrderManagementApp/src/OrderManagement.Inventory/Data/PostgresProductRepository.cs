using Npgsql;
using OrderManagement.Shared.Models;

namespace OrderManagement.Inventory.Data;

/// <summary>PostgreSQL implementation of <see cref="IProductRepository"/>.</summary>
public sealed class PostgresProductRepository(NpgsqlDataSource dataSource) : IProductRepository
{
    internal const string ProductColumns = "sku, name, unit_price, currency, available, reorder_level";

    public async Task<IReadOnlyList<Product>> ListAsync(CancellationToken cancellationToken)
    {
        await using var command = dataSource.CreateCommand(
            $"SELECT {ProductColumns} FROM inventory.products ORDER BY sku");
        await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);

        var products = new List<Product>();
        while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
        {
            products.Add(ReadProduct(reader));
        }

        return products;
    }

    internal static Product ReadProduct(NpgsqlDataReader reader) => new()
    {
        Sku = reader.GetString(0),
        Name = reader.GetString(1),
        UnitPrice = reader.GetDecimal(2),
        Currency = reader.GetString(3).Trim(),
        Available = reader.GetInt32(4),
        ReorderLevel = reader.GetInt32(5)
    };
}
