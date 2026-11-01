using Dapper;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;
using OrderManagement.Shared.Configuration;
using OrderManagement.Shared.Identity;
using OrderManagement.Shared.Persistence;

namespace OrderManagement.DbSetup;

/// <summary>
/// The orders database (the <c>sql</c> connection): <c>dbo.Orders</c>, and a database user per
/// service with only the rights it needs. On Azure the users are the services' Entra identities
/// (<c>SQL_API_CLIENT_ID</c>, <c>SQL_PROCESSOR_CLIENT_ID</c>: their managed identities' client IDs);
/// elsewhere they are SQL logins (<c>SQL_API_PASSWORD</c>, <c>SQL_PROCESSOR_PASSWORD</c>).
/// </summary>
public sealed class SqlServerSetup(IConfiguration configuration, ILoggerFactory loggerFactory) : IDatabaseSetup
{
    private readonly ILogger _logger = loggerFactory.CreateLogger<SqlServerSetup>();

    private sealed record Principal(string Name, string? ClientId, string? Password, string Permissions);

    // One statement per command: a column added by one statement can only be referenced by the next
    // once it has run.
    private static readonly string[] SchemaStatements =
    [
        """
        IF OBJECT_ID(N'dbo.Orders', N'U') IS NULL
        CREATE TABLE dbo.Orders
        (
            OrderId         UNIQUEIDENTIFIER NOT NULL PRIMARY KEY,
            CustomerId      NVARCHAR(128)    NOT NULL,
            CustomerName    NVARCHAR(256)    NOT NULL,
            LineCount       INT              NOT NULL,
            Total           DECIMAL(18, 2)   NOT NULL,
            Currency        NCHAR(3)         NOT NULL,
            LinesJson       NVARCHAR(MAX)    NOT NULL,
            PlacedAt        DATETIMEOFFSET   NOT NULL,
            ArchiveUri      NVARCHAR(1000)   NOT NULL,
            ProcessedAt     DATETIMEOFFSET   NOT NULL,
            Status          NVARCHAR(16)     NOT NULL CONSTRAINT DF_Orders_Status DEFAULT N'Processed',
            StatusReason    NVARCHAR(256)    NULL
        );
        """,
        """
        IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Orders_Customer_PlacedAt' AND object_id = OBJECT_ID(N'dbo.Orders'))
        CREATE INDEX IX_Orders_Customer_PlacedAt ON dbo.Orders (CustomerId, PlacedAt DESC);
        """,
        // Tables created before orders could be rejected: every existing order was processed.
        """
        IF COL_LENGTH(N'dbo.Orders', N'Status') IS NULL
        ALTER TABLE dbo.Orders ADD Status NVARCHAR(16) NOT NULL CONSTRAINT DF_Orders_Status DEFAULT N'Processed';
        """,
        """
        IF COL_LENGTH(N'dbo.Orders', N'StatusReason') IS NULL
        ALTER TABLE dbo.Orders ADD StatusReason NVARCHAR(256) NULL;
        """,
        """
        IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_Orders_Status' AND parent_object_id = OBJECT_ID(N'dbo.Orders'))
        ALTER TABLE dbo.Orders ADD CONSTRAINT CK_Orders_Status CHECK (Status IN (N'Processed', N'Rejected'));
        """
    ];

    public string Name => "SQL";

    public async Task RunAsync(CancellationToken cancellationToken)
    {
        var options = SqlOptions.FromConfiguration(configuration);
        var admin = DatabaseCredentialProviders.Create(configuration, "SQL_ADMIN_USERNAME", "SQL_ADMIN_PASSWORD",
            DatabaseCredentialProviders.SqlScope, defaultUserName: null, tokenNeedsUserName: false);
        var connections = new SqlConnectionFactory(options, admin, loggerFactory.CreateLogger<SqlConnectionFactory>());

        Principal[] principals =
        [
            ReadPrincipal("api", "SQL_API", "SELECT"),
            ReadPrincipal("processor", "SQL_PROCESSOR", "SELECT, INSERT, UPDATE")
        ];

        // SQL logins live in master, and a SQL Server container starts without the application
        // database. With Entra users only (Azure SQL) the database exists and master is not needed.
        var loginPrincipals = principals.Where(principal => principal.ClientId is null).ToList();
        if (admin is PasswordCredentialProvider || loginPrincipals.Count > 0)
        {
            await using var master = await ConnectionRetry.OpenAsync(
                token => connections.OpenAsync("master", token), $"SQL Server {options.Host}", _logger, cancellationToken);
            await EnsureDatabaseAsync(master, options.Database, cancellationToken);
            foreach (var principal in loginPrincipals)
            {
                await EnsureLoginAsync(master, principal, cancellationToken);
            }
        }

        await using var database = await ConnectionRetry.OpenAsync(
            connections.OpenAsync, $"SQL database {options.Database} on {options.Host}", _logger, cancellationToken);

        foreach (var statement in SchemaStatements)
        {
            await database.ExecuteAsync(new CommandDefinition(statement, cancellationToken: cancellationToken));
        }

        _logger.LogInformation("Table dbo.Orders is up to date in {Database}", options.Database);

        foreach (var principal in principals)
        {
            await EnsureUserAsync(database, principal, cancellationToken);
            await database.ExecuteAsync(new CommandDefinition(
                $"GRANT {principal.Permissions} ON dbo.Orders TO [{principal.Name}];", cancellationToken: cancellationToken));
            _logger.LogInformation("Database user {User} has {Permissions} on dbo.Orders", principal.Name, principal.Permissions);
        }
    }

