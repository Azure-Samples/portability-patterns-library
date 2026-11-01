using OrderManagement.Inventory.Data;
using OrderManagement.Inventory.Metrics;
using OrderManagement.Shared.Configuration;
using OrderManagement.Shared.Identity;
using OrderManagement.Shared.Persistence;

namespace OrderManagement.Inventory;

public static class InventoryServiceCollectionExtensions
{
    private const string CredentialKey = "inventorydb";

    /// <summary>
    /// The <c>inventorydb</c> PostgreSQL connection, signed in as the service's own role
    /// (<c>POSTGRES_USERNAME</c> with <c>POSTGRES_PASSWORD</c>, or an Entra ID token), and the
    /// repositories over it.
    /// </summary>
    public static IServiceCollection AddInventoryStore(this IServiceCollection services)
    {
        services.AddSingleton(sp => PostgresOptions.FromConfiguration(sp.GetRequiredService<IConfiguration>()));
        services.AddKeyedSingleton<IDatabaseCredentialProvider>(CredentialKey,
            (sp, _) => DatabaseCredentialProviders.ForPostgres(sp.GetRequiredService<IConfiguration>()));

        services.AddSingleton(sp =>
        {
            var options = sp.GetRequiredService<PostgresOptions>();
            var credentials = sp.GetRequiredKeyedService<IDatabaseCredentialProvider>(CredentialKey);
            sp.GetRequiredService<ILogger<PostgresProductRepository>>().LogInformation(
                "Connecting to PostgreSQL host {Host}, database {Database}, with {Credential}",
                options.Host, options.Database, credentials.Description);

            return PostgresDataSourceFactory.Create(options, credentials, sp.GetRequiredService<ILoggerFactory>());
        });

        services.AddSingleton<IProductRepository, PostgresProductRepository>();
        services.AddSingleton<IStockRepository, PostgresStockRepository>();

        services.AddSingleton<InventorySnapshot>();
        services.AddHostedService<InventorySnapshotRefresher>();

        return services;
    }
}
