using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Configuration;
using OrderManagement.Shared.Identity;

namespace OrderManagement.Shared.Configuration;

/// <summary>
/// Where the <c>sql</c> connection points, backed by the built-in
/// <c>Radius.Data/sqlServerDatabases</c> Resource Type: Azure SQL Database on Azure, a SQL Server
/// container on Azure Local.
///
/// Only the target comes from the connection. How the service signs in is a separate concern
/// (<see cref="IDatabaseCredentialProvider"/>): each service has its own least-privilege principal.
/// </summary>
public sealed class SqlOptions
{
    public required string Host { get; init; }
    public required int Port { get; init; }
    public required string Database { get; init; }

    public static SqlOptions FromConfiguration(IConfiguration configuration, string connectionName = "sql")
    {
        var values = new ConnectionValues(configuration, connectionName);

        return new SqlOptions
        {
            Host = values.GetRequired("host"),
            Port = values.GetInt32("port", 1433),
            Database = values.Get("database") ?? "omsdb"
        };
    }

    /// <summary>
    /// Connection string for <paramref name="database"/> (default: the application database). With
    /// an access token the string carries no credentials; the token is attached to the connection.
    /// </summary>
    public string BuildConnectionString(DatabaseCredential credential, string? database = null)
    {
        var builder = new SqlConnectionStringBuilder
        {
            DataSource = $"tcp:{Host},{Port}",
            InitialCatalog = database ?? Database,
            Encrypt = true,
            ConnectTimeout = 30,
            CommandTimeout = 60,
            ApplicationName = "OrderManagement"
        };

        if (credential.IsAccessToken)
        {
            return builder.ConnectionString;
        }

        builder.UserID = credential.UserName;
        builder.Password = credential.Secret;

        // A SQL login means the SQL Server container, which uses a self-signed certificate.
        builder.TrustServerCertificate = true;

        return builder.ConnectionString;
    }
}
