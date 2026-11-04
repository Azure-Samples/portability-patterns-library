using OrderManagement.Inventory;
using OrderManagement.Inventory.Data;
using OrderManagement.Shared.Diagnostics;
using OpenTelemetry.Metrics;
using OpenTelemetry.Trace;
using OrderManagement.Shared.Models;

var builder = WebApplication.CreateBuilder(args);

builder.AddOrderManagementTelemetry(
    tracing => tracing.AddAspNetCoreInstrumentation(options =>
        options.Filter = context => !context.Request.Path.StartsWithSegments("/healthz")),
    metrics => metrics.AddAspNetCoreInstrumentation());

builder.Services.AddInventoryStore(builder.Configuration);
builder.Services.AddProblemDetails();

var authenticationRequired = builder.AddInventoryAuthentication();

var app = builder.Build();

app.UseAuthentication();
app.UseAuthorization();

// Live while the process answers; ready while the inventory database is reachable.
app.MapHealthChecks("/healthz", new() { Predicate = check => check.Tags.Contains(HealthTags.Live) }).AllowAnonymous();
app.MapHealthChecks("/healthz/ready", new() { Predicate = check => check.Tags.Contains(HealthTags.Ready) }).AllowAnonymous();

var api = app.MapGroup("/api");
if (!authenticationRequired)
{
    app.Logger.LogWarning("InventoryAuth__Authority is not set: in Development the inventory API accepts calls without a token");
    api.AllowAnonymous();
}

api.MapGet("/products", async (IProductRepository products, CancellationToken cancellationToken) =>
    Results.Ok(await products.ListAsync(cancellationToken)))
    .RequireAuthorization(InventoryRoles.Read);

api.MapPost("/reservations", async (
    ReservationRequest request,
    IStockRepository stock,
    ILogger<ReservationRequest> logger,
    CancellationToken cancellationToken) =>
{
    var errors = Validate(request);
    if (errors is not null)
    {
        return Results.ValidationProblem(errors);
    }

    var outcome = await stock.ReserveAsync(request.OrderId, request.Lines, cancellationToken);
    if (outcome.Result is null)
    {
        return Results.ValidationProblem(new Dictionary<string, string[]>
        {
            ["lines"] = [$"Unknown products: {string.Join(", ", outcome.UnknownSkus)}."]
        });
    }

    logger.LogInformation("Reservation for order {OrderId}: {Status}{Unavailable}",
        request.OrderId, outcome.Result.Status,
        outcome.Result.UnavailableSkus.Count > 0 ? $" ({string.Join(", ", outcome.Result.UnavailableSkus)})" : string.Empty);

    return Results.Ok(outcome.Result);
})
    .RequireAuthorization(InventoryRoles.Reserve);

// Gives an order's reserved stock back, when the order won't complete. Idempotent.
api.MapDelete("/reservations/{orderId:guid}", async (
    Guid orderId,
    IStockRepository stock,
    ILogger<ReservationRequest> logger,
    CancellationToken cancellationToken) =>
{
    if (await stock.ReleaseAsync(orderId, cancellationToken))
    {
        logger.LogWarning("Released the stock reserved for order {OrderId}", orderId);
    }

    return Results.NoContent();
})
    .RequireAuthorization(InventoryRoles.Reserve);

api.MapPost("/products/{sku}/restock", async (
    string sku,
    RestockRequest request,
    IStockRepository stock,
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

    var product = await stock.RestockAsync(sku, request.Quantity, cancellationToken);
    if (product is null)
    {
        return Results.NotFound();
    }

    logger.LogInformation("Restocked {Sku} by {Quantity}; {Available} available", sku, request.Quantity, product.Available);
    return Results.Ok(product);
})
    .RequireAuthorization(InventoryRoles.Restock);

app.Run();

static Dictionary<string, string[]>? Validate(ReservationRequest request)
{
    const int maxLines = 100;

    if (request.OrderId == Guid.Empty)
    {
        return new() { ["orderId"] = ["An order ID is required."] };
    }

    if (request.Lines is not { Count: > 0 and <= maxLines })
    {
        return new() { ["lines"] = [$"A reservation needs between 1 and {maxLines} lines."] };
    }

    var errors = new Dictionary<string, string[]>();
    for (var i = 0; i < request.Lines.Count; i++)
    {
        var line = request.Lines[i];
        if (string.IsNullOrWhiteSpace(line.Sku))
        {
            errors[$"lines[{i}].sku"] = ["A SKU is required."];
        }

        if (line.Quantity <= 0)
        {
            errors[$"lines[{i}].quantity"] = ["Quantity must be greater than zero."];
        }
    }

    return errors.Count > 0 ? errors : null;
}
