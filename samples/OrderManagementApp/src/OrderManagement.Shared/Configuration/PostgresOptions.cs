using Microsoft.Extensions.Configuration;
using Npgsql;

namespace OrderManagement.Shared.Configuration;

/// <summary>
/// Where the <c>inventorydb</c> connection points: Azure Database for PostgreSQL on Azure, a
/// PostgreSQL container on Azure Local and in local compose. Credentials are not part of it.
/// </summary>
public sealed class PostgresOptions
{
    public required string Host { get; init; }
    public required int Port { get; init; }
    public required string Database { get; init; }

    /// <summary><c>CONNECTION_INVENTORYDB_TLS</c>: <c>required</c> (default) or <c>optional</c>.</summary>
    public required bool TlsRequired { get; init; }

    public static PostgresOptions FromConfiguration(IConfiguration configuration, string connectionName = "inventorydb")
    {
        var values = new ConnectionValues(configuration, connectionName);
        var tls = values.Get("tls")?.Trim().ToLowerInvariant() ?? "required";

        return new PostgresOptions
        {
            Host = values.GetRequired("host"),
            Port = values.GetInt32("port", 5432),
            Database = values.Get("database") ?? "inventory",
            TlsRequired = tls switch
            {
                "required" => true,
                "optional" => false,
                _ => throw new InvalidOperationException(
                    $"Unsupported TLS setting '{tls}' for connection '{connectionName}'. Expected 'required' or 'optional'.")
            }
        };
    }

    // Azure Database for PostgreSQL presents a certificate from a public CA for its own host name,
    // so it is verified there. A cluster-local server has a self-signed one: encrypted, not verified.
    private bool CanVerifyCertificate =>
        Host.EndsWith(".postgres.database.azure.com", StringComparison.OrdinalIgnoreCase);

    /// <summary>Connection string without a password; the data source supplies it per connection.</summary>
    public string BuildConnectionString(string userName, string? database = null) =>
        new NpgsqlConnectionStringBuilder
        {
            Host = Host,
            Port = Port,
            Database = database ?? Database,
            Username = userName,
            SslMode = TlsRequired
                ? CanVerifyCertificate ? SslMode.VerifyFull : SslMode.Require
                : SslMode.Prefer,
            Timeout = 30,
            CommandTimeout = 60,
            ApplicationName = "OrderManagement"
        }.ConnectionString;
}
