using OrderManagement.Shared.Models;

namespace OrderManagement.Shared.Persistence;

/// <summary>Records processed orders and reads them back for their customer.</summary>
public interface IOrderStore
{
    Task InitializeAsync(CancellationToken cancellationToken);

    Task RecordAsync(Order order, string archiveUri, CancellationToken cancellationToken);

    Task<IReadOnlyList<StoredOrder>> ListForCustomerAsync(string customerId, int top, CancellationToken cancellationToken);

    Task<StoredOrder?> GetForCustomerAsync(Guid orderId, string customerId, CancellationToken cancellationToken);
}
