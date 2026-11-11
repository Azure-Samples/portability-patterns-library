using System.Net;
using System.Net.Http.Json;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Diagnostics.HealthChecks;
using OrderManagement.Api;
using OrderManagement.Shared.Inventory;
using OrderManagement.Shared.Messaging;
using OrderManagement.Shared.Models;
using OrderManagement.Shared.Persistence;

namespace OrderManagement.Tests.Web;

/// <summary>
/// The API's authorization: every call needs the API scope, and each endpoint the role its policy
/// names. Failures the caller can act on come back as problem details.
/// </summary>
public sealed class ApiAuthorizationTests : IClassFixture<ApiAuthorizationTests.ApiFactory>
{
    private const string Reader = "Orders.Read";
    private const string Writer = "Orders.Create";
    private const string Manager = "Inventory.Manage";

    private readonly ApiFactory _factory;

    public ApiAuthorizationTests(ApiFactory factory)
    {
        _factory = factory;
        _factory.Inventory.Failure = null;
    }

    [Theory]
    [InlineData("GET", "/api/me")]
    [InlineData("GET", "/api/products")]
    [InlineData("GET", "/api/orders")]
    [InlineData("POST", "/api/orders")]
    [InlineData("POST", "/api/inventory/GEN-500/restock")]
    public async Task Refuses_calls_without_a_token(string method, string path) =>
        Assert.Equal(HttpStatusCode.Unauthorized, (await SendAsync(method, path, user: null)).StatusCode);

    [Fact]
    public async Task Refuses_a_token_without_the_api_scope() =>
        Assert.Equal(HttpStatusCode.Forbidden,
            (await SendAsync("GET", "/api/products", TestAuthenticationHandler.Header(roles: Writer, scp: "openid"))).StatusCode);

    [Theory]
    [InlineData("GET", "/api/orders", Reader, HttpStatusCode.OK)]
    [InlineData("GET", "/api/orders", Writer, HttpStatusCode.OK)]
    [InlineData("GET", "/api/orders", Manager, HttpStatusCode.Forbidden)]
    [InlineData("POST", "/api/orders", Reader, HttpStatusCode.Forbidden)]
    [InlineData("POST", "/api/orders", Writer, HttpStatusCode.Accepted)]
    [InlineData("POST", "/api/inventory/GEN-500/restock", Writer, HttpStatusCode.Forbidden)]
    [InlineData("POST", "/api/inventory/GEN-500/restock", Manager, HttpStatusCode.OK)]
    [InlineData("GET", "/api/products", Reader, HttpStatusCode.OK)]
    public async Task Allows_each_endpoint_to_its_roles_only(string method, string path, string role, HttpStatusCode expected) =>
        Assert.Equal(expected, (await SendAsync(method, path, TestAuthenticationHandler.Header(roles: role))).StatusCode);

    [Fact]
    public async Task Queues_the_order_for_the_signed_in_user()
    {
        var response = await SendAsync("POST", "/api/orders", TestAuthenticationHandler.Header(sub: "user-42", roles: Writer));

        Assert.Equal(HttpStatusCode.Accepted, response.StatusCode);
        Assert.Contains(_factory.Publisher.Published, order => order.CustomerId == "user-42" && order.Total == 200m);
    }

    [Fact]
    public async Task Answers_503_when_the_inventory_service_is_down()
    {
        _factory.Inventory.Failure = new InventoryUnavailableException("down");

        var response = await SendAsync("GET", "/api/products", TestAuthenticationHandler.Header(roles: Reader));

        Assert.Equal(HttpStatusCode.ServiceUnavailable, response.StatusCode);
        Assert.Equal("application/problem+json", response.Content.Headers.ContentType?.MediaType);
    }

    [Fact]
    public async Task Answers_502_when_the_inventory_service_refuses()
    {
        _factory.Inventory.Failure = new InventoryRequestException(HttpStatusCode.Forbidden, "refused");

        var response = await SendAsync("POST", "/api/inventory/GEN-500/restock", TestAuthenticationHandler.Header(roles: Manager));

        Assert.Equal(HttpStatusCode.BadGateway, response.StatusCode);
        Assert.Equal("application/problem+json", response.Content.Headers.ContentType?.MediaType);
    }

    [Fact]
    public async Task Refuses_a_token_without_a_user_identifier() =>
        Assert.Equal(HttpStatusCode.Forbidden,
            (await SendAsync("GET", "/api/orders", TestAuthenticationHandler.Header(sub: null, roles: Reader))).StatusCode);

    [Fact]
    public async Task Answers_the_liveness_probe_without_a_token() =>
        Assert.Equal(HttpStatusCode.OK, (await SendAsync("GET", "/healthz", user: null)).StatusCode);

    private async Task<HttpResponseMessage> SendAsync(string method, string path, string? user)
    {
        using var request = new HttpRequestMessage(new HttpMethod(method), path);
        if (user is not null)
        {
            request.Headers.TryAddWithoutValidation("Authorization", user);
        }

        if (method == "POST")
        {
            request.Content = path.EndsWith("/restock", StringComparison.Ordinal)
                ? JsonContent.Create(new RestockRequest { Quantity = 5 })
                : JsonContent.Create(new OrderRequest { Items = [new OrderRequestItem { Sku = "GEN-500", Quantity = 2 }] });
        }

        return await _factory.CreateClient().SendAsync(request);
    }

