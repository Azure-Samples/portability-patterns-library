using Microsoft.Extensions.Diagnostics.HealthChecks;
using Microsoft.Extensions.Options;
using Npgsql;
using OrderManagement.Inventory.Data;
using OrderManagement.Inventory.Metrics;
using OrderManagement.Shared.Configuration;
using OrderManagement.Shared.DependencyInjection;
using OrderManagement.Shared.Diagnostics;
using OrderManagement.Shared.Identity;
using OrderManagement.Shared.Persistence;

namespace OrderManagement.Inventory;

public static class InventoryServiceCollectionExtensions
{
    /// <summary>
    /// The <c>inventorydb</c> PostgreSQL connection, signed in as the service's own role
    /// (<c>POSTGRES_USERNAME</c> with <c>POSTGRES_PASSWORD</c>, or an Entra ID token), and the
    /// repositories over it.
    /// </summary>
    public static IServiceCollection AddInventoryStore(this IServiceCollection services, IConfiguration configuration)
    {
        var identity = services.AddWorkloadIdentity(configuration);
        PostgresOptions.Add(services);

        var login = DatabaseLogin.Create(configuration, identity, "POSTGRES_USERNAME", "POSTGRES_PASSWORD",
            DatabaseLogin.PostgresScope, tokenNeedsUserName: true);
        services.AddSingleton(sp =>
        {
            var options = sp.GetRequiredService<IOptions<PostgresOptions>>().Value;
            sp.GetRequiredService<ILogger<PostgresProductRepository>>().LogInformation(
                "Connecting to PostgreSQL host {Host}, database {Database}, with {Login}", options.Host, options.Database, login);
            return PostgresDataSourceFactory.Create(options, login, sp.GetRequiredService<ILoggerFactory>());
        });

        services.AddSingleton<IProductRepository, PostgresProductRepository>();
        services.AddSingleton<IStockRepository, PostgresStockRepository>();

        services.AddSingleton<InventorySnapshot>();
        services.AddHostedService<InventorySnapshotRefresher>();

        services.AddHealthChecks().AddCheck<PostgresHealthCheck>(
            "inventorydb", tags: [HealthTags.Ready], timeout: TimeSpan.FromSeconds(10));

        return services;
    }
}

/// <summary>Ready when the service can open a connection to its database and run a query.</summary>
public sealed class PostgresHealthCheck(NpgsqlDataSource dataSource) : IHealthCheck
{
    public async Task<HealthCheckResult> CheckHealthAsync(HealthCheckContext context, CancellationToken cancellationToken = default)
    {
        try
        {
            await using var command = dataSource.CreateCommand("SELECT 1");
            await command.ExecuteScalarAsync(cancellationToken);
            return HealthCheckResult.Healthy();
        }
        catch (Exception ex)
        {
            return HealthCheckResult.Unhealthy("Cannot query the inventory database.", ex);
        }
    }
}
