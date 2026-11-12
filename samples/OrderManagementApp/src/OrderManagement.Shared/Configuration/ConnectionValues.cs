using System.Globalization;
using Microsoft.Extensions.Configuration;

namespace OrderManagement.Shared.Configuration;

/// <summary>
/// Reads values that Radius injects into the container for a named connection.
///
/// Radius injects one environment variable per property of the connected resource, named
/// <c>CONNECTION_&lt;CONNECTION-NAME&gt;_&lt;PROPERTY-NAME&gt;</c>. For a connection named
/// <c>queue</c> exposing an <c>endpoint</c> property the variable is <c>CONNECTION_QUEUE_ENDPOINT</c>.
/// </summary>
public sealed class ConnectionValues(IConfiguration configuration, string connectionName)
{
    public string? Get(string property)
    {
        var value = configuration[Key(property)];
        return string.IsNullOrWhiteSpace(value) ? null : value.Trim();
    }

    /// <summary>The value, or null when it is not set; a value that isn't a whole number is an error.</summary>
    public int? GetInt32(string property) =>
        Get(property) is not { } value
            ? null
            : int.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsed)
                ? parsed
                : throw new InvalidOperationException($"{Key(property)} must be a whole number, not '{value}'.");

    /// <summary>
    /// The connection's <c>tls</c> value: <c>required</c> (the default) or <c>optional</c>.
    /// </summary>
    public bool GetTlsRequired() => Get("tls")?.ToLowerInvariant() switch
    {
        null or "required" => true,
        "optional" => false,
        var other => throw new InvalidOperationException(
            $"{Key("tls")} must be 'required' or 'optional', not '{other}'.")
    };

    public string Key(string property) =>
        $"CONNECTION_{connectionName.ToUpperInvariant()}_{property.ToUpperInvariant()}";
}
