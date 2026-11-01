using System.Security.Claims;
using OrderManagement.Api;
using OrderManagement.Shared.DependencyInjection;
using OrderManagement.Shared.Diagnostics;
using OpenTelemetry.Metrics;
using OpenTelemetry.Trace;
using OrderManagement.Shared.Inventory;
using OrderManagement.Shared.Messaging;
using OrderManagement.Shared.Models;
using OrderManagement.Shared.Persistence;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.Identity.Web;
using Microsoft.Identity.Web.Resource;

var builder = WebApplication.CreateBuilder(args);

builder.AddOrderManagementTelemetry(
    tracing => tracing.AddAspNetCoreInstrumentation(options =>
        options.Filter = context => !context.Request.Path.StartsWithSegments("/healthz")),
    metrics => metrics.AddAspNetCoreInstrumentation());

builder.Services.AddOrderQueue();
builder.Services.AddOrderStore();
builder.Services.AddInventoryClient();
builder.Services.AddSingleton(services => new ProductCatalog(
    services.GetRequiredService<IInventoryClient>(),
    TimeProvider.System,
    builder.Configuration.GetValue("Inventory:PriceCacheMaxAge", TimeSpan.FromHours(1)),
    services.GetRequiredService<ILogger<ProductCatalog>>()));

// Written exactly as for an Entra-only API. Which identity provider issues the tokens (Entra ID in
// Azure, Keycloak on Azure Local) is decided purely by the "AzureAd" configuration section.
var signInConfigured = !string.IsNullOrWhiteSpace(builder.Configuration["AzureAd:ClientId"]);
var authentication = builder.Services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme);
if (signInConfigured)
{
    authentication.AddMicrosoftIdentityWebApi(builder.Configuration.GetSection("AzureAd"));
}

builder.Services.AddAuthorizationBuilder()
    .AddPolicy(OrderPolicies.Read, policy => policy.RequireRole(OrderRoles.Read, OrderRoles.Create))
    .AddPolicy(OrderPolicies.Create, policy => policy.RequireRole(OrderRoles.Create))
    .AddPolicy(OrderPolicies.ManageInventory, policy => policy.RequireRole(OrderRoles.ManageInventory));

var app = builder.Build();

var spa = SpaSettings.FromConfiguration(app.Configuration);
app.Use(async (context, next) =>
{
    var headers = context.Response.Headers;
    headers.XContentTypeOptions = "nosniff";
    headers.XFrameOptions = "DENY";
    headers["Referrer-Policy"] = "no-referrer";
    headers.ContentSecurityPolicy = spa.ContentSecurityPolicy;
    await next(context);
});

// Without an identity provider the API refuses every call, but the app still serves and stays healthy.
if (!signInConfigured)
{
    app.Logger.LogWarning("No AzureAd configuration; the orders API is disabled until sign-in is configured");
    app.Use(async (context, next) =>
    {
        if (context.Request.Path.StartsWithSegments("/api"))
        {
            await Results.Problem("Sign-in is not configured for this deployment.",
                statusCode: StatusCodes.Status503ServiceUnavailable).ExecuteAsync(context);
            return;
        }
        await next(context);
    });
}

// The inventory service is a dependency like the queue: when it is down, say so rather than fail.
app.Use(async (context, next) =>
{
    try
    {
        await next(context);
    }
    catch (InventoryUnavailableException ex) when (!context.Response.HasStarted)
    {
        app.Logger.LogWarning("Inventory service unavailable for {Path}: {Reason}", context.Request.Path, ex.Message);
        await Results.Problem("Product information is unavailable. Try again shortly.",
            statusCode: StatusCodes.Status503ServiceUnavailable).ExecuteAsync(context);
    }
});

app.UseDefaultFiles();
app.UseStaticFiles();
app.UseAuthentication();
app.UseAuthorization();

app.MapGet("/healthz", () => Results.Ok(new { status = "ok" }));

// Runtime configuration for the SPA, so one image serves every environment.
app.MapGet("/config.json", () => Results.Json(spa.ClientConfiguration));

var api = app.MapGroup("/api").RequireScope(OrderRoles.ApiScope);

