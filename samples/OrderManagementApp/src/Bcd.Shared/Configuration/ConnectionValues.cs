using Microsoft.Extensions.Configuration;

namespace Bcd.Shared.Configuration;

/// <summary>
/// Reads values that Radius injects into the container for a named connection.
///
/// Radius injects one environment variable per property of the connected resource, named
/// <c>CONNECTION_&lt;CONNECTION-NAME&gt;_&lt;PROPERTY-NAME&gt;</c>. For a connection named
/// <c>queue</c> exposing a <c>host</c> property the variable is <c>CONNECTION_QUEUE_HOST</c>.
///
/// A <c>Bcd:&lt;connection&gt;:&lt;property&gt;</c> configuration fallback is supported so the
/// same binaries run under docker-compose or <c>dotnet run</c> without Radius.
/// </summary>
public sealed class ConnectionValues(IConfiguration configuration, string connectionName)
{
    private readonly IConfiguration _configuration = configuration;
    private readonly string _connectionName = connectionName;

    public string Name => _connectionName;

    public string? Get(string property)
    {
        var radiusKey = $"CONNECTION_{_connectionName.ToUpperInvariant()}_{property.ToUpperInvariant()}";
        var value = _configuration[radiusKey];
        if (!string.IsNullOrWhiteSpace(value))
        {
            return value;
        }

        value = _configuration[$"Bcd:{_connectionName}:{property}"];
        return string.IsNullOrWhiteSpace(value) ? null : value;
    }

    public string GetRequired(string property) =>
        Get(property) ?? throw new InvalidOperationException(
            $"Missing configuration for connection '{_connectionName}' property '{property}'. " +
            $"Expected environment variable CONNECTION_{_connectionName.ToUpperInvariant()}_{property.ToUpperInvariant()} " +
            $"or configuration key Bcd:{_connectionName}:{property}.");

    public int GetInt32(string property, int defaultValue) =>
        int.TryParse(Get(property), out var parsed) ? parsed : defaultValue;

    public bool GetBoolean(string property, bool defaultValue) =>
        bool.TryParse(Get(property), out var parsed) ? parsed : defaultValue;
}
