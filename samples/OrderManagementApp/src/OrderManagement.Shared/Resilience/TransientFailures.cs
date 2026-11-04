using System.Data.Common;
using System.Net;
using System.Net.Sockets;
using Amazon.S3;
using Azure;
using Microsoft.Data.SqlClient;
using OrderManagement.Shared.Inventory;
using Polly.CircuitBreaker;
using Polly.Timeout;

namespace OrderManagement.Shared.Resilience;

/// <summary>
/// Which failures go away on their own, so retrying the same work later can succeed: a dependency
/// that is restarting, failing over or briefly unreachable. Everything else (a wrong password, a
/// missing permission, a bad request) fails at once.
/// </summary>
public static class TransientFailures
{
    public static bool IsTransient(Exception exception)
    {
        for (var current = exception; current is not null; current = current.InnerException)
        {
            switch (current)
            {
                case InventoryUnavailableException:
                case SqlException sql when sql.Errors.Cast<SqlError>().Any(error =>
                    SqlConfigurableRetryFactory.BaselineTransientErrors.Contains(error.Number)):
                case DbException { IsTransient: true }:
                case RequestFailedException { Status: 0 or 408 or 429 or >= 500 }:
                case AmazonS3Exception s3 when s3.StatusCode is HttpStatusCode.RequestTimeout or HttpStatusCode.TooManyRequests
                    || (int)s3.StatusCode >= 500:
                case HttpRequestException:
                case SocketException:
                case TimeoutException:
                case TimeoutRejectedException:
                case BrokenCircuitException:
                    return true;
            }
        }

        return false;
    }
}
