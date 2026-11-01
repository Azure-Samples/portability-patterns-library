using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;
using Npgsql;
using NpgsqlTypes;
using OrderManagement.Shared.Configuration;
using OrderManagement.Shared.Identity;
using OrderManagement.Shared.Persistence;

namespace OrderManagement.DbSetup;

/// <summary>
/// The inventory database (the <c>inventorydb</c> connection): schema <c>inventory</c>, seed
/// products, and the <c>inventory</c> role with row access only. On Azure the role is the inventory
/// service's Entra identity (<c>INVENTORY_OBJECT_ID</c>); elsewhere a password role
/// (<c>INVENTORY_DB_PASSWORD</c>).
/// </summary>
public sealed class PostgresSetup(IConfiguration configuration, ILoggerFactory loggerFactory) : IDatabaseSetup
{
    private const string Role = DatabaseCredentialProviders.DefaultPostgresUserName;

    private static readonly string[] SchemaStatements =
    [
        "CREATE SCHEMA IF NOT EXISTS inventory",
        """
        CREATE TABLE IF NOT EXISTS inventory.products
        (
            sku           text          PRIMARY KEY,
            name          text          NOT NULL,
            unit_price    numeric(12,2) NOT NULL CHECK (unit_price >= 0),
            currency      char(3)       NOT NULL,
            available     int           NOT NULL CHECK (available >= 0),
            reorder_level int           NOT NULL DEFAULT 0
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS inventory.reservations
        (
            order_id   uuid        PRIMARY KEY,
            status     text        NOT NULL,
            created_at timestamptz NOT NULL DEFAULT now()
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS inventory.reservation_lines
        (
            order_id uuid NOT NULL REFERENCES inventory.reservations (order_id) ON DELETE CASCADE,
            sku      text NOT NULL REFERENCES inventory.products (sku),
            quantity int  NOT NULL CHECK (quantity > 0),
            PRIMARY KEY (order_id, sku)
        )
        """
    ];

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
        await using (var server = PostgresDataSourceFactory.Create(options, admin, loggerFactory, database: "postgres"))
        await using (var connection = await ConnectionRetry.OpenAsync(
            token => server.OpenConnectionAsync(token).AsTask(), $"PostgreSQL {options.Host}", _logger, cancellationToken))
        {
            await EnsureDatabaseAsync(connection, options.Database, cancellationToken);
            await EnsureRoleAsync(connection, cancellationToken);
        }

        await using var database = PostgresDataSourceFactory.Create(options, admin, loggerFactory);
        await using var db = await ConnectionRetry.OpenAsync(
            token => database.OpenConnectionAsync(token).AsTask(), $"PostgreSQL database {options.Database}", _logger, cancellationToken);

        foreach (var statement in SchemaStatements)
        {
            await ExecuteAsync(db, statement, cancellationToken);
        }

        await SeedAsync(db, cancellationToken);

        await ExecuteAsync(db, $"GRANT CONNECT ON DATABASE {Identifier(options.Database)} TO {Identifier(Role)}", cancellationToken);
        await ExecuteAsync(db, $"GRANT USAGE ON SCHEMA inventory TO {Identifier(Role)}", cancellationToken);
        await ExecuteAsync(db, $"GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA inventory TO {Identifier(Role)}", cancellationToken);

        _logger.LogInformation("Role {Role} has SELECT, INSERT, UPDATE, DELETE on schema inventory", Role);
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

    private async Task SeedAsync(NpgsqlConnection connection, CancellationToken cancellationToken)
    {
        var products = SeedCatalog.Products;
        await using var seed = new NpgsqlCommand(
            """
            INSERT INTO inventory.products (sku, name, unit_price, currency, available, reorder_level)
            SELECT seed.sku, seed.name, seed.unit_price, @currency, @available, @reorderLevel
            FROM unnest(@skus, @names, @prices) AS seed(sku, name, unit_price)
            WHERE NOT EXISTS (SELECT 1 FROM inventory.products)
            """, connection);
        seed.Parameters.Add(new NpgsqlParameter("skus", NpgsqlDbType.Array | NpgsqlDbType.Text) { Value = products.Select(p => p.Sku).ToArray() });
        seed.Parameters.Add(new NpgsqlParameter("names", NpgsqlDbType.Array | NpgsqlDbType.Text) { Value = products.Select(p => p.Name).ToArray() });
        seed.Parameters.Add(new NpgsqlParameter("prices", NpgsqlDbType.Array | NpgsqlDbType.Numeric) { Value = products.Select(p => p.UnitPrice).ToArray() });
        seed.Parameters.AddWithValue("currency", SeedCatalog.Currency);
        seed.Parameters.AddWithValue("available", SeedCatalog.StartingStock);
        seed.Parameters.AddWithValue("reorderLevel", SeedCatalog.ReorderLevel);

        var inserted = await seed.ExecuteNonQueryAsync(cancellationToken);
        if (inserted > 0)
        {
            _logger.LogInformation("Seeded {Count} products", inserted);
        }
        else
        {
            _logger.LogInformation("Products already present; seed skipped");
        }
    }

    private static async Task ExecuteAsync(NpgsqlConnection connection, string sql, CancellationToken cancellationToken)
    {
        await using var command = new NpgsqlCommand(sql, connection);
        await command.ExecuteNonQueryAsync(cancellationToken);
    }

    private static string Identifier(string name) => $"\"{name.Replace("\"", "\"\"", StringComparison.Ordinal)}\"";

    private string? Value(string key) => string.IsNullOrWhiteSpace(configuration[key]) ? null : configuration[key];
}
