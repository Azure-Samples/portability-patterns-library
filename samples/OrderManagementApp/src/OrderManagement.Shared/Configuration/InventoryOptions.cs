using Microsoft.Extensions.Configuration;

namespace OrderManagement.Shared.Configuration;

/// <summary>
/// How the api and the processor reach the inventory service: <c>Inventory__BaseUrl</c> and, where
/// Entra ID issues the service tokens, <c>Inventory__Scope</c>.
/// </summary>
public sealed class InventoryOptions
{
    public required Uri BaseUrl { get; init; }

    /// <summary>Entra ID scope, for example <c>api://&lt;inventory-client-id&gt;/.default</c>. Empty with Keycloak.</summary>
    public string? Scope { get; init; }

    public static InventoryOptions FromConfiguration(IConfiguration configuration)
    {
        var section = configuration.GetSection("Inventory");
        var baseUrl = section["BaseUrl"];
        if (string.IsNullOrWhiteSpace(baseUrl) || !Uri.TryCreate(baseUrl, UriKind.Absolute, out var uri))
        {
            throw new InvalidOperationException(
                "Missing or invalid Inventory__BaseUrl, for example http://inventory:8080.");
        }

        return new InventoryOptions
        {
            BaseUrl = uri,
            Scope = string.IsNullOrWhiteSpace(section["Scope"]) ? null : section["Scope"]
        };
    }
}
