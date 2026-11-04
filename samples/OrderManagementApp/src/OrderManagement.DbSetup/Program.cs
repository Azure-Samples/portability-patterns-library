using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using OrderManagement.DbSetup;
using OrderManagement.Shared.Configuration;
using OrderManagement.Shared.DependencyInjection;
using OrderManagement.Shared.Diagnostics;

// One-shot job, run before the services start: creates the databases, applies their migrations
// (Migrations/, with DbUp) and grants each service its least-privilege principal. Each database is
// set up only when its connection is given, so the job can serve SQL, PostgreSQL or both.
var builder = Host.CreateApplicationBuilder(args);
builder.Logging.AddSimpleConsole(options => options.SingleLine = true);
// Npgsql logs every command at Information; this job's own messages say what it did.
builder.Logging.AddFilter("Npgsql", LogLevel.Warning);

builder.Services.AddWorkloadIdentity(builder.Configuration);
builder.Services.AddOptions<DbSetupOptions>().BindConfiguration(DbSetupOptions.SectionName);

if (!string.IsNullOrWhiteSpace(builder.Configuration["CONNECTION_SQL_HOST"]))
{
    SqlOptions.Add(builder.Services);
    builder.Services.AddSingleton<SqlServerSetup>();
}

if (!string.IsNullOrWhiteSpace(builder.Configuration["CONNECTION_INVENTORYDB_HOST"]))
{
    PostgresOptions.Add(builder.Services);
    builder.Services.AddSingleton<PostgresSetup>();
}

using var host = builder.Build();
var logger = host.Services.GetRequiredService<ILoggerFactory>().CreateLogger("OrderManagement.DbSetup");

var sql = host.Services.GetService<SqlServerSetup>();
var postgres = host.Services.GetService<PostgresSetup>();
if (sql is null && postgres is null)
{
    logger.LogError("Nothing to set up: neither CONNECTION_SQL_HOST nor CONNECTION_INVENTORYDB_HOST is set");
    return 2;
}

using var cancellation = new CancellationTokenSource();
Console.CancelKeyPress += (_, args) =>
{
    args.Cancel = true;
    cancellation.Cancel();
};

try
{
    if (sql is not null)
    {
        await sql.RunAsync(cancellation.Token);
        logger.LogInformation("SQL setup complete");
    }

    if (postgres is not null)
    {
        await postgres.RunAsync(cancellation.Token);
        logger.LogInformation("PostgreSQL setup complete");
    }
}
catch (Exception ex)
{
    logger.LogError(ex, "Database setup failed: {Reason}", ExceptionSummary.Describe(ex));
    return 1;
}

return 0;
