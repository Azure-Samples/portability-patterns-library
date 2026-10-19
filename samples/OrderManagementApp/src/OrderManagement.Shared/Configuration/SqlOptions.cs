using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Configuration;

namespace OrderManagement.Shared.Configuration;

/// <summary>
/// Settings for the <c>sql</c> connection, backed by the built-in
/// <c>Radius.Data/sqlServerDatabases</c> Resource Type.
///
/// Locally this resolves to a SQL Server container in the cluster authenticated with SQL logins.
/// In Azure it resolves to Azure SQL Database; when no password is supplied the worker acquires an
/// Entra ID access token through Workload Identity instead.
/// </summary>
public sealed class SqlOptions
{
    public required string Host { get; init; }
    public required int Port { get; init; }
    public required string Database { get; init; }
    public string? Username { get; init; }
    public string? Password { get; init; }

    /// <summary>
    /// Path to a file holding the password. Preferred over <see cref="Password"/> wherever a vault
    /// or secret store supplies the credential: a mounted file tracks rotation, an environment
    /// variable cannot change under a running process.
    /// </summary>
    public string? PasswordFile { get; init; }

    public string? WorkloadIdentityClientId { get; init; }

    /// <summary>
    /// Forces Entra ID authentication even when a password is present. The Azure environment sets
    /// this because the Resource Type always provisions a SQL administrator login, but the workers
    /// should still authenticate passwordlessly through Workload Identity.
    /// </summary>
    public bool ForceEntraId { get; init; }

    /// <summary>
    /// True when the worker authenticates to SQL with an Entra ID token obtained via Workload
    /// Identity rather than a SQL login.
    /// </summary>
    public bool UseEntraId => ForceEntraId ||
        (string.IsNullOrWhiteSpace(Password) && string.IsNullOrWhiteSpace(PasswordFile));

    /// <summary>
    /// Reads the password as it stands now. Called for every connection so a credential that was
    /// rotated since the process started, or since the last connection, is still honoured.
    /// </summary>
    public string? ResolvePassword() =>
        string.IsNullOrWhiteSpace(PasswordFile) ? Password : File.ReadAllText(PasswordFile).Trim();

    /// <summary>Entra ID scope used when requesting an access token for Azure SQL.</summary>
    public const string EntraScope = "https://database.windows.net/.default";

    public static SqlOptions FromConfiguration(IConfiguration configuration, string connectionName = "sql")
    {
        var values = new ConnectionValues(configuration, connectionName);

        return new SqlOptions
        {
            Host = values.GetRequired("host"),
            Port = values.GetInt32("port", 1433),
            Database = values.Get("database") ?? "omsdb",
            Username = values.Get("username"),
            Password = values.Get("password"),
            PasswordFile = values.Get("passwordFile"),
            WorkloadIdentityClientId = values.Get("workloadIdentityClientId"),
            ForceEntraId = configuration.GetValue("OrderManagement:Sql:UseEntraId", false)
        };
    }

    public string BuildConnectionString() => BuildConnectionString(Database, ResolvePassword());

    /// <summary>
    /// Connection string pointed at <c>master</c>, used only to create the application database on a
    /// freshly provisioned SQL Server container.
    /// </summary>
    public string BuildMasterConnectionString() => BuildConnectionString("master", ResolvePassword());

    private string BuildConnectionString(string database, string? password)
    {
        var builder = new SqlConnectionStringBuilder
        {
            DataSource = $"tcp:{Host},{Port}",
            InitialCatalog = database,
            Encrypt = true,
            ConnectTimeout = 30,
            CommandTimeout = 60,
            ApplicationName = "OrderManagement"
        };

        if (UseEntraId)
        {
            // No credentials in the connection string. The access token is attached per-connection
            // from the Workload Identity federated credential.
            return builder.ConnectionString;
        }

        builder.UserID = Username ?? throw new InvalidOperationException(
            "A SQL username is required when a SQL password is configured.");
        builder.Password = password;

        // The local SQL Server container uses a self-signed certificate.
        builder.TrustServerCertificate = true;

        return builder.ConnectionString;
    }
}
