using Microsoft.Extensions.Configuration;
using OrderManagement.Shared.Configuration;

namespace OrderManagement.Tests;

/// <summary>How the archive connection's values pick the object storage client.</summary>
public sealed class ArchiveOptionsTests
{
    [Fact]
    public void Uses_blob_storage_with_an_endpoint_only()
    {
        var options = Read(new() { ["ENDPOINT"] = "https://account.blob.core.windows.net", ["CONTAINERNAME"] = "orders" });

        Assert.Equal(ArchiveProvider.AzureBlob, options.Provider);
        Assert.Equal("orders", options.ContainerName);
    }

    [Fact]
    public void Uses_s3_when_the_platform_issued_keys()
    {
        var options = Read(new()
        {
            ["ENDPOINT"] = "https://seaweedfs-s3.object-store.svc.cluster.local:8443",
            ["CONTAINERNAME"] = "oms-azurelocal.orders",
            ["ACCESSKEYID"] = "key",
            ["SECRETACCESSKEY"] = "secret"
        });

        Assert.Equal(ArchiveProvider.S3, options.Provider);
        Assert.Equal("oms-azurelocal.orders", options.ContainerName);
    }

    [Fact]
    public void Refuses_a_connection_without_an_endpoint() =>
        Assert.Throws<InvalidOperationException>(() => Read(new() { ["CONTAINERNAME"] = "orders" }));

    [Fact]
    public void Refuses_an_s3_key_without_its_secret() =>
        Assert.Throws<InvalidOperationException>(() => Read(new() { ["ENDPOINT"] = "http://store:8333", ["ACCESSKEYID"] = "key" }));

    // As Radius injects them: CONNECTION_ARCHIVE_<PROPERTY>.
    private static ArchiveOptions Read(Dictionary<string, string?> values) =>
        ArchiveOptions.FromConfiguration(new ConfigurationBuilder()
            .AddInMemoryCollection(values.ToDictionary(entry => $"CONNECTION_ARCHIVE_{entry.Key}", entry => entry.Value))
            .Build());
}
