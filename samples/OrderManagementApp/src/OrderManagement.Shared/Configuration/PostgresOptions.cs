using System.ComponentModel.DataAnnotations;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Options;
using Npgsql;

namespace OrderManagement.Shared.Configuration;

/// <summary>
/// The <c>inventorydb</c> connection (Azure Database for PostgreSQL on Azure, a PostgreSQL server on
/// Azure Local and in local compose) and the client's tunables from the <c>InventoryDb</c> section.
/// Credentials are not part of it.
/// </summary>
public sealed class PostgresOptions
{
    public const string ConnectionName = "inventorydb";
    public const string SectionName = "InventoryDb";

    [Required]
    public string? Host { get; set; }

    [Range(1, 65535)]
    public int Port { get; set; } = 5432;

    [Required]
    public string? Database { get; set; }

    /// <summary><c>CONNECTION_INVENTORYDB_TLS</c>: <c>required</c> (default) or <c>optional</c>.</summary>
    public bool TlsRequired { get; set; } = true;

    [Range(1, 600)]
    public int ConnectTimeoutSeconds { get; set; } = 30;

    [Range(1, 3600)]
    public int CommandTimeoutSeconds { get; set; } = 60;

    /// <summary>
    /// With TLS required the server's certificate is verified: Azure Database for PostgreSQL has one
    /// from a public CA; for an in-cluster server Npgsql reads the CA from <c>PGSSLROOTCERT</c>, which
    /// the Azure Local platform sets.
    /// </summary>
    public NpgsqlConnectionStringBuilder CreateConnectionStringBuilder(string? database = null) => new()
    {
        Host = Host,
        Port = Port,
        Database = database ?? Database,
        SslMode = TlsRequired ? SslMode.VerifyFull : SslMode.Prefer,
        Timeout = ConnectTimeoutSeconds,
        CommandTimeout = CommandTimeoutSeconds,
        ApplicationName = "OrderManagement"
    };

    public static OptionsBuilder<PostgresOptions> Add(IServiceCollection services) =>
        services.AddConnectionOptions<PostgresOptions>(ConnectionName, SectionName, (options, values) =>
        {
            options.Host = values.Get("host");
            options.Port = values.GetInt32("port") ?? options.Port;
            options.Database = values.Get("database");
            options.TlsRequired = values.GetTlsRequired();
        });
}
