using System.ComponentModel.DataAnnotations;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Options;

namespace OrderManagement.Shared.Configuration;

/// <summary>
/// The <c>sql</c> connection, backed by the built-in <c>Radius.Data/sqlServerDatabases</c> Resource
/// Type (Azure SQL Database on Azure, a SQL Server container on Azure Local), and the client's
/// tunables from the <c>Sql</c> section. Only the target comes from the connection: each service signs
/// in as its own least-privilege principal (<see cref="Identity.DatabaseLogin"/>).
/// </summary>
public sealed class SqlOptions
{
    public const string ConnectionName = "sql";
    public const string SectionName = "Sql";

    [Required]
    public string? Host { get; set; }

    [Range(1, 65535)]
    public int Port { get; set; } = 1433;

    [Required]
    public string? Database { get; set; }

    /// <summary>
    /// <c>CONNECTION_SQL_TLS</c>: <c>required</c> (default) encrypts the connection and verifies the
    /// server's certificate against the CAs the process trusts; on Azure Local that is the site CA the
    /// platform gives every pod. <c>optional</c> is only for a local server without a certificate.
    /// </summary>
    public bool TlsRequired { get; set; } = true;

    [Range(1, 600)]
    public int ConnectTimeoutSeconds { get; set; } = 30;

    [Range(1, 3600)]
    public int CommandTimeoutSeconds { get; set; } = 60;

    /// <summary>
    /// SqlClient's own retry of opening a connection, on the errors it knows to be transient (an Azure
    /// SQL failover or reconfiguration, for example), with exponential backoff.
    /// </summary>
    [Range(1, 60)]
    public int OpenRetries { get; set; } = 5;

    public TimeSpan OpenRetryDelay { get; set; } = TimeSpan.FromSeconds(1);

    public TimeSpan OpenRetryMaxDelay { get; set; } = TimeSpan.FromSeconds(30);

    public SqlConnectionStringBuilder CreateConnectionStringBuilder(string? database = null) => new()
    {
        DataSource = $"tcp:{Host},{Port}",
        InitialCatalog = database ?? Database,
        Encrypt = TlsRequired ? SqlConnectionEncryptOption.Mandatory : SqlConnectionEncryptOption.Optional,
        TrustServerCertificate = false,
        ConnectTimeout = ConnectTimeoutSeconds,
        CommandTimeout = CommandTimeoutSeconds,
        ApplicationName = "OrderManagement"
    };

    public SqlRetryLogicBaseProvider CreateOpenRetryProvider() =>
        SqlConfigurableRetryFactory.CreateExponentialRetryProvider(new SqlRetryLogicOption
        {
            NumberOfTries = OpenRetries,
            DeltaTime = OpenRetryDelay,
            MaxTimeInterval = OpenRetryMaxDelay
        });

    public static OptionsBuilder<SqlOptions> Add(IServiceCollection services) =>
        services.AddConnectionOptions<SqlOptions>(ConnectionName, SectionName, (options, values) =>
        {
            options.Host = values.Get("host");
            options.Port = values.GetInt32("port") ?? options.Port;
            options.Database = values.Get("database");
            options.TlsRequired = values.GetTlsRequired();
        });
}
