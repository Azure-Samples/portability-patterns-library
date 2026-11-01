using System.Text.Json.Serialization;
using OrderManagement.Shared.Models;

namespace OrderManagement.Shared.Persistence;

/// <summary>An order as recorded by the processor.</summary>
public sealed record StoredOrder
{
    [JsonPropertyName("orderId")]
    public required Guid OrderId { get; init; }

    [JsonPropertyName("customerName")]
    public required string CustomerName { get; init; }

    [JsonPropertyName("lines")]
    public required IReadOnlyList<OrderLine> Lines { get; init; }

    [JsonPropertyName("total")]
    public required decimal Total { get; init; }

    [JsonPropertyName("currency")]
    public required string Currency { get; init; }

    [JsonPropertyName("placedAt")]
    public required DateTimeOffset PlacedAt { get; init; }

    [JsonPropertyName("processedAt")]
    public required DateTimeOffset ProcessedAt { get; init; }

    [JsonPropertyName("archiveUri")]
    public required string ArchiveUri { get; init; }

    /// <summary><see cref="OrderStatus.Processed"/> or <see cref="OrderStatus.Rejected"/>.</summary>
    [JsonPropertyName("status")]
    public required string Status { get; init; }

    [JsonPropertyName("statusReason")]
    public string? StatusReason { get; init; }
}
