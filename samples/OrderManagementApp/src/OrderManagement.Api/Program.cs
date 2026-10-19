using System.Security.Claims;
using OrderManagement.Api;
using OrderManagement.Shared.DependencyInjection;
using OrderManagement.Shared.Messaging;
using OrderManagement.Shared.Models;
using OrderManagement.Shared.Persistence;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.Identity.Web;
using Microsoft.Identity.Web.Resource;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddOrderQueue();
builder.Services.AddOrderStore();

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
    .AddPolicy(OrderPolicies.Create, policy => policy.RequireRole(OrderRoles.Create));

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
    canCreate = user.IsInRole(OrderRoles.Create)
}))
    .RequireAuthorization();

api.MapGet("/products", () => Results.Ok(ProductCatalog.Products))
    .RequireAuthorization();

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
    ILogger<OrderRequest> logger,
    CancellationToken cancellationToken) =>
{
    var (lines, errors) = ProductCatalog.Price(request);
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
