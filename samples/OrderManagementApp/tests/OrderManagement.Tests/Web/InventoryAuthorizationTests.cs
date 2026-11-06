using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.IdentityModel.JsonWebTokens;
using Microsoft.IdentityModel.Protocols.OpenIdConnect;
using Microsoft.IdentityModel.Tokens;
using OrderManagement.Inventory;
using OrderManagement.Inventory.Data;
using OrderManagement.Shared.Models;

namespace OrderManagement.Tests.Web;

/// <summary>
/// The inventory service's authorization: it validates the callers' service tokens and each endpoint
/// needs the role its policy names. Only in Development may it run without a token issuer.
/// </summary>
public sealed class InventoryAuthorizationTests
{
    private const string Authority = "https://issuer.test/realms/oms";
    private const string Audience = "oms-inventory";
    private static readonly SymmetricSecurityKey SigningKey = new(Guid.NewGuid().ToByteArray().Concat(Guid.NewGuid().ToByteArray()).ToArray());

    [Fact]
    public void Refuses_to_start_without_a_token_issuer_outside_development()
    {
        using var factory = new InventoryFactory("Production", authority: null);

        var failure = Assert.Throws<InvalidOperationException>(() => factory.CreateClient());
        Assert.Contains("InventoryAuth__Authority", failure.Message);
    }

    [Fact]
    public async Task Accepts_calls_without_a_token_in_development_without_an_issuer()
    {
        using var factory = new InventoryFactory("Development", authority: null);

        Assert.Equal(HttpStatusCode.OK, (await factory.CreateClient().GetAsync("/api/products")).StatusCode);
    }

    [Theory]
    [InlineData("GET", "/api/products", InventoryRoles.Read, HttpStatusCode.OK)]
    [InlineData("GET", "/api/products", InventoryRoles.Reserve, HttpStatusCode.Forbidden)]
    [InlineData("POST", "/api/reservations", InventoryRoles.Reserve, HttpStatusCode.OK)]
    [InlineData("POST", "/api/reservations", InventoryRoles.Read, HttpStatusCode.Forbidden)]
    [InlineData("DELETE", "/api/reservations/7f1d1b55-8f0a-4c1e-9d55-6a4b2f2f2a01", InventoryRoles.Reserve, HttpStatusCode.NoContent)]
    [InlineData("DELETE", "/api/reservations/7f1d1b55-8f0a-4c1e-9d55-6a4b2f2f2a01", InventoryRoles.Restock, HttpStatusCode.Forbidden)]
    [InlineData("POST", "/api/products/GEN-500/restock", InventoryRoles.Restock, HttpStatusCode.OK)]
    [InlineData("POST", "/api/products/GEN-500/restock", InventoryRoles.Reserve, HttpStatusCode.Forbidden)]
    public async Task Allows_each_endpoint_to_its_role_only(string method, string path, string role, HttpStatusCode expected)
    {
        using var factory = new InventoryFactory("Production", Authority);

        Assert.Equal(expected, (await SendAsync(factory, method, path, Token(Audience, role))).StatusCode);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("someone-else")]
    public async Task Refuses_calls_without_a_valid_token_for_the_inventory_service(string? audience)
    {
        using var factory = new InventoryFactory("Production", Authority);

        var response = await SendAsync(factory, "GET", "/api/products", audience is null ? null : Token(audience, InventoryRoles.Read));

        Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
    }

    [Fact]
    public async Task Answers_the_liveness_probe_without_a_token()
    {
        using var factory = new InventoryFactory("Production", Authority);

        Assert.Equal(HttpStatusCode.OK, (await factory.CreateClient().GetAsync("/healthz")).StatusCode);
    }

    private static string Token(string audience, string role) => new JsonWebTokenHandler().CreateToken(new SecurityTokenDescriptor
    {
        Issuer = Authority,
        Audience = audience,
        Claims = new Dictionary<string, object> { ["sub"] = "service-account-processor", ["roles"] = new[] { role } },
        Expires = DateTime.UtcNow.AddMinutes(5),
        SigningCredentials = new SigningCredentials(SigningKey, SecurityAlgorithms.HmacSha256)
    });

    private static async Task<HttpResponseMessage> SendAsync(InventoryFactory factory, string method, string path, string? token)
    {
        using var request = new HttpRequestMessage(new HttpMethod(method), path);
        if (token is not null)
        {
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        }

        if (method == "POST")
        {
            request.Content = path.EndsWith("/restock", StringComparison.Ordinal)
                ? JsonContent.Create(new RestockRequest { Quantity = 5 })
                : JsonContent.Create(new ReservationRequest
                {
                    OrderId = Guid.NewGuid(),
                    Lines = [new ReservationLine { Sku = "GEN-500", Quantity = 1 }]
                });
        }

        return await factory.CreateClient().SendAsync(request);
    }

    private sealed class InventoryFactory(string environment, string? authority) : WebApplicationFactory<PostgresHealthCheck>
    {
        protected override void ConfigureWebHost(IWebHostBuilder builder)
        {
            builder.UseEnvironment(environment);
            builder.UseSetting("CONNECTION_INVENTORYDB_HOST", "postgres");
            builder.UseSetting("CONNECTION_INVENTORYDB_DATABASE", "inventory");
            builder.UseSetting("POSTGRES_USERNAME", "inventory");
            builder.UseSetting("POSTGRES_PASSWORD", "unused");
            builder.UseSetting("Telemetry:Exporter", "None");
            if (authority is not null)
            {
                builder.UseSetting("InventoryAuth:Authority", authority);
                builder.UseSetting("InventoryAuth:Audience", Audience);
            }

            builder.ConfigureTestServices(services =>
            {
                // The issuer's signing key, as if read from its metadata.
                services.Configure<JwtBearerOptions>(JwtBearerDefaults.AuthenticationScheme, options =>
                {
                    options.Configuration = new OpenIdConnectConfiguration { Issuer = Authority };
                    options.Configuration.SigningKeys.Add(SigningKey);
                });
                services.RemoveAll<IProductRepository>().AddSingleton<IProductRepository, FakeStock>();
                services.RemoveAll<IStockRepository>().AddSingleton<IStockRepository, FakeStock>();
            });
        }
    }

    private sealed class FakeStock : IProductRepository, IStockRepository
    {
        private static readonly Product Generator = new()
        {
            Sku = "GEN-500", Name = "Generator", UnitPrice = 100m, Currency = "USD", Available = 10, ReorderLevel = 1
        };

        public Task<IReadOnlyList<Product>> ListAsync(CancellationToken cancellationToken) =>
            Task.FromResult<IReadOnlyList<Product>>([Generator]);

        public Task<ReservationOutcome> ReserveAsync(Guid orderId, IReadOnlyList<ReservationLine> lines, CancellationToken cancellationToken) =>
            Task.FromResult(ReservationOutcome.Of(new ReservationResult { OrderId = orderId, Status = ReservationStatus.Reserved }));

        public Task<bool> ReleaseAsync(Guid orderId, CancellationToken cancellationToken) => Task.FromResult(true);

        public Task<Product?> RestockAsync(string sku, int quantity, CancellationToken cancellationToken) =>
            Task.FromResult<Product?>(Generator with { Available = Generator.Available + quantity });
    }
}
