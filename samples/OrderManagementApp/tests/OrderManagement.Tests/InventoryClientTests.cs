using System.Net;
using System.Text;
using Duende.AccessTokenManagement;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using OrderManagement.Shared.DependencyInjection;
using OrderManagement.Shared.Inventory;

namespace OrderManagement.Tests;

/// <summary>
/// How the processor and the API call the inventory service on Azure Local: with a Keycloak token
/// obtained with the pod's ServiceAccount token as the client assertion, cached and reused, and with
/// Keycloak being down treated like the inventory service being down.
/// </summary>
public sealed class InventoryClientTests : IDisposable
{
    private const string TokenEndpoint = "https://keycloak.test/realms/oms/protocol/openid-connect/token";
    private readonly string _assertionFile = Path.Combine(AppContext.BaseDirectory, $"sa-token-{Guid.NewGuid():N}");

    public InventoryClientTests() => File.WriteAllText(_assertionFile, "service-account-jwt\n");

    [Fact]
    public async Task Calls_with_a_keycloak_token_obtained_with_the_service_account_token_and_reuses_it()
    {
        var keycloak = new RecordingHandler(_ => Json(HttpStatusCode.OK, """{"access_token":"keycloak-token","token_type":"Bearer","expires_in":900}"""));
        var inventory = new RecordingHandler(_ => Json(HttpStatusCode.OK, "[]"));
        using var provider = Build(keycloak, inventory);
        var client = provider.GetRequiredService<IInventoryClient>();

        await client.GetProductsAsync(CancellationToken.None);
        await client.GetProductsAsync(CancellationToken.None);

        var tokenRequest = Assert.Single(keycloak.Bodies);
        Assert.Contains("client_id=workload-processor", tokenRequest);
        Assert.Contains("client_assertion_type=urn%3Aietf%3Aparams%3Aoauth%3Aclient-assertion-type%3Ajwt-bearer", tokenRequest);
        Assert.Contains("client_assertion=service-account-jwt", tokenRequest);
        Assert.All(inventory.Authorizations, authorization => Assert.Equal("Bearer keycloak-token", authorization));
        Assert.Equal(2, inventory.Authorizations.Count);
    }

    [Fact]
    public async Task Treats_keycloak_being_down_as_the_inventory_service_being_unavailable()
    {
        var keycloak = new RecordingHandler(_ => Json(HttpStatusCode.ServiceUnavailable, "{}"));
        var inventory = new RecordingHandler(_ => Json(HttpStatusCode.OK, "[]"));
        using var provider = Build(keycloak, inventory);

        await Assert.ThrowsAsync<InventoryUnavailableException>(() =>
            provider.GetRequiredService<IInventoryClient>().GetProductsAsync(CancellationToken.None));
        Assert.Empty(inventory.Authorizations);
    }

    [Fact]
    public async Task Gives_up_on_an_answer_whose_body_stalls()
    {
        var keycloak = new RecordingHandler(_ => Json(HttpStatusCode.OK, """{"access_token":"keycloak-token","token_type":"Bearer","expires_in":900}"""));
        var inventory = new RecordingHandler(_ => new HttpResponseMessage(HttpStatusCode.OK) { Content = new StreamContent(new StallingStream()) });
        using var provider = Build(keycloak, inventory, new()
        {
            ["Inventory:Resilience:AttemptTimeout:Timeout"] = "00:00:00.500",
            ["Inventory:Resilience:TotalRequestTimeout:Timeout"] = "00:00:01"
        });

        var call = provider.GetRequiredService<IInventoryClient>().GetProductsAsync(CancellationToken.None);

        var finished = await Task.WhenAny(call, Task.Delay(TimeSpan.FromSeconds(30)));
        Assert.Same(call, finished);
        await Assert.ThrowsAsync<InventoryUnavailableException>(() => call);
    }

    public void Dispose() => File.Delete(_assertionFile);

    private ServiceProvider Build(RecordingHandler keycloak, RecordingHandler inventory, Dictionary<string, string?>? settings = null)
    {
        var values = new Dictionary<string, string?>
        {
            ["IDENTITY_CLIENT_ID"] = "workload-processor",
            ["IDENTITY_TOKEN_ENDPOINT"] = TokenEndpoint,
            ["IDENTITY_TOKEN_FILE"] = _assertionFile,
            ["Inventory:BaseUrl"] = "http://inventory.test",
            ["Inventory:Resilience:Retry:Delay"] = "00:00:00.010"
        };
        foreach (var (key, value) in settings ?? [])
        {
            values[key] = value;
        }

        var configuration = new ConfigurationBuilder().AddInMemoryCollection(values).Build();

        var services = new ServiceCollection().AddLogging().AddSingleton<IConfiguration>(configuration);
        services.AddInventoryClient(configuration);
        services.AddHttpClient(ClientCredentialsTokenManagementDefaults.BackChannelHttpClientName)
            .ConfigurePrimaryHttpMessageHandler(() => keycloak);
        services.AddHttpClient<IInventoryClient, HttpInventoryClient>().ConfigurePrimaryHttpMessageHandler(() => inventory);
        return services.BuildServiceProvider();
    }

    private static HttpResponseMessage Json(HttpStatusCode status, string body) =>
        new(status) { Content = new StringContent(body, Encoding.UTF8, "application/json") };

    // A body that never arrives: every read waits until it is cancelled.
    private sealed class StallingStream : Stream
    {
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }

        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
        {
            await Task.Delay(Timeout.Infinite, cancellationToken);
            return 0;
        }

        public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken) =>
            ReadAsync(buffer.AsMemory(offset, count), cancellationToken).AsTask();

        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override void Flush() { }
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }

    private sealed class RecordingHandler(Func<HttpRequestMessage, HttpResponseMessage> respond) : HttpMessageHandler
    {
        public List<string> Bodies { get; } = [];
        public List<string?> Authorizations { get; } = [];

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            lock (Bodies)
            {
                Authorizations.Add(request.Headers.Authorization?.ToString());
            }

            if (request.Content is not null)
            {
                var body = await request.Content.ReadAsStringAsync(cancellationToken);
                lock (Bodies)
                {
                    Bodies.Add(body);
                }
            }

            return respond(request);
        }
    }
}
