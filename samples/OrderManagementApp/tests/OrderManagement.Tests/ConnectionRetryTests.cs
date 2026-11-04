using System.Net.Sockets;
using Npgsql;
using OrderManagement.DbSetup;

namespace OrderManagement.Tests;

/// <summary>Which first-connection errors the database setup job waits out, and which it fails on.</summary>
public sealed class ConnectionRetryTests
{
    [Fact]
    public void Waits_out_a_server_that_is_not_reachable_yet()
    {
        Assert.True(ConnectionRetry.IsTransient(new SocketException((int)SocketError.ConnectionRefused)));
        Assert.True(ConnectionRetry.IsTransient(new TimeoutException()));
        Assert.True(ConnectionRetry.IsTransient(new InvalidOperationException("wrapped", new SocketException((int)SocketError.HostNotFound))));
    }

    [Fact]
    public void Waits_out_a_postgres_server_that_is_starting()
    {
        Assert.True(ConnectionRetry.IsTransient(new PostgresException("the database system is starting up", "FATAL", "FATAL", "57P03")));
    }

    [Fact]
    public void Fails_at_once_on_a_wrong_password_or_a_missing_permission()
    {
        Assert.False(ConnectionRetry.IsTransient(new PostgresException("password authentication failed", "FATAL", "FATAL", "28P01")));
        Assert.False(ConnectionRetry.IsTransient(new PostgresException("permission denied for database", "FATAL", "FATAL", "42501")));
        Assert.False(ConnectionRetry.IsTransient(new InvalidOperationException("No principal for 'api'")));
    }
}