    private Principal ReadPrincipal(string name, string prefix, string permissions)
    {
        var clientId = Value($"{prefix}_CLIENT_ID");
        var password = Value($"{prefix}_PASSWORD");

        if (clientId is not null)
        {
            if (!Guid.TryParse(clientId, out var parsed))
            {
                throw new InvalidOperationException($"{prefix}_CLIENT_ID is not a valid client ID.");
            }

            return new Principal(name, parsed.ToString("D"), null, permissions);
        }

        return password is not null
            ? new Principal(name, null, password, permissions)
            : throw new InvalidOperationException(
                $"No principal for '{name}': set {prefix}_CLIENT_ID (Entra) or {prefix}_PASSWORD (SQL login).");
    }

    private async Task EnsureDatabaseAsync(SqlConnection master, string databaseName, CancellationToken cancellationToken)
    {
        // The database name cannot be parameterized in CREATE DATABASE, so it is quoted instead.
        var quoted = databaseName.Replace("]", "]]", StringComparison.Ordinal);
        var created = await master.ExecuteScalarAsync<int>(new CommandDefinition(
            $"IF DB_ID(@databaseName) IS NULL BEGIN CREATE DATABASE [{quoted}]; SELECT 1; END ELSE SELECT 0;",
            new { databaseName }, cancellationToken: cancellationToken));

        _logger.LogInformation(created == 1 ? "Created database {Database}" : "Database {Database} exists", databaseName);
    }

    private async Task EnsureLoginAsync(SqlConnection master, Principal principal, CancellationToken cancellationToken)
    {
        // ALTER when it exists, so a changed (rotated) password takes effect. CREATE/ALTER LOGIN
        // take no parameters, so the statement is built on the server from a parameter: the
        // password never appears in the command text.
        await master.ExecuteAsync(new CommandDefinition(
            $"""
            DECLARE @password_literal NVARCHAR(400) = N'''' + REPLACE(@password, N'''', N'''''') + N'''';
            DECLARE @sql NVARCHAR(MAX) =
                CASE WHEN SUSER_ID(N'{principal.Name}') IS NULL THEN N'CREATE' ELSE N'ALTER' END +
                N' LOGIN [{principal.Name}] WITH PASSWORD = ' + @password_literal;
            EXEC sp_executesql @sql;
            """, new { password = principal.Password }, cancellationToken: cancellationToken));

        _logger.LogInformation("SQL login {Login} is set", principal.Name);
    }

    private static Task EnsureUserAsync(SqlConnection database, Principal principal, CancellationToken cancellationToken)
    {
        if (principal.ClientId is not null)
        {
            // A user for an Entra application or managed identity, created from its SID: the
            // client ID's bytes. FROM EXTERNAL PROVIDER would look the identity up in Microsoft
            // Graph, which needs the server to have an identity with Directory Readers, a role only
            // a tenant administrator can grant. CREATE USER takes no parameters, so the SID literal
            // is built on the server from one.
            return database.ExecuteAsync(new CommandDefinition(
                $"""
                IF DATABASE_PRINCIPAL_ID(N'{principal.Name}') IS NULL
                BEGIN
                    DECLARE @sid NVARCHAR(40) = CONVERT(NVARCHAR(40), CONVERT(VARBINARY(16), CAST(@clientId AS UNIQUEIDENTIFIER)), 1);
                    EXEC (N'CREATE USER [{principal.Name}] WITH SID = ' + @sid + N', TYPE = E;');
                END
                """, new { clientId = principal.ClientId }, cancellationToken: cancellationToken));
        }

        // Re-linking an existing user repairs it if the login was dropped and created again.
        return database.ExecuteAsync(new CommandDefinition(
            $"""
            IF DATABASE_PRINCIPAL_ID(N'{principal.Name}') IS NULL
                CREATE USER [{principal.Name}] FOR LOGIN [{principal.Name}];
            ELSE
                ALTER USER [{principal.Name}] WITH LOGIN = [{principal.Name}];
            """, cancellationToken: cancellationToken));
    }

    private string? Value(string key) => string.IsNullOrWhiteSpace(configuration[key]) ? null : configuration[key];
}
