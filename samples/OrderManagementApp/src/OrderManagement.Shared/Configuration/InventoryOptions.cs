using System.ComponentModel.DataAnnotations;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Options;
using OrderManagement.Shared.Identity;

namespace OrderManagement.Shared.Configuration;

/// <summary>
/// How the api and the processor reach the inventory service, from the <c>Inventory</c> section:
/// <c>Inventory__BaseUrl</c> and, where Entra ID issues the service tokens, <c>Inventory__Scope</c>.
/// Retries, timeouts and the circuit breaker are in <c>Inventory:Resilience</c>
/// (<see cref="Microsoft.Extensions.Http.Resilience.HttpStandardResilienceOptions"/>).
/// </summary>
public sealed class InventoryOptions
{
    public const string SectionName = "Inventory";

    /// <summary>For example <c>http://inventory:8080</c>.</summary>
    [Required]
    public Uri? BaseUrl { get; set; }

    /// <summary>Entra ID scope, for example <c>api://&lt;inventory-client-id&gt;/.default</c>. Empty with Keycloak.</summary>
    public string? Scope { get; set; }

    public static OptionsBuilder<InventoryOptions> Add(IServiceCollection services) =>
        services.AddOptions<InventoryOptions>()
            .BindConfiguration(SectionName)
            .ValidateDataAnnotations()
            .Validate(options => options.BaseUrl is null || options.BaseUrl.IsAbsoluteUri,
                "Inventory__BaseUrl must be an absolute URL, for example http://inventory:8080.")
            .Validate<WorkloadIdentity>((options, identity) => identity.Entra is null || !string.IsNullOrWhiteSpace(options.Scope),
                "The pod has an Entra workload identity but no scope to request the inventory service's token for. Set Inventory__Scope.")
            .ValidateOnStart();
}
