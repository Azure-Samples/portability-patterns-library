using System.Net;

namespace OrderManagement.Shared.Inventory;

/// <summary>The inventory service refused the request (4xx). Repeating it unchanged will not help.</summary>
public sealed class InventoryRequestException(HttpStatusCode statusCode, string message)
    : Exception(message)
{
    public HttpStatusCode StatusCode { get; } = statusCode;
}
