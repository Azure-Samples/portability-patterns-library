using OrderManagement.Shared.Models;

namespace OrderManagement.Inventory.Data;

/// <summary>Reads the product catalog with its current stock.</summary>
public interface IProductRepository
{
    Task<IReadOnlyList<Product>> ListAsync(CancellationToken cancellationToken);
}
