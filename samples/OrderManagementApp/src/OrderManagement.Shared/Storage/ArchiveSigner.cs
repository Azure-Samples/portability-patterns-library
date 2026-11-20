using System.Security.Cryptography;
using System.Text;
using Microsoft.Extensions.Options;
using OrderManagement.Shared.Configuration;

namespace OrderManagement.Shared.Storage;

/// <summary>An archived document's signature, stored with it as object metadata.</summary>
/// <param name="KeyId">Identifies the key that signed it, so a verifier picks the right one after a rotation.</param>
public sealed record ArchiveSignature(string Algorithm, string KeyId, string Value);

/// <summary>
/// Signs archived orders with HMAC-SHA256, so anyone holding the key can tell an archived order was
/// written by the processor and not changed since. The key file is read again every
/// <see cref="ArchiveSigningOptions.RefreshInterval"/>, so a key rotated in Key Vault is picked up
/// without a restart once the platform has delivered it.
/// </summary>
public sealed class ArchiveSigner(IOptions<ArchiveSigningOptions> options, TimeProvider time)
{
    public const string Algorithm = "HMAC-SHA256";
    public const int MinimumKeyLength = 32;

    private readonly Lock _gate = new();
    private SigningKey? _key;

    private sealed record SigningKey(byte[] Bytes, string Id, DateTimeOffset ReadAt);

    public ArchiveSignature Sign(string content)
    {
        var key = CurrentKey();
        var mac = HMACSHA256.HashData(key.Bytes, Encoding.UTF8.GetBytes(content));
        return new ArchiveSignature(Algorithm, key.Id, Convert.ToBase64String(mac));
    }

    /// <summary>Whether <paramref name="signature"/> is <paramref name="content"/>'s, under <paramref name="key"/>.</summary>
    public static bool Verify(string content, ArchiveSignature signature, byte[] key) =>
        signature.Algorithm == Algorithm &&
        signature.KeyId == KeyIdOf(key) &&
        CryptographicOperations.FixedTimeEquals(
            HMACSHA256.HashData(key, Encoding.UTF8.GetBytes(content)),
            Convert.FromBase64String(signature.Value));

    /// <summary>
    /// Reads the key: the file's text without surrounding whitespace, as UTF-8. Key Vault and
    /// Kubernetes Secrets hold text, and a trailing newline is easy to add by accident.
    /// </summary>
    public static bool TryReadKey(string path, out byte[] key)
    {
        key = [];
        try
        {
            key = Encoding.UTF8.GetBytes(File.ReadAllText(path).Trim());
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            return false;
        }
        return key.Length >= MinimumKeyLength;
    }

    /// <summary>The first 16 hex digits of the key's SHA-256: identifies the key without revealing it.</summary>
    public static string KeyIdOf(byte[] key) => Convert.ToHexStringLower(SHA256.HashData(key))[..16];

    private SigningKey CurrentKey()
    {
        lock (_gate)
        {
            var now = time.GetUtcNow();
            if (_key is { } current && now - current.ReadAt < options.Value.RefreshInterval)
            {
                return current;
            }

            if (!TryReadKey(options.Value.KeyPath, out var bytes))
            {
                // Keep signing with the key already read, rather than stop archiving, while the
                // platform replaces the file.
                return _key ?? throw new InvalidOperationException($"The archive signing key at {options.Value.KeyPath} is missing or too short.");
            }

            _key = new SigningKey(bytes, KeyIdOf(bytes), now);
            return _key;
        }
    }
}
