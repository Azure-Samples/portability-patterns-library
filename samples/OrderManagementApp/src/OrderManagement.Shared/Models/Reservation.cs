using System.Text.Json.Serialization;

namespace OrderManagement.Shared.Models;

/// <summary>Asks the inventory service to set stock aside for an order, all lines or none.</summary>
public sealed record ReservationRequest
{
    [JsonPropertyName("orderId")]
    public required Guid OrderId { get; init; }

    [JsonPropertyName("lines")]
    public required IReadOnlyList<ReservationLine> Lines { get; init; }
}

public sealed record ReservationLine
{
    [JsonPropertyName("sku")]
    public required string Sku { get; init; }

    [JsonPropertyName("quantity")]
    public required int Quantity { get; init; }
}

/// <summary>The outcome of a reservation. Repeating a request for the same order returns the same outcome.</summary>
public sealed record ReservationResult
{
    [JsonPropertyName("orderId")]
    public required Guid OrderId { get; init; }

    /// <summary><see cref="ReservationStatus.Reserved"/> or <see cref="ReservationStatus.OutOfStock"/>.</summary>
    [JsonPropertyName("status")]
    public required string Status { get; init; }

    [JsonPropertyName("unavailableSkus")]
    public IReadOnlyList<string> UnavailableSkus { get; init; } = [];
}

public static class ReservationStatus
{
    public const string Reserved = "Reserved";
    public const string OutOfStock = "OutOfStock";

    /// <summary>The order's stock was given back. Reserving for the order again is allowed.</summary>
    public const string Released = "Released";
}

/// <summary>Adds stock to a product.</summary>
public sealed record RestockRequest
{
    public const int MaxQuantity = 10_000;

    [JsonPropertyName("quantity")]
    public int Quantity { get; init; }

    public bool IsValid => Quantity is > 0 and <= MaxQuantity;
}
