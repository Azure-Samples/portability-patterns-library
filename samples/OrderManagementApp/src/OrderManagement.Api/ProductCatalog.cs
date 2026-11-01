using OrderManagement.Shared.Inventory;
using OrderManagement.Shared.Models;

namespace OrderManagement.Api;

/// <summary>
/// The inventory service's products, as the API shows them and prices orders from them. Keeps the
/// last list it fetched: while the inventory service is down, the product list still shows and
/// orders are still priced and queued, and the processor reserves their stock once the service is
/// back. A list older than <c>Inventory__PriceCacheMaxAge</c> (one hour by default) is not used.
/// After a failed call, the next calls within <see cref="RetryAfter"/> use the last list straight
/// away, so users don't each wait for the service to time out.
/// </summary>
public sealed class ProductCatalog(IInventoryClient inventory, TimeProvider clock, TimeSpan maxAge, ILogger<ProductCatalog> logger)
{
    private static readonly TimeSpan RetryAfter = TimeSpan.FromSeconds(15);

    private CatalogSnapshot? _last;
    private long _retryAtTicks;

    public async Task<CatalogSnapshot> GetAsync(CancellationToken cancellationToken)
    {
        var now = clock.GetUtcNow();
        var last = Volatile.Read(ref _last);
        if (now.UtcTicks < Interlocked.Read(ref _retryAtTicks) && IsUsable(last, now))
        {
            return last! with { IsCached = true };
        }

        try
        {
            var products = await inventory.GetProductsAsync(cancellationToken).ConfigureAwait(false);
            var snapshot = new CatalogSnapshot(products, clock.GetUtcNow(), IsCached: false);
            Volatile.Write(ref _last, snapshot);
            Interlocked.Exchange(ref _retryAtTicks, 0);
            return snapshot;
        }
        catch (InventoryUnavailableException ex)
        {
            now = clock.GetUtcNow();
            Interlocked.Exchange(ref _retryAtTicks, (now + RetryAfter).UtcTicks);
            last = Volatile.Read(ref _last);
            if (!IsUsable(last, now))
            {
                throw;
            }

            logger.LogWarning("Inventory service unavailable ({Reason}); using the products fetched at {FetchedAt:O}",
                ex.Message, last!.FetchedAt);
            return last with { IsCached = true };
        }
    }

    private bool IsUsable(CatalogSnapshot? snapshot, DateTimeOffset now) =>
        snapshot is not null && now - snapshot.FetchedAt <= maxAge;
}

/// <param name="IsCached">True when the inventory service was unavailable and this is the last list fetched.</param>
public sealed record CatalogSnapshot(IReadOnlyList<Product> Products, DateTimeOffset FetchedAt, bool IsCached);
