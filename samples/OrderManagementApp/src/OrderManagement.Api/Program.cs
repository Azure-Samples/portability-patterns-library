using System.Security.Claims;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.Identity.Web;
using Microsoft.Identity.Web.Resource;
using OpenTelemetry.Metrics;
using OpenTelemetry.Trace;
using OrderManagement.Api;
using OrderManagement.Shared.DependencyInjection;
using OrderManagement.Shared.Diagnostics;
using OrderManagement.Shared.Inventory;
using OrderManagement.Shared.Messaging;
using OrderManagement.Shared.Models;
using OrderManagement.Shared.Persistence;

var builder = WebApplication.CreateBuilder(args);

builder.AddOrderManagementTelemetry(
    tracing => tracing.AddAspNetCoreInstrumentation(options =>
        options.Filter = context => !context.Request.Path.StartsWithSegments("/healthz")),
    metrics => metrics.AddAspNetCoreInstrumentation());

builder.Services.AddOrderQueue(builder.Configuration);
builder.Services.AddOrderStore(builder.Configuration);
builder.Services.AddInventoryClient(builder.Configuration);

builder.Services.AddProblemDetails();
builder.Services.AddExceptionHandler<ApiExceptionHandler>();

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

app.UseExceptionHandler();

var spa = SpaSettings.FromConfiguration(app.Configuration);
app.Use(async (context, next) =>
{
    var headers = context.Response.Headers;
    headers.XContentTypeOptions = "nosniff";
    headers["Referrer-Policy"] = "no-referrer";
    if (context.Request.Path.Equals(SpaSettings.RedirectBridgePath, StringComparison.OrdinalIgnoreCase))
    {
        // Its address carries the sign-in response, so nothing may keep a copy.
        headers.XFrameOptions = "SAMEORIGIN";
        headers.ContentSecurityPolicy = spa.RedirectBridgeContentSecurityPolicy;
        headers.CacheControl = "no-store";
    }
    else
    {
        headers.XFrameOptions = "DENY";
        headers.ContentSecurityPolicy = spa.ContentSecurityPolicy;
    }
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

app.UseDefaultFiles();
app.UseStaticFiles();
app.UseAuthentication();
app.UseAuthorization();

// Live while the process answers; ready while the queue and the orders database are reachable.
// The inventory service is left out: while it is down, only the product list and new orders fail.
app.MapHealthChecks("/healthz", new() { Predicate = check => check.Tags.Contains(HealthTags.Live) });
app.MapHealthChecks("/healthz/ready", new() { Predicate = check => check.Tags.Contains(HealthTags.Ready) });

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

api.MapGet("/products", async (IInventoryClient inventory, CancellationToken cancellationToken) =>
    Results.Ok(await inventory.GetProductsAsync(cancellationToken)))
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

    logger.LogInformation("User {UserId} restocked {Sku} by {Quantity}; {Available} available",
        UserIdentity.CustomerId(user), product.Sku, request.Quantity, product.Available);
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
    IMessageQueue queue,
    IInventoryClient inventory,
    OrderMetrics metrics,
    ILogger<OrderRequest> logger,
    CancellationToken cancellationToken) =>
{
    // Priced from the inventory service's current prices; stock is reserved later by the processor.
    var products = await inventory.GetProductsAsync(cancellationToken);
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
        await queue.PublishAsync(order, cancellationToken);
    }
    catch (Exception ex) when (ex is not OperationCanceledException)
    {
        logger.LogError(ex, "Could not queue order {OrderId}", order.OrderId);
        return Results.Problem("The order could not be queued. Try again shortly.", statusCode: StatusCodes.Status503ServiceUnavailable);
    }

    metrics.OrderPlaced();
    logger.LogInformation("Queued order {OrderId} for customer {CustomerId}: {LineCount} lines, {Total} {Currency}",
        order.OrderId, order.CustomerId, order.Lines.Count, order.Total, order.Currency);

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