    public sealed class ApiFactory : WebApplicationFactory<ApiExceptionHandler>
    {
        public FakeInventory Inventory { get; } = new();
        public FakePublisher Publisher { get; } = new();

        protected override void ConfigureWebHost(IWebHostBuilder builder)
        {
            builder.UseEnvironment("Production");
            foreach (var (key, value) in new Dictionary<string, string>
            {
                ["AzureAd:Instance"] = "https://login.microsoftonline.com/",
                ["AzureAd:TenantId"] = "00000000-0000-0000-0000-000000000001",
                ["AzureAd:ClientId"] = "00000000-0000-0000-0000-000000000002",
                ["CONNECTION_QUEUE_PROVIDER"] = "rabbitmq",
                ["CONNECTION_QUEUE_ENDPOINT"] = "rabbitmq:5672",
                ["CONNECTION_QUEUE_QUEUENAME"] = "orders",
                ["CONNECTION_QUEUE_MAXDELIVERYCOUNT"] = "10",
                ["CONNECTION_QUEUE_USERNAME"] = "oms",
                ["CONNECTION_QUEUE_PASSWORD"] = "unused",
                ["CONNECTION_SQL_HOST"] = "sql",
                ["CONNECTION_SQL_DATABASE"] = "omsdb",
                ["SQL_USERNAME"] = "api",
                ["SQL_PASSWORD"] = "unused",
                ["Inventory:BaseUrl"] = "http://inventory:8080",
                ["Telemetry:Exporter"] = "None"
            })
            {
                builder.UseSetting(key, value);
            }

            builder.ConfigureTestServices(services =>
            {
                services.AddAuthentication().AddScheme<AuthenticationSchemeOptions, TestAuthenticationHandler>(TestAuthenticationHandler.SchemeName, null);
                services.Configure<AuthenticationOptions>(options =>
                {
                    options.DefaultScheme = TestAuthenticationHandler.SchemeName;
                    options.DefaultAuthenticateScheme = TestAuthenticationHandler.SchemeName;
                    options.DefaultChallengeScheme = TestAuthenticationHandler.SchemeName;
                });
                services.RemoveAll<IInventoryClient>().AddSingleton<IInventoryClient>(Inventory);
                services.RemoveAll<IMessageQueue>().AddSingleton<IMessageQueue>(Publisher);
                services.RemoveAll<IOrderStore>().AddSingleton<IOrderStore, EmptyOrderStore>();
            });
        }
    }

    public sealed class FakeInventory : IInventoryClient
    {
        public Exception? Failure { get; set; }

        private static readonly Product Generator = new()
        {
            Sku = "GEN-500", Name = "Generator", UnitPrice = 100m, Currency = "USD", Available = 10, ReorderLevel = 1
        };

        public Task<IReadOnlyList<Product>> GetProductsAsync(CancellationToken cancellationToken) =>
            Failure is null ? Task.FromResult<IReadOnlyList<Product>>([Generator]) : Task.FromException<IReadOnlyList<Product>>(Failure);

        public Task<Product?> RestockAsync(string sku, int quantity, CancellationToken cancellationToken) =>
            Failure is null
                ? Task.FromResult<Product?>(Generator with { Available = Generator.Available + quantity })
                : Task.FromException<Product?>(Failure);

        public Task<ReservationResult> ReserveAsync(ReservationRequest request, CancellationToken cancellationToken) =>
            throw new NotSupportedException();

        public Task ReleaseAsync(Guid orderId, CancellationToken cancellationToken) => throw new NotSupportedException();
    }

    public sealed class FakePublisher : IMessageQueue
    {
        public List<Order> Published { get; } = [];

        public Task PublishAsync(Order order, CancellationToken cancellationToken)
        {
            lock (Published)
            {
                Published.Add(order);
            }
            return Task.CompletedTask;
        }

        public Task RunAsync(Func<QueueMessage, CancellationToken, Task> handler, CancellationToken cancellationToken) =>
            throw new NotSupportedException();

        public Task<HealthCheckResult> CheckHealthAsync(HealthCheckContext context, CancellationToken cancellationToken = default) =>
            Task.FromResult(HealthCheckResult.Healthy());

        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }

    public sealed class EmptyOrderStore : IOrderStore
    {
        public Task RecordAsync(Order order, string archiveUri, string status, string? statusReason, CancellationToken cancellationToken) =>
            throw new NotSupportedException();

        public Task<IReadOnlyList<StoredOrder>> ListForCustomerAsync(string customerId, int top, CancellationToken cancellationToken) =>
            Task.FromResult<IReadOnlyList<StoredOrder>>([]);

        public Task<StoredOrder?> GetForCustomerAsync(Guid orderId, string customerId, CancellationToken cancellationToken) =>
            Task.FromResult<StoredOrder?>(null);
    }
}
