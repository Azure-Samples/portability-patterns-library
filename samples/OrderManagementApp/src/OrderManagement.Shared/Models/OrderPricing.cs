namespace OrderManagement.Shared.Models;

/// <summary>
/// Validates an order request and prices it from the inventory service's products. Prices live on
/// the server so a client cannot set its own. Stock is not checked here: the processor reserves it.
/// </summary>
public static class OrderPricing
{
    public const string DefaultCurrency = "USD";
    public const int MaxLines = 20;
    public const int MaxQuantity = 100;

    /// <summary>Lines for the same SKU are merged.</summary>
    /// <returns>The order lines and their currency, or the validation errors keyed by field.</returns>
    public static (IReadOnlyList<OrderLine>? Lines, string Currency, IDictionary<string, string[]>? Errors) Price(
        OrderRequest? request, IReadOnlyList<Product> products)
    {
        var errors = new Dictionary<string, string[]>();
        var items = request?.Items;

        if (items is null || items.Count == 0)
        {
            errors["items"] = ["An order needs at least one item."];
            return (null, DefaultCurrency, errors);
        }

        if (items.Count > MaxLines)
        {
            errors["items"] = [$"An order can have at most {MaxLines} items."];
            return (null, DefaultCurrency, errors);
        }

        var catalog = products.ToDictionary(product => product.Sku, StringComparer.OrdinalIgnoreCase);
        var quantities = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        for (var i = 0; i < items.Count; i++)
        {
            var item = items[i];
            if (item.Sku is null || !catalog.TryGetValue(item.Sku, out var product))
            {
                errors[$"items[{i}].sku"] = [$"Unknown product '{item.Sku}'."];
                continue;
            }

            if (item.Quantity is < 1 or > MaxQuantity)
            {
                errors[$"items[{i}].quantity"] = [$"Quantity must be between 1 and {MaxQuantity}."];
                continue;
            }

            quantities[product.Sku] = quantities.GetValueOrDefault(product.Sku) + item.Quantity;
        }

        foreach (var (sku, quantity) in quantities)
        {
            if (quantity > MaxQuantity)
            {
                errors[$"items.{sku}"] = [$"Total quantity for '{sku}' must not exceed {MaxQuantity}."];
            }
        }

        var currencies = quantities.Keys.Select(sku => catalog[sku].Currency).Distinct(StringComparer.Ordinal).ToList();
        if (currencies.Count > 1)
        {
            errors["items"] = ["All items in an order must be priced in the same currency."];
        }

        if (errors.Count > 0)
        {
            return (null, DefaultCurrency, errors);
        }

        var lines = quantities
            .Select(entry =>
            {
                var product = catalog[entry.Key];
                return new OrderLine
                {
                    Sku = product.Sku,
                    ProductName = product.Name,
                    Quantity = entry.Value,
                    UnitPrice = product.UnitPrice
                };
            })
            .ToList();

        return (lines, currencies[0], null);
    }
}
