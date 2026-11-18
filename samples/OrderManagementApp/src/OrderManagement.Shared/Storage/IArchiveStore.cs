using OrderManagement.Shared.Models;

namespace OrderManagement.Shared.Storage;

/// <summary>
/// Writes each consumed order to object storage as a JSON document. Writes only: the container or
/// bucket is the platform's.
/// </summary>
public interface IArchiveStore
{
    /// <returns>The absolute URI of the object that was written.</returns>
    Task<string> ArchiveAsync(Order order, CancellationToken cancellationToken);
}

/// <summary>
/// Metadata names on each archived object, the same on Blob Storage and S3, for its signature
/// (<see cref="ArchiveSigner"/>). S3 returns them lowercased, as <c>x-amz-meta-*</c> headers.
/// </summary>
public static class ArchiveMetadata
{
    public const string SignatureAlgorithm = "signaturealgorithm";
    public const string SigningKeyId = "signingkeyid";
    public const string Signature = "signature";
}
