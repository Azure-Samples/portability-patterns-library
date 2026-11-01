using System.Text.Json.Serialization;

namespace OrderManagement.Shared.Models;

/// <summary>A product as the inventory service reports it: price and current stock.</summary>
public sealed record Product
{
    [JsonPropertyName("sku")]
    public required string Sku { get; init; }

    [JsonPropertyName("name")]
    public required string Name { get; init; }

    [JsonPropertyName("unitPrice")]
    public required decimal UnitPrice { get; init; }

    [JsonPropertyName("currency")]
    public required string Currency { get; init; }

    /// <summary>Units in stock and not reserved by an order.</summary>
    [JsonPropertyName("available")]
    public required int Available { get; init; }

    /// <summary>At or below this level the product should be restocked.</summary>
    [JsonPropertyName("reorderLevel")]
    public required int ReorderLevel { get; init; }
}
