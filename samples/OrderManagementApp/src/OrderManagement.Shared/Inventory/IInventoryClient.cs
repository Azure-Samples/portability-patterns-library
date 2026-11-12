using OrderManagement.Shared.Models;

namespace OrderManagement.Shared.Inventory;

/// <summary>
/// The inventory service as the api and the processor see it. Calls carry the caller's own
/// workload identity, never a user's token.
/// </summary>
/// <remarks>
/// Throws <see cref="InventoryUnavailableException"/> when the service cannot be reached or fails
/// (worth retrying), and <see cref="InventoryRequestException"/> when it refuses the request.
/// </remarks>
public interface IInventoryClient
{
    Task<IReadOnlyList<Product>> GetProductsAsync(CancellationToken cancellationToken);

    /// <summary>Reserves stock for every line or none. Repeating it for the same order returns the first outcome.</summary>
    Task<ReservationResult> ReserveAsync(ReservationRequest request, CancellationToken cancellationToken);

    /// <summary>Gives an order's reserved stock back. Safe to repeat, and a no-op when nothing is reserved.</summary>
    Task ReleaseAsync(Guid orderId, CancellationToken cancellationToken);

    /// <returns>The product with its new stock, or null when the SKU is unknown.</returns>
    Task<Product?> RestockAsync(string sku, int quantity, CancellationToken cancellationToken);
}
