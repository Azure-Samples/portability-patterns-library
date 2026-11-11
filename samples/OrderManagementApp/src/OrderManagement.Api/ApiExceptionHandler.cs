using Microsoft.AspNetCore.Diagnostics;
using OrderManagement.Shared.Inventory;

namespace OrderManagement.Api;

/// <summary>
/// Turns the failures callers can act on into problem details: a dependency that is down (503), the
/// inventory service refusing a request (502), and a token without a user identifier (403). Anything
/// else is left to the default handler, which answers 500 without details.
/// </summary>
public sealed class ApiExceptionHandler(IProblemDetailsService problems, ILogger<ApiExceptionHandler> logger) : IExceptionHandler
{
    public async ValueTask<bool> TryHandleAsync(HttpContext context, Exception exception, CancellationToken cancellationToken)
    {
        var (status, title) = exception switch
        {
            InventoryUnavailableException => (StatusCodes.Status503ServiceUnavailable, "Product information is unavailable. Try again shortly."),
            InventoryRequestException => (StatusCodes.Status502BadGateway, "The inventory service refused the request."),
            MissingUserIdentifierException => (StatusCodes.Status403Forbidden, "The access token carries no user identifier."),
            _ => (0, null)
        };

        if (status == 0)
        {
            return false;
        }

        // The endpoint's route template, not anything the caller sent; the exception carries the rest.
        logger.LogWarning(exception, "{Endpoint} answered {Status}", context.GetEndpoint()?.DisplayName, status);
        context.Response.StatusCode = status;
        return await problems.TryWriteAsync(new ProblemDetailsContext
        {
            HttpContext = context,
            Exception = exception,
            ProblemDetails = { Status = status, Title = title }
        });
    }
}

/// <summary>The access token carries neither <c>oid</c> nor <c>sub</c>, so orders can't be tied to a user.</summary>
public sealed class MissingUserIdentifierException() : Exception("The access token carries no user identifier.");
