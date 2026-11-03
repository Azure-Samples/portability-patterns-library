using Azure.Storage.Blobs;
using Azure.Storage.Blobs.Models;
using OrderManagement.Shared.Configuration;
using OrderManagement.Shared.Diagnostics;
using OrderManagement.Shared.Identity;
using OrderManagement.Shared.Models;
using Microsoft.Extensions.Logging;

namespace OrderManagement.Shared.Storage;

/// <summary>
/// Azure Blob Storage implementation: a storage account in Azure, authenticated with Workload
/// Identity.
/// </summary>
public sealed class BlobArchiveStore : IArchiveStore
{
    private readonly ArchiveOptions _options;
    private readonly ILogger<BlobArchiveStore> _logger;
    private readonly BlobContainerClient _containerClient;

    public BlobArchiveStore(ArchiveOptions options, ILogger<BlobArchiveStore> logger)
    {
        _options = options;
        _logger = logger;

        _logger.LogInformation("Connecting to blob endpoint {Endpoint} using workload identity", options.Endpoint);

        var credential = AzureCredentialFactory.Create();
        var serviceClient = new BlobServiceClient(new Uri(options.Endpoint!), credential);
        _containerClient = serviceClient.GetBlobContainerClient(options.ContainerName);
    }

    public async Task InitializeAsync(CancellationToken cancellationToken)
    {
        // The container must exist before the first upload. Creating it here (rather than in the
        // Recipe) keeps the Recipe platform-neutral, but it must not fail silently: swallowing an
        // error here turns into an endless stream of 404s on every message.
        //
        // The budget is generous because on a cold cluster the object store may still be pulling
        // its image when this worker starts. Too short a budget makes the worker crash-loop for
        // several minutes before the dependency is ready.
        const int maxAttempts = 30;
        for (var attempt = 1; ; attempt++)
        {
            try
            {
                await _containerClient.CreateIfNotExistsAsync(cancellationToken: cancellationToken)
                    .ConfigureAwait(false);

                _logger.LogInformation("Object storage container {Container} is ready", _options.ContainerName);
                return;
            }
            catch (Azure.RequestFailedException ex) when (ex.Status == 409)
            {
                // Already exists, possibly created concurrently by another replica.
                _logger.LogInformation("Object storage container {Container} already exists", _options.ContainerName);
                return;
            }
            catch (Azure.RequestFailedException ex) when (ex.Status is 403)
            {
                // The identity may only have data-plane write permission, with the container
                // pre-created by the Recipe. That is a valid configuration.
                _logger.LogWarning(
                    "Not permitted to create container {Container}; assuming the Recipe created it",
                    _options.ContainerName);
                return;
            }
            catch (Exception ex) when (attempt < maxAttempts && !cancellationToken.IsCancellationRequested)
            {
                var delay = TimeSpan.FromSeconds(Math.Min(10, attempt * 2));

                // Summarised at warning; the full exception is available at debug level.
                _logger.LogWarning(
                    "Object storage not ready (attempt {Attempt}/{MaxAttempts}): {Reason}. Retrying in {Delay}",
                    attempt, maxAttempts, ExceptionSummary.Describe(ex), delay);
                _logger.LogDebug(ex, "Object storage initialization attempt {Attempt} failed", attempt);

                await Task.Delay(delay, cancellationToken).ConfigureAwait(false);
            }
        }
    }

    public async Task<string> ArchiveAsync(Order order, CancellationToken cancellationToken)
    {
        // Date-partitioned layout keeps listings cheap as the archive grows.
        var blobClient = _containerClient.GetBlobClient($"{order.PlacedAt:yyyy/MM/dd}/{order.OrderId}.json");

        try
        {
            await UploadAsync(blobClient, order, cancellationToken).ConfigureAwait(false);
        }
        catch (Azure.RequestFailedException ex) when (ex.ErrorCode == BlobErrorCode.ContainerNotFound)
        {
            // The container can be deleted after startup. Without this every later order would fail
            // until the worker restarts.
            _logger.LogWarning("Object storage container {Container} is missing; creating it again", _options.ContainerName);
            await _containerClient.CreateIfNotExistsAsync(cancellationToken: cancellationToken).ConfigureAwait(false);
            await UploadAsync(blobClient, order, cancellationToken).ConfigureAwait(false);
        }

        return blobClient.Uri.ToString();
    }

    private static async Task UploadAsync(BlobClient blobClient, Order order, CancellationToken cancellationToken)
    {
        using var content = new MemoryStream(System.Text.Encoding.UTF8.GetBytes(order.ToJson()));

        // Overwrite: a redelivered message must not fail on the blob it already wrote.
        await blobClient.UploadAsync(
            content,
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
    }
}
