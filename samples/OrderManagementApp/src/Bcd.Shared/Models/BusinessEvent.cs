using System.Text.Json;
using System.Text.Json.Serialization;

namespace Bcd.Shared.Models;

/// <summary>
/// The randomly generated business continuity event that flows publisher -> queue -> consumer.
/// </summary>
public sealed record BusinessEvent
{
    [JsonPropertyName("eventId")]
    public required Guid EventId { get; init; }

    [JsonPropertyName("eventType")]
    public required string EventType { get; init; }

    [JsonPropertyName("region")]
    public required string Region { get; init; }

    [JsonPropertyName("businessUnit")]
    public required string BusinessUnit { get; init; }

    [JsonPropertyName("severity")]
    public required int Severity { get; init; }

    [JsonPropertyName("estimatedImpactUsd")]
    public required decimal EstimatedImpactUsd { get; init; }

    [JsonPropertyName("detectedBy")]
    public required string DetectedBy { get; init; }

    [JsonPropertyName("occurredAt")]
    public required DateTimeOffset OccurredAt { get; init; }

    [JsonPropertyName("details")]
    public required IReadOnlyDictionary<string, string> Details { get; init; }

    public static readonly JsonSerializerOptions SerializerOptions = new(JsonSerializerDefaults.Web)
    {
        WriteIndented = true
    };

    public string ToJson() => JsonSerializer.Serialize(this, SerializerOptions);

    public static BusinessEvent FromJson(string json) =>
        JsonSerializer.Deserialize<BusinessEvent>(json, SerializerOptions)
        ?? throw new InvalidOperationException("Message body did not deserialize into a BusinessEvent.");
}
