using DbUp;
using DbUp.Postgresql;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using Npgsql;
using OrderManagement.Shared.Configuration;
using OrderManagement.Shared.Identity;
using OrderManagement.Shared.Persistence;

namespace OrderManagement.DbSetup;

/// <summary>
/// The inventory database (the <c>inventorydb</c> connection): its migrations (schema
/// <c>inventory</c> and the starting products), and the <c>inventory</c> role with the row access the
/// inventory service uses. On Azure the role is the inventory service's Entra identity
/// (<c>INVENTORY_OBJECT_ID</c>); elsewhere a password role (<c>INVENTORY_DB_PASSWORD</c>).
/// </summary>
public sealed class PostgresSetup(
    IOptions<PostgresOptions> options,
    IOptions<DbSetupOptions> setup,
    WorkloadIdentity identity,
    IConfiguration configuration,
    ILoggerFactory loggerFactory)
{
    public const string Role = "inventory";

    // What the inventory service's statements need, table by table (Data/Postgres*Repository.cs).
    // SELECT ... FOR UPDATE needs UPDATE.
    private static readonly (string Table, string Privileges)[] Grants =
    [
        ("inventory.products", "SELECT, UPDATE"),
        ("inventory.reservations", "SELECT, INSERT, UPDATE"),
        ("inventory.reservation_lines", "SELECT, INSERT, DELETE")
    ];

    private readonly ILogger _logger = loggerFactory.CreateLogger<PostgresSetup>();

    public async Task RunAsync(CancellationToken cancellationToken)
    {
        var target = options.Value;
        var admin = DatabaseLogin.Create(configuration, identity, "POSTGRES_ADMIN_USERNAME", "POSTGRES_ADMIN_PASSWORD",
            DatabaseLogin.PostgresScope, tokenNeedsUserName: true);

        _logger.LogInformation("Setting up PostgreSQL host {Host}, database {Database}, as {Login}",
            target.Host, target.Database, admin);

        // Databases and roles are server-wide; Entra principals can only be created from 'postgres'.
        await using var server = PostgresDataSourceFactory.Create(target, admin, loggerFactory, database: "postgres");
        await using var session = await setup.Value.CreateConnectPipeline($"PostgreSQL {target.Host}", _logger)
            .ExecuteAsync(async token => await server.OpenConnectionAsync(token), cancellationToken);
        await EnsureDatabaseAsync(session, target.Database!, cancellationToken);
        await EnsureRoleAsync(session, cancellationToken);

        await using var database = PostgresDataSourceFactory.Create(target, admin, loggerFactory);
        Migrations.Apply(
            DeployChanges.To.PostgresqlDatabase(new PostgresqlConnectionManager(database))
                .JournalToPostgresqlTable("public", "schemaversions"),
            "Postgres", loggerFactory);

        await using var db = await database.OpenConnectionAsync(cancellationToken);
        await ExecuteAsync(db, $"GRANT CONNECT ON DATABASE {Identifier(target.Database!)} TO {Identifier(Role)}", cancellationToken);
        await ExecuteAsync(db, $"GRANT USAGE ON SCHEMA inventory TO {Identifier(Role)}", cancellationToken);
        foreach (var (table, privileges) in Grants)
        {
            await ExecuteAsync(db, $"GRANT {privileges} ON {table} TO {Identifier(Role)}", cancellationToken);
            _logger.LogInformation("Role {Role} has {Privileges} on {Table}", Role, privileges, table);
        }
    }

    private async Task EnsureDatabaseAsync(NpgsqlConnection connection, string databaseName, CancellationToken cancellationToken)
    {
        await using var exists = new NpgsqlCommand("SELECT 1 FROM pg_database WHERE datname = @name", connection);
        exists.Parameters.AddWithValue("name", databaseName);
        if (await exists.ExecuteScalarAsync(cancellationToken) is not null)
        {
            _logger.LogInformation("Database {Database} exists", databaseName);
            return;
        }

        await ExecuteAsync(connection, $"CREATE DATABASE {Identifier(databaseName)}", cancellationToken);
        _logger.LogInformation("Created database {Database}", databaseName);
    }

    private async Task EnsureRoleAsync(NpgsqlConnection connection, CancellationToken cancellationToken)
    {
        await using var exists = new NpgsqlCommand("SELECT 1 FROM pg_roles WHERE rolname = @name", connection);
        exists.Parameters.AddWithValue("name", Role);
        var roleExists = await exists.ExecuteScalarAsync(cancellationToken) is not null;

        var objectId = Value("INVENTORY_OBJECT_ID");
        var password = Value("INVENTORY_DB_PASSWORD");

        if (objectId is not null)
        {
            if (!Guid.TryParse(objectId, out var parsed))
            {
                throw new InvalidOperationException("INVENTORY_OBJECT_ID is not a valid object ID.");
            }

            if (!roleExists)
            {
                await using var create = new NpgsqlCommand(
                    "SELECT * FROM pgaadauth_create_principal_with_oid(@name, @objectId, 'service', false, false)", connection);
                create.Parameters.AddWithValue("name", Role);
                create.Parameters.AddWithValue("objectId", parsed.ToString("D"));
                await create.ExecuteNonQueryAsync(cancellationToken);
            }

            _logger.LogInformation("Entra role {Role} {State}", Role, roleExists ? "exists" : "created");
            return;
        }

        if (password is null)
        {
            throw new InvalidOperationException(
                $"No principal for '{Role}': set INVENTORY_OBJECT_ID (Entra) or INVENTORY_DB_PASSWORD (password role).");
        }

        // ALTER applies a changed (rotated) password. PostgreSQL stores it hashed (SCRAM-SHA-256).
        var verb = roleExists ? "ALTER" : "CREATE";
        await ExecuteAsync(connection,
            $"{verb} ROLE {Identifier(Role)} WITH LOGIN PASSWORD '{password.Replace("'", "''", StringComparison.Ordinal)}'",
            cancellationToken);
        _logger.LogInformation("Password role {Role} {State}", Role, roleExists ? "updated" : "created");
    }

    private static async Task ExecuteAsync(NpgsqlConnection connection, string sql, CancellationToken cancellationToken)
    {
        await using var command = new NpgsqlCommand(sql, connection);
        await command.ExecuteNonQueryAsync(cancellationToken);
    }

    private static string Identifier(string name) => $"\"{name.Replace("\"", "\"\"", StringComparison.Ordinal)}\"";

    private string? Value(string key) => string.IsNullOrWhiteSpace(configuration[key]) ? null : configuration[key];
}
