using System.Security.Cryptography;
using System.Text;
using Microsoft.Extensions.Options;
using OrderManagement.Shared.Configuration;
using OrderManagement.Shared.Storage;

namespace OrderManagement.Tests;

/// <summary>How the processor signs archived orders with the key the platform delivers from Key Vault.</summary>
public sealed class ArchiveSignerTests : IDisposable
{
    private const string Content = """{"orderId":"8f6b1c0e-4d55-4c84-9d6e-0e1f2a3b4c5d","total":200}""";
    private readonly string _keyPath = Path.Combine(Path.GetTempPath(), $"archive-signing-{Guid.NewGuid():N}");

    [Fact]
    public void Signs_with_hmac_sha256_under_the_delivered_key()
    {
        File.WriteAllText(_keyPath, "first-key-0123456789abcdefghijklmnop\n");
        var signer = Signer(new ManualTime());

        var signature = signer.Sign(Content);

        var key = Encoding.UTF8.GetBytes("first-key-0123456789abcdefghijklmnop");
        Assert.Equal(ArchiveSigner.Algorithm, signature.Algorithm);
        Assert.Equal(Convert.ToBase64String(HMACSHA256.HashData(key, Encoding.UTF8.GetBytes(Content))), signature.Value);
        Assert.True(ArchiveSigner.Verify(Content, signature, key));
        Assert.False(ArchiveSigner.Verify(Content.Replace("200", "201", StringComparison.Ordinal), signature, key));
    }

    [Fact]
    public void Uses_a_rotated_key_once_the_refresh_interval_passes()
    {
        File.WriteAllText(_keyPath, "first-key-0123456789abcdefghijklmnop");
        var time = new ManualTime();
        var signer = Signer(time);
        var before = signer.Sign(Content);

        File.WriteAllText(_keyPath, "second-key-0123456789abcdefghijklmno");
        Assert.Equal(before.KeyId, signer.Sign(Content).KeyId);

        time.Advance(TimeSpan.FromMinutes(1));
        var after = signer.Sign(Content);

        Assert.NotEqual(before.KeyId, after.KeyId);
        Assert.True(ArchiveSigner.Verify(Content, after, Encoding.UTF8.GetBytes("second-key-0123456789abcdefghijklmno")));
    }

    [Fact]
    public void Keeps_the_last_key_while_the_file_is_being_replaced()
    {
        File.WriteAllText(_keyPath, "first-key-0123456789abcdefghijklmnop");
        var time = new ManualTime();
        var signer = Signer(time);
        var before = signer.Sign(Content);

        File.Delete(_keyPath);
        time.Advance(TimeSpan.FromMinutes(5));

        Assert.Equal(before, signer.Sign(Content));
    }

    [Fact]
    public void Refuses_to_start_without_the_key() =>
        Assert.Throws<OptionsValidationException>(() => Read(_keyPath));

    [Fact]
    public void Refuses_to_start_with_a_short_key()
    {
        File.WriteAllText(_keyPath, "too-short");
        Assert.Throws<OptionsValidationException>(() => Read(_keyPath));
    }

    [Fact]
    public void Reads_the_key_from_the_path_the_platform_mounts_by_default() =>
        Assert.Equal("/var/run/secrets/archive-signing/key", new ArchiveSigningOptions().KeyPath);

    public void Dispose() => File.Delete(_keyPath);

    private ArchiveSigner Signer(TimeProvider time) =>
        new(Options.Create(new ArchiveSigningOptions { KeyPath = _keyPath }), time);

    private static ArchiveSigningOptions Read(string keyPath) =>
        OptionsReader.Read<ArchiveSigningOptions>(new() { ["ArchiveSigning:KeyPath"] = keyPath }, services => ArchiveSigningOptions.Add(services));

    private sealed class ManualTime : TimeProvider
    {
        private DateTimeOffset _now = new(2026, 11, 18, 12, 0, 0, TimeSpan.Zero);

        public override DateTimeOffset GetUtcNow() => _now;

        public void Advance(TimeSpan by) => _now += by;
    }
}
