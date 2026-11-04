using System.ComponentModel.DataAnnotations;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Options;
using OrderManagement.Shared.Identity;

namespace OrderManagement.Shared.Configuration;

public enum ArchiveProvider
{
    AzureBlob,
    S3
}

/// <summary>
/// The <c>archive</c> connection, backed by the built-in <c>Radius.Storage/objectStorage</c> Resource
/// Type, and the client's tunables from the <c>Archive</c> section.
///
/// On Azure this is a blob container in a storage account, reached with the workload identity. On
/// Azure Local it is a bucket in the site's S3-compatible object store (SeaweedFS), reached with the
/// S3 keys the platform issues to the services connected to it.
/// </summary>
public sealed class ArchiveOptions
{
    public const string ConnectionName = "archive";
    public const string SectionName = "Archive";

    /// <summary>The blob container, or on S3 the bucket.</summary>
    [Required]
    public string? ContainerName { get; set; }

    /// <summary>
    /// Blob service endpoint, for example <c>https://mystorage.blob.core.windows.net</c>, or the S3
    /// endpoint, for example <c>https://seaweedfs-s3.object-store.svc.cluster.local:8443</c>.
    /// </summary>
    [Required]
    public Uri? Endpoint { get; set; }

    /// <summary>S3 access key ID. Present only on S3, where it selects that provider.</summary>
    public string? AccessKeyId { get; set; }

    public string? SecretAccessKey { get; set; }

    /// <summary>The region S3 requests are signed for. A self-hosted store accepts any.</summary>
    [Required]
    public string Region { get; set; } = "us-east-1";

    /// <summary>Retries of a failed request, with exponential backoff, by the storage SDK itself.</summary>
    [Range(0, 20)]
    public int MaxRetries { get; set; } = 3;

    public TimeSpan RetryDelay { get; set; } = TimeSpan.FromSeconds(0.8);

    public TimeSpan MaxRetryDelay { get; set; } = TimeSpan.FromMinutes(1);

    /// <summary>How long one request may take.</summary>
    public TimeSpan RequestTimeout { get; set; } = TimeSpan.FromSeconds(100);

    public ArchiveProvider Provider => AccessKeyId is null ? ArchiveProvider.AzureBlob : ArchiveProvider.S3;

    public static OptionsBuilder<ArchiveOptions> Add(IServiceCollection services) =>
        services.AddConnectionOptions<ArchiveOptions>(ConnectionName, SectionName, (options, values) =>
            {
                options.ContainerName = values.Get("containerName");
                options.Endpoint = values.Get("endpoint") is { } endpoint
                    ? Uri.TryCreate(endpoint, UriKind.Absolute, out var uri)
                        ? uri
                        : throw new InvalidOperationException($"{values.Key("endpoint")} must be an absolute URL, not '{endpoint}'.")
                    : null;
                options.AccessKeyId = values.Get("accessKeyId");
                options.SecretAccessKey = values.Get("secretAccessKey");
            })
            .Validate(options => options.AccessKeyId is null || options.SecretAccessKey is not null,
                "S3 object storage needs both keys: CONNECTION_ARCHIVE_ACCESSKEYID and CONNECTION_ARCHIVE_SECRETACCESSKEY.")
            .Validate<WorkloadIdentity>(
                (options, identity) => options.Provider != ArchiveProvider.AzureBlob || identity.Entra is not null,
                "Blob storage needs the pod's Entra workload identity (AZURE_CLIENT_ID and AZURE_FEDERATED_TOKEN_FILE).");
}
