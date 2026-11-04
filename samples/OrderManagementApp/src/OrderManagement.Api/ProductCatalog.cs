using Microsoft.Extensions.Caching.Memory;
using Microsoft.Extensions.Options;
using OrderManagement.Shared.Inventory;
using OrderManagement.Shared.Models;

namespace OrderManagement.Api;

/// <summary>From the <c>Inventory</c> section.</summary>
public sealed class ProductCatalogOptions
{
    /// <summary><c>Inventory__PriceCacheMaxAge</c>: the oldest product list orders may still be priced from.</summary>
    public TimeSpan PriceCacheMaxAge { get; set; } = TimeSpan.FromHours(1);
}

/// <summary>
/// The inventory service's products, as the API shows them and prices orders from them. Keeps the
/// last list it fetched, for <see cref="ProductCatalogOptions.PriceCacheMaxAge"/>: while the inventory
/// service is down, the product list still shows and orders are still priced and queued, and the
/// processor reserves their stock once the service is back. While the inventory client's circuit
/// breaker is open, calls fail at once, so users don't each wait for the service to time out.
/// </summary>
public sealed class ProductCatalog(
    IInventoryClient inventory,
    IMemoryCache cache,
    IOptions<ProductCatalogOptions> options,
    TimeProvider clock,
    ILogger<ProductCatalog> logger)
{
    private const string LastFetchedKey = "product-catalog";

    public async Task<CatalogSnapshot> GetAsync(CancellationToken cancellationToken)
    {
        try
        {
            var products = await inventory.GetProductsAsync(cancellationToken);
            var snapshot = new CatalogSnapshot(products, clock.GetUtcNow(), IsCached: false);
            cache.Set(LastFetchedKey, snapshot, options.Value.PriceCacheMaxAge);
            return snapshot;
        }
        catch (InventoryUnavailableException ex) when (cache.TryGetValue(LastFetchedKey, out CatalogSnapshot? last))
        {
            logger.LogWarning("Inventory service unavailable ({Reason}); using the products fetched at {FetchedAt:O}",
                ex.Message, last!.FetchedAt);
            return last with { IsCached = true };
        }
    }
}

/// <param name="IsCached">True when the inventory service was unavailable and this is the last list fetched.</param>
public sealed record CatalogSnapshot(IReadOnlyList<Product> Products, DateTimeOffset FetchedAt, bool IsCached);
