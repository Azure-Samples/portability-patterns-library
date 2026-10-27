using Azure.Storage.Blobs;
using Azure.Storage.Blobs.Models;
using OrderManagement.Shared.Configuration;
using OrderManagement.Shared.Diagnostics;
using OrderManagement.Shared.Identity;
using OrderManagement.Shared.Models;
using Microsoft.Extensions.Logging;

namespace OrderManagement.Shared.Storage;

/// <summary>
/// Azure Blob Storage implementation. Backed by a real storage account in Azure (authenticated with
/// Workload Identity) and by Azurite locally (authenticated with the well-known dev connection
/// string emitted by the local recipe).
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

        if (_options.UseManagedIdentity)
        {
            var endpoint = options.Endpoint ?? throw new InvalidOperationException(
                "Object storage requires either 'endpoint' (with managed identity) or 'connectionString'.");

            _logger.LogInformation(
                "Connecting to blob endpoint {Endpoint} using workload identity",
                endpoint);

            var credential = AzureCredentialFactory.Create();
            var serviceClient = new BlobServiceClient(new Uri(endpoint), credential);
            _containerClient = serviceClient.GetBlobContainerClient(options.ContainerName);
        }
        else
        {
            // A connection string means the local emulator. Azurite implements an older REST API
            // than this SDK negotiates by default, which makes it reject requests with 400. Pinning
            // the service version keeps the SDK within what the emulator understands. Real Azure
            // Storage always uses the SDK default above.
            _logger.LogInformation(
                "Connecting to blob storage with a connection string (Azurite), pinned to service version {Version}",
                EmulatorServiceVersion);

            var clientOptions = new BlobClientOptions(EmulatorServiceVersion);
            var serviceClient = new BlobServiceClient(options.ConnectionString, clientOptions);
            _containerClient = serviceClient.GetBlobContainerClient(options.ContainerName);
        }
    }

    /// <summary>
    /// REST API version used when talking to Azurite. Must not exceed what the emulator supports.
    /// </summary>
    private const BlobClientOptions.ServiceVersion EmulatorServiceVersion =
        BlobClientOptions.ServiceVersion.V2023_11_03;

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

        return blobClient.Uri.ToString();
    }
}
