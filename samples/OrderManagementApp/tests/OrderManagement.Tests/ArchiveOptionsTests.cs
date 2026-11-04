using Microsoft.Extensions.Options;
using OrderManagement.Shared.Configuration;

namespace OrderManagement.Tests;

/// <summary>How the archive connection's values pick the object storage client.</summary>
public sealed class ArchiveOptionsTests
{
    [Fact]
    public void Uses_blob_storage_with_the_workload_identity()
    {
        var options = Read(new()
        {
            ["CONNECTION_ARCHIVE_ENDPOINT"] = "https://account.blob.core.windows.net",
            ["CONNECTION_ARCHIVE_CONTAINERNAME"] = "orders",
            ["AZURE_CLIENT_ID"] = "00000000-0000-0000-0000-000000000001",
            ["AZURE_FEDERATED_TOKEN_FILE"] = "/var/run/secrets/azure/tokens/azure-identity-token"
        });

        Assert.Equal(ArchiveProvider.AzureBlob, options.Provider);
        Assert.Equal("orders", options.ContainerName);
    }

    [Fact]
    public void Uses_s3_when_the_platform_issued_keys()
    {
        var options = Read(new()
        {
            ["CONNECTION_ARCHIVE_ENDPOINT"] = "https://seaweedfs-s3.object-store.svc.cluster.local:8443",
            ["CONNECTION_ARCHIVE_CONTAINERNAME"] = "oms-azurelocal.orders",
            ["CONNECTION_ARCHIVE_ACCESSKEYID"] = "key",
            ["CONNECTION_ARCHIVE_SECRETACCESSKEY"] = "secret",
            ["Archive:MaxRetries"] = "5"
        });

        Assert.Equal(ArchiveProvider.S3, options.Provider);
        Assert.Equal("oms-azurelocal.orders", options.ContainerName);
        Assert.Equal(5, options.MaxRetries);
    }

    [Fact]
    public void Refuses_a_connection_without_an_endpoint() =>
        Assert.Throws<OptionsValidationException>(() => Read(new()
        {
            ["CONNECTION_ARCHIVE_CONTAINERNAME"] = "orders",
            ["CONNECTION_ARCHIVE_ACCESSKEYID"] = "key",
            ["CONNECTION_ARCHIVE_SECRETACCESSKEY"] = "secret"
        }));

    [Fact]
    public void Refuses_an_s3_key_without_its_secret() =>
        Assert.Throws<OptionsValidationException>(() => Read(new()
        {
            ["CONNECTION_ARCHIVE_ENDPOINT"] = "http://store:8333",
            ["CONNECTION_ARCHIVE_CONTAINERNAME"] = "orders",
            ["CONNECTION_ARCHIVE_ACCESSKEYID"] = "key"
        }));

    [Fact]
    public void Refuses_blob_storage_without_a_workload_identity() =>
        Assert.Throws<OptionsValidationException>(() => Read(new()
        {
            ["CONNECTION_ARCHIVE_ENDPOINT"] = "https://account.blob.core.windows.net",
            ["CONNECTION_ARCHIVE_CONTAINERNAME"] = "orders"
        }));

    private static ArchiveOptions Read(Dictionary<string, string?> values) =>
        OptionsReader.Read<ArchiveOptions>(values, services => ArchiveOptions.Add(services));
}
