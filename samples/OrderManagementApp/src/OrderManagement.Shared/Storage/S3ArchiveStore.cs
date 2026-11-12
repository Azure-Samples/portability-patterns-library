using System.Net;
using Amazon.Runtime;
using Amazon.S3;
using Amazon.S3.Model;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using OrderManagement.Shared.Configuration;
using OrderManagement.Shared.Models;

namespace OrderManagement.Shared.Storage;

/// <summary>
/// S3 implementation, for an S3-compatible store such as SeaweedFS on Azure Local. Writes the same
/// objects as <see cref="BlobArchiveStore"/>: one JSON document per order under a date prefix. Failed
/// requests are retried by the SDK (<see cref="ArchiveOptions.MaxRetries"/>).
/// </summary>
public sealed class S3ArchiveStore : IArchiveStore, IDisposable
{
    private readonly AmazonS3Client _client;
    private readonly string _bucket;
    private readonly string _endpoint;

    public S3ArchiveStore(IOptions<ArchiveOptions> options)
    {
        var settings = options.Value;
        _bucket = settings.ContainerName!;
        _endpoint = settings.Endpoint!.ToString().TrimEnd('/');
        _client = new AmazonS3Client(
            new BasicAWSCredentials(settings.AccessKeyId, settings.SecretAccessKey),
            new AmazonS3Config
            {
                ServiceURL = _endpoint,
                // Buckets are addressed in the path; a self-hosted store has no per-bucket DNS names.
                ForcePathStyle = true,
                AuthenticationRegion = settings.Region,
                RetryMode = RequestRetryMode.Standard,
                MaxErrorRetry = settings.MaxRetries,
                Timeout = settings.RequestTimeout,
                // Newer SDKs add CRC checksums to every request by default, which S3-compatible
                // stores don't all accept; send them only where the S3 API requires one.
                RequestChecksumCalculation = RequestChecksumCalculation.WHEN_REQUIRED,
                ResponseChecksumValidation = ResponseChecksumValidation.WHEN_REQUIRED
            });
    }

    /// <summary>
    /// Creates the bucket when it doesn't exist. The platform grants the keys the right to create the
    /// bucket it named for them; any other refusal, a 403 included, is an error.
    /// </summary>
    /// <returns>True when the bucket was created.</returns>
    public async Task<bool> EnsureBucketAsync(CancellationToken cancellationToken)
    {
        try
        {
            await _client.HeadBucketAsync(new HeadBucketRequest { BucketName = _bucket }, cancellationToken).ConfigureAwait(false);
            return false;
        }
        catch (AmazonS3Exception ex) when (ex.StatusCode == HttpStatusCode.NotFound)
        {
            try
            {
                await _client.PutBucketAsync(new PutBucketRequest { BucketName = _bucket }, cancellationToken).ConfigureAwait(false);
                return true;
            }
            catch (AmazonS3Exception conflict) when (conflict.ErrorCode == "BucketAlreadyOwnedByYou")
            {
                // Another replica created it in the meantime.
                return false;
            }
        }
    }

    public async Task<string> ArchiveAsync(Order order, CancellationToken cancellationToken)
    {
        var key = $"{order.PlacedAt:yyyy/MM/dd}/{order.OrderId}.json";

        // Overwrites: a redelivered message must not fail on the object it already wrote.
        var request = new PutObjectRequest
        {
            BucketName = _bucket,
            Key = key,
            ContentBody = order.ToJson(),
            ContentType = "application/json",
            UseChunkEncoding = false
        };
        request.Metadata.Add("messageType", Order.OrderPlacedType);
        request.Metadata.Add("lineCount", order.Lines.Count.ToString(System.Globalization.CultureInfo.InvariantCulture));
        await _client.PutObjectAsync(request, cancellationToken).ConfigureAwait(false);

        return $"{_endpoint}/{_bucket}/{key}";
    }

    public void Dispose() => _client.Dispose();
}

/// <summary>Creates the bucket once, before the host starts consuming.</summary>
internal sealed class S3BucketInitializer(S3ArchiveStore store, IOptions<ArchiveOptions> options, ILogger<S3BucketInitializer> logger)
    : IHostedService
{
    public async Task StartAsync(CancellationToken cancellationToken)
    {
        var created = await store.EnsureBucketAsync(cancellationToken).ConfigureAwait(false);
        logger.LogInformation(created ? "Created bucket {Bucket}" : "Bucket {Bucket} exists", options.Value.ContainerName);
    }

    public Task StopAsync(CancellationToken cancellationToken) => Task.CompletedTask;
}
