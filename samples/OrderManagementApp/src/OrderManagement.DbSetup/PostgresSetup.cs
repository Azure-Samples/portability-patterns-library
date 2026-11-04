using DbUp;
using DbUp.Postgresql;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;
using Npgsql;
using OrderManagement.Shared.Configuration;
using OrderManagement.Shared.Identity;
using OrderManagement.Shared.Persistence;

namespace OrderManagement.DbSetup;

/// <summary>
/// The inventory database (the <c>inventorydb</c> connection): its migrations (schema
/// <c>inventory</c> and the starting products), and the <c>inventory</c> role with row access only.
/// On Azure the role is the inventory service's Entra identity (<c>INVENTORY_OBJECT_ID</c>);
/// elsewhere a password role (<c>INVENTORY_DB_PASSWORD</c>).
/// </summary>
public sealed class PostgresSetup(IConfiguration configuration, ILoggerFactory loggerFactory) : IDatabaseSetup
{
    private const string Role = DatabaseCredentialProviders.DefaultPostgresUserName;

    // Held for the whole run, so two runs at once (two deployments, say) take turns. Any fixed number
    // works; this one is the job's own.
    private const long LockKey = 0x4F4D_5344_4253_4554;
    private static readonly TimeSpan LockTimeout = TimeSpan.FromMinutes(10);

    private readonly ILogger _logger = loggerFactory.CreateLogger<PostgresSetup>();

    public string Name => "PostgreSQL";

    public async Task RunAsync(CancellationToken cancellationToken)
    {
        var options = PostgresOptions.FromConfiguration(configuration);
        var admin = DatabaseCredentialProviders.Create(configuration, "POSTGRES_ADMIN_USERNAME", "POSTGRES_ADMIN_PASSWORD",
            DatabaseCredentialProviders.PostgresScope, defaultUserName: null, tokenNeedsUserName: true);

        _logger.LogInformation("Setting up PostgreSQL host {Host}, database {Database}, as {Credential}",
            options.Host, options.Database, admin.Description);

        // Databases and roles are server-wide; Entra principals can only be created from 'postgres'.
        // That connection holds the lock until the end.
        await using var server = PostgresDataSourceFactory.Create(options, admin, loggerFactory, database: "postgres");
        await using var session = await ConnectionRetry.OpenAsync(
            token => server.OpenConnectionAsync(token).AsTask(), $"PostgreSQL {options.Host}", _logger, cancellationToken);
        await LockAsync(session, cancellationToken);
        await EnsureDatabaseAsync(session, options.Database, cancellationToken);
        await EnsureRoleAsync(session, cancellationToken);

        await using var database = PostgresDataSourceFactory.Create(options, admin, loggerFactory);
        Migrations.Apply(
            DeployChanges.To.PostgresqlDatabase(new PostgresqlConnectionManager(database))
                .JournalToPostgresqlTable("public", "schemaversions"),
            "Postgres", loggerFactory);

        // Every table in the schema, including ones a later migration adds.
        await using var db = await database.OpenConnectionAsync(cancellationToken);
        await ExecuteAsync(db, $"GRANT CONNECT ON DATABASE {Identifier(options.Database)} TO {Identifier(Role)}", cancellationToken);
        await ExecuteAsync(db, $"GRANT USAGE ON SCHEMA inventory TO {Identifier(Role)}", cancellationToken);
        await ExecuteAsync(db, $"GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA inventory TO {Identifier(Role)}", cancellationToken);

        _logger.LogInformation("Role {Role} has SELECT, INSERT, UPDATE, DELETE on schema inventory", Role);
    }

    // A session-level advisory lock, released when the connection closes.
    private static async Task LockAsync(NpgsqlConnection session, CancellationToken cancellationToken)
    {
        await using var command = new NpgsqlCommand("SELECT pg_advisory_lock(@key)", session)
        {
            CommandTimeout = (int)LockTimeout.TotalSeconds
        };
        command.Parameters.AddWithValue("key", LockKey);
        await command.ExecuteNonQueryAsync(cancellationToken);
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

        // ALTER applies a changed (rotated) password. The password goes in as a parameter, never in
        // the statement text, so it cannot end up in a log of executed commands.
        var verb = roleExists ? "ALTER" : "CREATE";
        await using (var transaction = await connection.BeginTransactionAsync(cancellationToken))
        {
            await using var setPassword = new NpgsqlCommand(
                $"""
                SELECT set_config('oms.role_password', @password, true);
                DO $$ BEGIN
                    EXECUTE format('{verb} ROLE %I WITH LOGIN PASSWORD %L', '{Role}', current_setting('oms.role_password'));
                END $$;
                """, connection, transaction);
            setPassword.Parameters.AddWithValue("password", password);
            await setPassword.ExecuteNonQueryAsync(cancellationToken);
            await transaction.CommitAsync(cancellationToken);
        }

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
