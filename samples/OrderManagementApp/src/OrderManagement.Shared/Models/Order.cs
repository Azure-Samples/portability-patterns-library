using System.Text.Json;
using System.Text.Json.Serialization;

namespace OrderManagement.Shared.Models;

/// <summary>One line of an order, priced by the server from <see cref="ProductCatalog"/>.</summary>
public sealed record OrderLine
{
    [JsonPropertyName("sku")]
    public required string Sku { get; init; }

    [JsonPropertyName("productName")]
    public required string ProductName { get; init; }

    [JsonPropertyName("quantity")]
    public required int Quantity { get; init; }

    [JsonPropertyName("unitPrice")]
    public required decimal UnitPrice { get; init; }

    [JsonPropertyName("lineTotal")]
    public decimal LineTotal => UnitPrice * Quantity;
}

/// <summary>
/// An order placed by a signed-in user. Flows API -> queue -> processor, which archives it to object
/// storage and records it in SQL.
/// </summary>
public sealed record Order
{
    /// <summary>Identifies an order on the queue; any other message is skipped by the processor.</summary>
    public const string OrderPlacedType = "OrderPlaced";

    [JsonPropertyName("messageType")]
    public string MessageType => OrderPlacedType;

    [JsonPropertyName("orderId")]
    public required Guid OrderId { get; init; }

    /// <summary>Stable user identifier: the token's <c>oid</c> (Entra) or its Keycloak equivalent.</summary>
    [JsonPropertyName("customerId")]
    public required string CustomerId { get; init; }

    [JsonPropertyName("customerName")]
    public required string CustomerName { get; init; }

    [JsonPropertyName("lines")]
    public required IReadOnlyList<OrderLine> Lines { get; init; }

    [JsonPropertyName("currency")]
    public string Currency { get; init; } = ProductCatalog.Currency;

    [JsonPropertyName("total")]
    public decimal Total => Lines.Sum(line => line.LineTotal);

    [JsonPropertyName("placedAt")]
    public required DateTimeOffset PlacedAt { get; init; }

    public static readonly JsonSerializerOptions SerializerOptions = new(JsonSerializerDefaults.Web)
    {
        WriteIndented = true
    };

    public string ToJson() => JsonSerializer.Serialize(this, SerializerOptions);

    public static Order FromJson(string json) =>
        JsonSerializer.Deserialize<Order>(json, SerializerOptions)
        ?? throw new InvalidOperationException("Message body did not deserialize into an Order.");

    /// <summary>True when a queue message body carries an order.</summary>
    public static bool IsOrderMessage(string json)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            return document.RootElement.ValueKind == JsonValueKind.Object
                && document.RootElement.TryGetProperty("messageType", out var type)
                && type.ValueKind == JsonValueKind.String
                && type.GetString() == OrderPlacedType;
        }
        catch (JsonException)
        {
            return false;
        }
    }
}

/// <summary>A product the customer can order.</summary>
public sealed record Product(
    [property: JsonPropertyName("sku")] string Sku,
    [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("unitPrice")] decimal UnitPrice);

/// <summary>What the client asks for; prices are never taken from the client.</summary>
public sealed record OrderRequest
{
    [JsonPropertyName("items")]
    public IReadOnlyList<OrderRequestItem>? Items { get; init; }
}

public sealed record OrderRequestItem
{
    [JsonPropertyName("sku")]
    public string? Sku { get; init; }

    [JsonPropertyName("quantity")]
    public int Quantity { get; init; }
}

/// <summary>Fixed product catalog. Prices live on the server so a client cannot set its own.</summary>
public static class ProductCatalog
{
    public const string Currency = "USD";
    public const int MaxLines = 20;
    public const int MaxQuantity = 100;

    public static IReadOnlyList<Product> Products { get; } =
    [
        new("GEN-500", "Backup generator 500 kW", 18500.00m),
        new("UPS-20", "UPS battery module 20 kVA", 2400.00m),
        new("SAT-01", "Satellite uplink terminal", 6100.00m),
        new("RAD-10", "Two-way radio kit (10 units)", 1250.00m),
        new("WAT-200", "Water purification unit", 890.00m)
    ];

    public static Product? Find(string? sku) =>
        Products.FirstOrDefault(product => string.Equals(product.Sku, sku, StringComparison.OrdinalIgnoreCase));

    /// <summary>
    /// Validates a request against the catalog and prices it. Lines for the same SKU are merged.
    /// </summary>
    /// <returns>The order lines, or the validation errors keyed by field.</returns>
    public static (IReadOnlyList<OrderLine>? Lines, IDictionary<string, string[]>? Errors) Price(OrderRequest? request)
    {
        var errors = new Dictionary<string, string[]>();
        var items = request?.Items;

        if (items is null || items.Count == 0)
        {
            errors["items"] = ["An order needs at least one item."];
            return (null, errors);
        }

        if (items.Count > MaxLines)
        {
            errors["items"] = [$"An order can have at most {MaxLines} items."];
            return (null, errors);
        }

        var quantities = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        for (var i = 0; i < items.Count; i++)
        {
            var item = items[i];
            var product = Find(item.Sku);
            if (product is null)
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

        if (errors.Count > 0)
        {
            return (null, errors);
        }

        var lines = quantities
            .Select(entry =>
            {
                var product = Find(entry.Key)!;
                return new OrderLine
                {
                    Sku = product.Sku,
                    ProductName = product.Name,
                    Quantity = entry.Value,
                    UnitPrice = product.UnitPrice
                };
            })
            .ToList();

        return (lines, null);
    }
}
