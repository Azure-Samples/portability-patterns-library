using OrderManagement.Shared.Models;

namespace OrderManagement.Inventory.Data;

/// <summary>Changes stock: reservations for orders and restocking.</summary>
public interface IStockRepository
{
    /// <summary>
    /// Reserves every line or none, in one transaction. A repeated call for the same order changes
    /// nothing and returns the outcome recorded the first time.
    /// </summary>
    Task<ReservationOutcome> ReserveAsync(Guid orderId, IReadOnlyList<ReservationLine> lines, CancellationToken cancellationToken);

    /// <summary>
    /// Gives an order's reserved stock back, in one transaction. Repeating it, or calling it for an
    /// order with nothing reserved, changes nothing.
    /// </summary>
    /// <returns>True when stock was given back.</returns>
    Task<bool> ReleaseAsync(Guid orderId, CancellationToken cancellationToken);

    /// <returns>The product with its new stock, or null when the SKU is unknown.</returns>
    Task<Product?> RestockAsync(string sku, int quantity, CancellationToken cancellationToken);
}
