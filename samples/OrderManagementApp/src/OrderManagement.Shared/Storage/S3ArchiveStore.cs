using System.Net;
using Amazon.Runtime;
using Amazon.S3;
using Amazon.S3.Model;
using OrderManagement.Shared.Configuration;
using OrderManagement.Shared.Diagnostics;
using OrderManagement.Shared.Models;
using Microsoft.Extensions.Logging;

namespace OrderManagement.Shared.Storage;

/// <summary>
/// S3 implementation, for an S3-compatible store such as SeaweedFS on Azure Local. Writes the same
/// objects as <see cref="BlobArchiveStore"/>: one JSON document per order under a date prefix.
/// </summary>
public sealed class S3ArchiveStore : IArchiveStore, IDisposable
{
    private readonly ArchiveOptions _options;
    private readonly ILogger<S3ArchiveStore> _logger;
    private readonly AmazonS3Client _client;
    private readonly string _endpoint;

    public S3ArchiveStore(ArchiveOptions options, ILogger<S3ArchiveStore> logger)
    {
        _options = options;
        _logger = logger;
        _endpoint = options.Endpoint!.TrimEnd('/');

        _logger.LogInformation("Connecting to S3 endpoint {Endpoint}, bucket {Bucket}", _endpoint, options.ContainerName);

        _client = new AmazonS3Client(
            new BasicAWSCredentials(options.AccessKeyId, options.SecretAccessKey),
            new AmazonS3Config
            {
                ServiceURL = _endpoint,
                // Buckets are addressed in the path; a self-hosted store has no per-bucket DNS names.
                ForcePathStyle = true,
                AuthenticationRegion = "us-east-1",
                // Newer SDKs add CRC checksums to every request by default, which S3-compatible
                // stores don't all accept; send them only where the S3 API requires one.
                RequestChecksumCalculation = RequestChecksumCalculation.WHEN_REQUIRED,
                ResponseChecksumValidation = ResponseChecksumValidation.WHEN_REQUIRED
            });
    }

    public async Task InitializeAsync(CancellationToken cancellationToken)
    {
        // As for blob storage: the bucket must exist before the first upload, and a failure here
        // must not be swallowed. The budget covers an object store that is still starting.
        const int maxAttempts = 30;
        for (var attempt = 1; ; attempt++)
        {
            try
            {
                try
                {
                    await CreateBucketAsync(cancellationToken).ConfigureAwait(false);
                }
                catch (AmazonS3Exception ex) when (ex.StatusCode == HttpStatusCode.Forbidden)
                {
                    // Keys that may only use a bucket created for them are fine. Anything else, such
                    // as wrong keys or an identity the store hasn't loaded yet, is retried.
                    if (!await BucketExistsAsync(cancellationToken).ConfigureAwait(false))
                    {
                        throw;
                    }
                    _logger.LogWarning("Not permitted to create bucket {Bucket}, which exists", _options.ContainerName);
                }
                return;
            }
            catch (Exception ex) when (attempt < maxAttempts && !cancellationToken.IsCancellationRequested)
            {
                var delay = TimeSpan.FromSeconds(Math.Min(10, attempt * 2));
                _logger.LogWarning(
                    "Object storage not ready (attempt {Attempt}/{MaxAttempts}): {Reason}. Retrying in {Delay}",
                    attempt, maxAttempts, Describe(ex), delay);
                _logger.LogDebug(ex, "Object storage initialization attempt {Attempt} failed", attempt);

                await Task.Delay(delay, cancellationToken).ConfigureAwait(false);
            }
        }
    }

    public async Task<string> ArchiveAsync(Order order, CancellationToken cancellationToken)
    {
        // Same date-partitioned layout as on blob storage.
        var key = $"{order.PlacedAt:yyyy/MM/dd}/{order.OrderId}.json";

        try
        {
            await PutAsync(key, order, cancellationToken).ConfigureAwait(false);
        }
        catch (AmazonS3Exception ex) when (ex.ErrorCode == "NoSuchBucket" || ex.StatusCode == HttpStatusCode.Forbidden)
        {
            // The bucket can be deleted after startup. Without this every later order would fail
            // until the worker restarts. SeaweedFS answers a write to a missing bucket with 403, as
            // it would need global Admin to create it, so a 403 is checked against the bucket.
            if (ex.ErrorCode != "NoSuchBucket" && await BucketExistsAsync(cancellationToken).ConfigureAwait(false))
            {
                throw;
            }
            _logger.LogWarning("Bucket {Bucket} is missing; creating it again", _options.ContainerName);
            await CreateBucketAsync(cancellationToken).ConfigureAwait(false);
            await PutAsync(key, order, cancellationToken).ConfigureAwait(false);
        }

        return $"{_endpoint}/{_options.ContainerName}/{key}";
    }

    private async Task<bool> BucketExistsAsync(CancellationToken cancellationToken)
    {
        try
        {
            await _client.HeadBucketAsync(new HeadBucketRequest { BucketName = _options.ContainerName }, cancellationToken)
                .ConfigureAwait(false);
            return true;
        }
        catch (AmazonS3Exception ex) when (ex.StatusCode == HttpStatusCode.NotFound)
        {
            return false;
        }
    }

    private async Task CreateBucketAsync(CancellationToken cancellationToken)
    {
        try
        {
            await _client.PutBucketAsync(new PutBucketRequest { BucketName = _options.ContainerName }, cancellationToken)
                .ConfigureAwait(false);
            _logger.LogInformation("Bucket {Bucket} is ready", _options.ContainerName);
        }
        catch (AmazonS3Exception ex) when (ex.ErrorCode is "BucketAlreadyOwnedByYou" or "BucketAlreadyExists")
        {
            // Already exists, possibly created concurrently by another replica.
            _logger.LogInformation("Bucket {Bucket} already exists", _options.ContainerName);
        }
    }

    private Task PutAsync(string key, Order order, CancellationToken cancellationToken)
    {
        // Overwrite: a redelivered message must not fail on the object it already wrote.
        var request = new PutObjectRequest
        {
            BucketName = _options.ContainerName,
            Key = key,
            ContentBody = order.ToJson(),
            ContentType = "application/json",
            UseChunkEncoding = false
        };
        request.Metadata.Add("messageType", Order.OrderPlacedType);
        request.Metadata.Add("lineCount", order.Lines.Count.ToString(System.Globalization.CultureInfo.InvariantCulture));

        return _client.PutObjectAsync(request, cancellationToken);
    }

    // The SDK's inner exception says nothing; the status and S3 error code do.
    private static string Describe(Exception ex) => ex is AmazonS3Exception s3
        ? $"{(int)s3.StatusCode} {s3.ErrorCode ?? s3.StatusCode.ToString()}: {s3.Message}"
        : ExceptionSummary.Describe(ex);

    public void Dispose() => _client.Dispose();
}
