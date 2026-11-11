using Azure.Core;
using Azure.Storage.Blobs;
using Azure.Storage.Blobs.Models;
using Microsoft.Extensions.Options;
using OrderManagement.Shared.Configuration;
using OrderManagement.Shared.Identity;
using OrderManagement.Shared.Models;

namespace OrderManagement.Shared.Storage;

/// <summary>
/// Azure Blob Storage implementation, authenticated with the workload identity. The Recipe creates
/// the container and grants the identity data access to that container only, so this only writes.
/// Failed requests are retried by the SDK (<see cref="ArchiveOptions.MaxRetries"/>).
/// </summary>
public sealed class BlobArchiveStore : IArchiveStore
{
    private readonly BlobContainerClient _container;

    public BlobArchiveStore(IOptions<ArchiveOptions> options, WorkloadIdentity identity)
    {
        var settings = options.Value;
        var clientOptions = new BlobClientOptions();
        clientOptions.Retry.Mode = RetryMode.Exponential;
        clientOptions.Retry.MaxRetries = settings.MaxRetries;
        clientOptions.Retry.Delay = settings.RetryDelay;
        clientOptions.Retry.MaxDelay = settings.MaxRetryDelay;
        clientOptions.Retry.NetworkTimeout = settings.RequestTimeout;

        var credential = identity.Entra?.Credential
            ?? throw new InvalidOperationException("Blob storage needs the pod's Entra workload identity.");
        _container = new BlobServiceClient(settings.Endpoint, credential, clientOptions)
            .GetBlobContainerClient(settings.ContainerName);
    }

    public async Task<string> ArchiveAsync(Order order, CancellationToken cancellationToken)
    {
        // Date-partitioned layout keeps listings cheap as the archive grows.
        var blob = _container.GetBlobClient($"{order.PlacedAt:yyyy/MM/dd}/{order.OrderId}.json");

        // Overwrites: a redelivered message must not fail on the blob it already wrote.
        await blob.UploadAsync(
            BinaryData.FromString(order.ToJson()),
            new BlobUploadOptions
            {
                HttpHeaders = new BlobHttpHeaders { ContentType = "application/json" },
                Metadata = new Dictionary<string, string>
                {
                    ["messageType"] = Order.OrderPlacedType,
                    ["lineCount"] = order.Lines.Count.ToString(System.Globalization.CultureInfo.InvariantCulture)
                }
            },
            cancellationToken).ConfigureAwait(false);

        return blob.Uri.ToString();
    }
}
