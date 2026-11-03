using Microsoft.Extensions.Configuration;

namespace OrderManagement.Shared.Configuration;

public enum ArchiveProvider
{
    AzureBlob,
    S3
}

/// <summary>
/// Settings for the <c>archive</c> connection, backed by the built-in
/// <c>Radius.Storage/objectStorage</c> Resource Type.
///
/// In Azure this resolves to an Azure Storage account reached over its blob endpoint using
/// Workload Identity. On Azure Local it resolves to a bucket in the site's S3-compatible object
/// store (SeaweedFS), reached with S3 keys the platform issues to the services connected to it.
/// </summary>
public sealed class ArchiveOptions
{
    /// <summary>The blob container, or on S3 the bucket.</summary>
    public required string ContainerName { get; init; }

    /// <summary>
    /// Blob service endpoint, for example <c>https://mystorage.blob.core.windows.net</c>, or the S3
    /// endpoint, for example <c>https://seaweedfs-s3.object-store.svc.cluster.local:8443</c>.
    /// </summary>
    public string? Endpoint { get; init; }

    public string? AccountName { get; init; }

    /// <summary>S3 access key ID. Present only on S3, where it selects that provider.</summary>
    public string? AccessKeyId { get; init; }

    public string? SecretAccessKey { get; init; }

    public ArchiveProvider Provider => string.IsNullOrWhiteSpace(AccessKeyId) ? ArchiveProvider.AzureBlob : ArchiveProvider.S3;

    public static ArchiveOptions FromConfiguration(IConfiguration configuration, string connectionName = "archive")
    {
        var values = new ConnectionValues(configuration, connectionName);
        var options = new ArchiveOptions
        {
            ContainerName = values.Get("containerName") ?? "orders",
            Endpoint = values.Get("endpoint"),
            AccountName = values.Get("accountName"),
            AccessKeyId = values.Get("accessKeyId"),
            SecretAccessKey = values.Get("secretAccessKey")
        };

        if (options.Endpoint is null)
        {
            throw new InvalidOperationException(
                $"Object storage requires an endpoint: CONNECTION_{connectionName.ToUpperInvariant()}_ENDPOINT.");
        }
        if (options.Provider == ArchiveProvider.S3 && options.SecretAccessKey is null)
        {
            throw new InvalidOperationException(
                $"S3 object storage requires both keys: CONNECTION_{connectionName.ToUpperInvariant()}_ACCESSKEYID and _SECRETACCESSKEY.");
        }

        return options;
    }
}
