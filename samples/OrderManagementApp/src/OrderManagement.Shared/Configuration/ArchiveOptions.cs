using Microsoft.Extensions.Configuration;

namespace OrderManagement.Shared.Configuration;

/// <summary>
/// Settings for the <c>archive</c> connection, backed by the built-in
/// <c>Radius.Storage/objectStorage</c> Resource Type.
///
/// In Azure this resolves to an Azure Storage account reached over its blob endpoint using
/// Workload Identity. On Azure Local it resolves to Azurite, reached with the connection string its Recipe issues.
/// </summary>
public sealed class ArchiveOptions
{
    public required string ContainerName { get; init; }

    /// <summary>Blob service endpoint, for example <c>https://mystorage.blob.core.windows.net</c>.</summary>
    public string? Endpoint { get; init; }

    public string? AccountName { get; init; }

    /// <summary>Issued only by the Azurite Recipe. When present it takes precedence over managed identity.</summary>
    public string? ConnectionString { get; init; }

    public bool UseManagedIdentity => string.IsNullOrWhiteSpace(ConnectionString);

    public static ArchiveOptions FromConfiguration(IConfiguration configuration, string connectionName = "archive")
    {
        var values = new ConnectionValues(configuration, connectionName);

        return new ArchiveOptions
        {
            ContainerName = values.Get("containerName") ?? "orders",
            Endpoint = values.Get("endpoint"),
            AccountName = values.Get("accountName"),
            ConnectionString = values.Get("connectionString")
        };
    }
}
