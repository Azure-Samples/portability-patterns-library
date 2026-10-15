using Microsoft.Extensions.Configuration;

namespace Bcd.Shared.Configuration;

/// <summary>
/// Settings for the <c>archive</c> connection, backed by the built-in
/// <c>Radius.Storage/objectStorage</c> Resource Type.
///
/// In Azure this resolves to an Azure Storage account reached over its blob endpoint using
/// Workload Identity. Locally it resolves to Azurite, reached with a development connection string.
/// </summary>
public sealed class ArchiveOptions
{
    public required string ContainerName { get; init; }

    /// <summary>Blob service endpoint, for example <c>https://mystorage.blob.core.windows.net</c>.</summary>
    public string? Endpoint { get; init; }

    public string? AccountName { get; init; }

    /// <summary>Set only for local/dev (Azurite). When present it takes precedence over managed identity.</summary>
    public string? ConnectionString { get; init; }

    /// <summary>Client ID of the user-assigned managed identity federated with the cluster (FIC).</summary>
    public string? WorkloadIdentityClientId { get; init; }

    public bool UseManagedIdentity => string.IsNullOrWhiteSpace(ConnectionString);

    public static ArchiveOptions FromConfiguration(IConfiguration configuration, string connectionName = "archive")
    {
        var values = new ConnectionValues(configuration, connectionName);

        return new ArchiveOptions
        {
            ContainerName = values.Get("containerName") ?? "business-events",
            Endpoint = values.Get("endpoint"),
            AccountName = values.Get("accountName"),
            ConnectionString = values.Get("connectionString"),
            WorkloadIdentityClientId = values.Get("workloadIdentityClientId")
        };
    }
}
