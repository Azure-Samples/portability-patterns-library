using System.Data.Common;
using System.Net;
using System.Net.Sockets;
using Amazon.S3;
using Azure;
using Microsoft.Data.SqlClient;
using OrderManagement.Shared.Inventory;

namespace OrderManagement.Shared.Resilience;

/// <summary>
/// Which failures go away on their own, so retrying can succeed: timeouts, network errors, 5xx and
/// 429 answers, and the databases' own transient errors. Everything else (a wrong password, a missing
/// permission, a bad request) fails at once.
/// </summary>
public static class TransientFailures
{
    public static bool IsTransient(Exception exception)
    {
        for (var current = exception; current is not null; current = current.InnerException)
        {
            switch (current)
            {
                case TimeoutException:
                case SocketException:
                case HttpRequestException:
                // The inventory client's 5xx, 429, timeouts and open circuit.
                case InventoryUnavailableException:
                case RequestFailedException { Status: 0 or 408 or 429 or >= 500 }:
                case AmazonS3Exception s3 when s3.StatusCode is HttpStatusCode.RequestTimeout or HttpStatusCode.TooManyRequests
                    || (int)s3.StatusCode >= 500:
                case SqlException sql when sql.Errors.Cast<SqlError>().Any(error =>
                    SqlConfigurableRetryFactory.BaselineTransientErrors.Contains(error.Number)):
                case DbException { IsTransient: true }:
                    return true;
            }
        }

        return false;
    }
}
