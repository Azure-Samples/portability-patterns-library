using System.Net;
using System.Net.Http.Json;
using OrderManagement.Shared.Models;
using Polly.CircuitBreaker;
using Polly.Timeout;

namespace OrderManagement.Shared.Inventory;

/// <summary>
/// <see cref="IInventoryClient"/> over the inventory service's HTTP API. A typed client: the base
/// address, the token handler and the resilience handler (retries, timeouts, circuit breaker) are
/// configured where it is registered.
/// </summary>
public sealed class HttpInventoryClient(HttpClient http) : IInventoryClient
{
    public async Task<IReadOnlyList<Product>> GetProductsAsync(CancellationToken cancellationToken)
    {
        using var response = await SendAsync(new HttpRequestMessage(HttpMethod.Get, "api/products"), cancellationToken)
            .ConfigureAwait(false);
        await EnsureSuccessAsync(response, cancellationToken).ConfigureAwait(false);
        return await ReadAsync<List<Product>>(response, cancellationToken).ConfigureAwait(false);
    }

    public async Task<ReservationResult> ReserveAsync(ReservationRequest request, CancellationToken cancellationToken)
    {
        using var response = await SendAsync(
            new HttpRequestMessage(HttpMethod.Post, "api/reservations") { Content = JsonContent.Create(request) },
            cancellationToken).ConfigureAwait(false);
        await EnsureSuccessAsync(response, cancellationToken).ConfigureAwait(false);
        return await ReadAsync<ReservationResult>(response, cancellationToken).ConfigureAwait(false);
    }

    public async Task ReleaseAsync(Guid orderId, CancellationToken cancellationToken)
    {
        using var response = await SendAsync(
            new HttpRequestMessage(HttpMethod.Delete, $"api/reservations/{orderId:D}"), cancellationToken).ConfigureAwait(false);
        await EnsureSuccessAsync(response, cancellationToken).ConfigureAwait(false);
    }

    public async Task<Product?> RestockAsync(string sku, int quantity, CancellationToken cancellationToken)
    {
        using var response = await SendAsync(
            new HttpRequestMessage(HttpMethod.Post, $"api/products/{Uri.EscapeDataString(sku)}/restock")
            {
                Content = JsonContent.Create(new RestockRequest { Quantity = quantity })
            },
            cancellationToken).ConfigureAwait(false);

        if (response.StatusCode == HttpStatusCode.NotFound)
        {
            return null;
        }

        await EnsureSuccessAsync(response, cancellationToken).ConfigureAwait(false);
        return await ReadAsync<Product>(response, cancellationToken).ConfigureAwait(false);
    }

    // Separates "try again later" from "this request is wrong", which callers handle differently.
    // What reaches here has already been retried by the resilience handler.
    private async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        using (request)
        {
            HttpResponseMessage response;
            try
            {
                response = await http.SendAsync(request, cancellationToken).ConfigureAwait(false);
            }
            catch (Exception ex) when (ex is HttpRequestException or TimeoutRejectedException or BrokenCircuitException
                // HttpClient's own timeout, which also covers reading the body.
                or TaskCanceledException { InnerException: TimeoutException })
            {
                throw new InventoryUnavailableException($"The inventory service could not be reached: {ex.Message}", ex);
            }

            if ((int)response.StatusCode >= 500 ||
                response.StatusCode is HttpStatusCode.RequestTimeout or HttpStatusCode.TooManyRequests)
            {
                var status = (int)response.StatusCode;
                response.Dispose();
                throw new InventoryUnavailableException($"The inventory service answered {status}.");
            }

            return response;
        }
    }

    private static async Task EnsureSuccessAsync(HttpResponseMessage response, CancellationToken cancellationToken)
    {
        if (response.IsSuccessStatusCode)
        {
            return;
        }

        var body = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
        throw new InventoryRequestException(response.StatusCode,
            $"The inventory service refused {response.RequestMessage?.Method} {response.RequestMessage?.RequestUri?.AbsolutePath} " +
            $"with {(int)response.StatusCode}: {body}");
    }

    private static async Task<T> ReadAsync<T>(HttpResponseMessage response, CancellationToken cancellationToken) =>
        await response.Content.ReadFromJsonAsync<T>(cancellationToken).ConfigureAwait(false)
        ?? throw new InventoryUnavailableException("The inventory service sent an empty response.");
}
