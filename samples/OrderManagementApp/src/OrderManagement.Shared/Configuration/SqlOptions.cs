using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Configuration;
using OrderManagement.Shared.Identity;

namespace OrderManagement.Shared.Configuration;

/// <summary>
/// Settings for the <c>sql</c> connection, backed by the built-in
/// <c>Radius.Data/sqlServerDatabases</c> Resource Type.
///
/// The platform decides how the application authenticates, in this order:
/// <list type="number">
/// <item>Azure: an Entra workload identity is attached, so the application connects to Azure SQL
/// Database with an Entra ID access token.</item>
/// <item>Azure Local with Active Directory: a Kerberos client keytab is attached, so the application
/// connects to the SQL Server container with integrated (Kerberos) authentication.</item>
/// <item>Otherwise: the SQL login the connection carries.</item>
/// </list>
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

    /// <summary>
    /// True when the platform attached an Entra workload identity to the pod. The Resource Type
    /// always carries a SQL login, but where an Entra identity exists it is used instead.
    /// </summary>
    public bool HasWorkloadIdentity { get; init; }

    /// <summary>True when the platform attached a Kerberos client keytab to the pod.</summary>
    public bool HasKerberosIdentity { get; init; }

    /// <summary>
    /// True when the application authenticates as its Active Directory account through Kerberos
    /// rather than with a SQL login.
    /// </summary>
    public bool UseKerberos => !HasWorkloadIdentity && HasKerberosIdentity;

    /// <summary>
    /// True when the application authenticates to SQL with an Entra ID token obtained through
    /// Workload Identity rather than a SQL login.
    /// </summary>
    public bool UseEntraId => HasWorkloadIdentity ||
        (!HasKerberosIdentity && string.IsNullOrWhiteSpace(Password) && string.IsNullOrWhiteSpace(PasswordFile));

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
            HasWorkloadIdentity = AzureCredentialFactory.HasWorkloadIdentity,
            HasKerberosIdentity = KerberosIdentity.IsAvailable
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

        if (UseKerberos)
        {
            // Tickets come from the client keytab; SQL Server maps them to the account's Windows login.
            builder.IntegratedSecurity = true;
            builder.TrustServerCertificate = true;
            return builder.ConnectionString;
        }

        builder.UserID = Username ?? throw new InvalidOperationException(
            "A SQL username is required when a SQL password is configured.");
        builder.Password = password;

        // The SQL Server container uses a self-signed certificate.
        builder.TrustServerCertificate = true;

        return builder.ConnectionString;
    }
}
