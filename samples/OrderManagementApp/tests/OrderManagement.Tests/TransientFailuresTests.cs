using System.Net;
using System.Net.Sockets;
using Amazon.S3;
using Azure;
using Npgsql;
using OrderManagement.Shared.Inventory;
using OrderManagement.Shared.Resilience;

namespace OrderManagement.Tests;

/// <summary>Which failures are retried in place, and which fail at once.</summary>
public sealed class TransientFailuresTests
{
    [Fact]
    public void Waits_out_a_dependency_that_is_unreachable_or_restarting()
    {
        Assert.True(TransientFailures.IsTransient(new SocketException((int)SocketError.ConnectionRefused)));
        Assert.True(TransientFailures.IsTransient(new TimeoutException()));
        Assert.True(TransientFailures.IsTransient(new InvalidOperationException("wrapped", new SocketException((int)SocketError.HostNotFound))));
        Assert.True(TransientFailures.IsTransient(new InventoryUnavailableException("down")));
        Assert.True(TransientFailures.IsTransient(new RequestFailedException(503, "Server busy")));
        Assert.True(TransientFailures.IsTransient(new AmazonS3Exception("unavailable") { StatusCode = HttpStatusCode.ServiceUnavailable }));
        Assert.True(TransientFailures.IsTransient(new PostgresException("the database system is starting up", "FATAL", "FATAL", "57P03")));
    }

    [Fact]
    public void Fails_at_once_on_a_wrong_password_a_missing_permission_or_a_bad_request()
    {
        Assert.False(TransientFailures.IsTransient(new PostgresException("password authentication failed", "FATAL", "FATAL", "28P01")));
        Assert.False(TransientFailures.IsTransient(new PostgresException("permission denied for table", "ERROR", "ERROR", "42501")));
        Assert.False(TransientFailures.IsTransient(new RequestFailedException(403, "This request is not authorized")));
        Assert.False(TransientFailures.IsTransient(new AmazonS3Exception("denied") { StatusCode = HttpStatusCode.Forbidden }));
        Assert.False(TransientFailures.IsTransient(new InventoryRequestException(HttpStatusCode.BadRequest, "bad")));
        Assert.False(TransientFailures.IsTransient(new InvalidOperationException("No principal for 'api'")));
    }
}