api.MapGet("/me", (ClaimsPrincipal user) => Results.Ok(new
{
    name = UserIdentity.DisplayName(user),
    customerId = UserIdentity.CustomerId(user),
    issuer = user.FindFirstValue("iss"),
    roles = UserIdentity.Roles(user),
    canRead = user.IsInRole(OrderRoles.Read) || user.IsInRole(OrderRoles.Create),
    canCreate = user.IsInRole(OrderRoles.Create),
    canManageInventory = user.IsInRole(OrderRoles.ManageInventory)
}))
    .RequireAuthorization();

// While the inventory service is down, the last product list fetched, marked with when it was
// fetched so the page can say the stock may be out of date.
api.MapGet("/products", async (HttpContext context, ProductCatalog catalog, CancellationToken cancellationToken) =>
{
    var snapshot = await catalog.GetAsync(cancellationToken);
    if (snapshot.IsCached)
    {
        context.Response.Headers["X-Products-As-Of"] = snapshot.FetchedAt.ToString("O");
    }

    return Results.Ok(snapshot.Products);
})
    .RequireAuthorization();

// The user's role is checked here; the inventory service then trusts the API's own identity.
api.MapPost("/inventory/{sku}/restock", async (
    string sku,
    RestockRequest request,
    ClaimsPrincipal user,
    IInventoryClient inventory,
    ILogger<RestockRequest> logger,
    CancellationToken cancellationToken) =>
{
    if (!request.IsValid)
    {
        return Results.ValidationProblem(new Dictionary<string, string[]>
        {
            ["quantity"] = [$"Quantity must be between 1 and {RestockRequest.MaxQuantity}."]
        });
    }

    var product = await inventory.RestockAsync(sku, request.Quantity, cancellationToken);
    if (product is null)
    {
        return Results.NotFound();
    }

    logger.LogInformation("{User} restocked {Sku} by {Quantity}; {Available} available",
        UserIdentity.DisplayName(user), product.Sku, request.Quantity, product.Available);
    return Results.Ok(product);
})
    .RequireAuthorization(OrderPolicies.ManageInventory);

api.MapGet("/orders", async (ClaimsPrincipal user, IOrderStore orders, CancellationToken cancellationToken) =>
    Results.Ok(await orders.ListForCustomerAsync(UserIdentity.CustomerId(user), 50, cancellationToken)))
    .RequireAuthorization(OrderPolicies.Read);

api.MapGet("/orders/{orderId:guid}", async (Guid orderId, ClaimsPrincipal user, IOrderStore orders, CancellationToken cancellationToken) =>
    await orders.GetForCustomerAsync(orderId, UserIdentity.CustomerId(user), cancellationToken) is { } order
        ? Results.Ok(order)
        : Results.NotFound())
    .RequireAuthorization(OrderPolicies.Read);

api.MapPost("/orders", async (
    OrderRequest request,
    ClaimsPrincipal user,
    IMessagePublisher publisher,
    ProductCatalog catalog,
    OrderMetrics metrics,
    ILogger<OrderRequest> logger,
    CancellationToken cancellationToken) =>
{
    // Priced from the inventory service's current prices, or the last ones fetched while it is
    // down; stock is reserved later by the processor.
    var products = (await catalog.GetAsync(cancellationToken)).Products;
    var (lines, currency, errors) = OrderPricing.Price(request, products);
    if (errors is not null)
    {
        return Results.ValidationProblem(errors);
    }

    var order = new Order
    {
        OrderId = Guid.NewGuid(),
        CustomerId = UserIdentity.CustomerId(user),
        CustomerName = UserIdentity.DisplayName(user),
        Lines = lines!,
        Currency = currency,
        PlacedAt = DateTimeOffset.UtcNow
    };

    try
    {
        await publisher.PublishAsync(order, cancellationToken);
    }
    catch (Exception ex) when (ex is not OperationCanceledException)
    {
        logger.LogError(ex, "Could not queue order {OrderId}", order.OrderId);
        return Results.Problem("The order could not be queued. Try again shortly.", statusCode: StatusCodes.Status503ServiceUnavailable);
    }

    metrics.OrderPlaced();
    logger.LogInformation("Queued order {OrderId} for {Customer}: {LineCount} lines, {Total} {Currency}",
        order.OrderId, order.CustomerName, order.Lines.Count, order.Total, order.Currency);

    return Results.Accepted($"/api/orders/{order.OrderId}", new
    {
        orderId = order.OrderId,
        status = "Submitted",
        lines = order.Lines,
        total = order.Total,
        currency = order.Currency,
        placedAt = order.PlacedAt
    });
})
    .RequireAuthorization(OrderPolicies.Create);

app.Run();
