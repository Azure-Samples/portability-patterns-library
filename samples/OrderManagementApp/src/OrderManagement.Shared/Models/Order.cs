using System.Text.Json;
using System.Text.Json.Serialization;

namespace OrderManagement.Shared.Models;

/// <summary>One line of an order, priced by the server from the inventory service's products.</summary>
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
    public string Currency { get; init; } = OrderPricing.DefaultCurrency;

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
