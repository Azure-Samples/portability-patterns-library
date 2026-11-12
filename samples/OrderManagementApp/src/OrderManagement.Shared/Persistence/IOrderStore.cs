using OrderManagement.Shared.Models;

namespace OrderManagement.Shared.Persistence;

/// <summary>
/// Records completed orders and reads them back for their customer. Rows only: the table is
/// created and migrated by dbsetup, never by the services.
/// </summary>
public interface IOrderStore
{
    /// <param name="status"><see cref="OrderStatus.Processed"/> or <see cref="OrderStatus.Rejected"/>.</param>
    /// <param name="statusReason">Why an order was rejected, for example <see cref="OrderStatus.OutOfStockReason"/>.</param>
    Task RecordAsync(Order order, string archiveUri, string status, string? statusReason, CancellationToken cancellationToken);

    Task<IReadOnlyList<StoredOrder>> ListForCustomerAsync(string customerId, int top, CancellationToken cancellationToken);

    Task<StoredOrder?> GetForCustomerAsync(Guid orderId, string customerId, CancellationToken cancellationToken);
}