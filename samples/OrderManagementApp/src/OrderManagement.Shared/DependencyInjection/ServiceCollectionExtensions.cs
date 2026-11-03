using OrderManagement.Shared.Configuration;
using OrderManagement.Shared.Identity;
using OrderManagement.Shared.Inventory;
using OrderManagement.Shared.Messaging;
using OrderManagement.Shared.Persistence;
using OrderManagement.Shared.Storage;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Logging;

namespace OrderManagement.Shared.DependencyInjection;

/// <summary>
/// Wires up the provider implementations chosen at runtime from the Radius-injected connection
/// values. This is the single place where "which environment am I in" is decided; nothing else in
/// the application needs to know.
/// </summary>
public static class ServiceCollectionExtensions
{
    public static IServiceCollection AddOrderQueue(this IServiceCollection services)
    {
        services.AddServiceIdentity();
        services.AddSingleton(sp => QueueOptions.FromConfiguration(sp.GetRequiredService<IConfiguration>()));

        services.AddSingleton<IMessageBroker>(sp =>
        {
            var options = sp.GetRequiredService<QueueOptions>();
            var loggerFactory = sp.GetRequiredService<ILoggerFactory>();

            return options.Provider switch
            {
                QueueProvider.ServiceBus => new ServiceBusMessageBroker(
                    options, loggerFactory.CreateLogger<ServiceBusMessageBroker>()),
                QueueProvider.RabbitMq => new RabbitMqMessageBroker(
                    options, loggerFactory.CreateLogger<RabbitMqMessageBroker>(),
                    BrokerTokenProvider(sp, options, loggerFactory)),
                _ => throw new InvalidOperationException($"Unhandled queue provider '{options.Provider}'.")
            };
        });

        services.AddSingleton<IMessagePublisher>(sp => sp.GetRequiredService<IMessageBroker>());
        services.AddSingleton<IMessageSubscriber>(sp => sp.GetRequiredService<IMessageBroker>());

        return services;
    }

    // Credentials issued by the queue Recipe win: the broker expects them. Without any, the broker
    // accepts tokens, so the pod's own identity is used, as Service Bus does with Entra on Azure.
    // With neither, the broker's default login applies, as for a local broker under `dotnet run`.
    private static WorkloadTokenProvider? BrokerTokenProvider(
        IServiceProvider services, QueueOptions options, ILoggerFactory loggerFactory)
    {
        if (options.HasCredentials) { return null; }

        var provider = services.GetService<WorkloadTokenProvider>();
        if (provider is null)
        {
            loggerFactory.CreateLogger(typeof(ServiceCollectionExtensions)).LogWarning(
                "The queue has no credentials and the pod has no workload identity " +
                "(IDENTITY_TOKEN_FILE, IDENTITY_CLIENT_ID, IDENTITY_TOKEN_ENDPOINT); " +
                "using the broker's default login.");
        }

        return provider;
    }

    /// <summary>
    /// The workload's own identity for calls to other services, from what the platform gave the pod:
    /// an Entra workload identity (<c>AZURE_CLIENT_ID</c>, <c>AZURE_FEDERATED_TOKEN_FILE</c>), a
    /// Keycloak client (<c>IDENTITY_TOKEN_FILE</c>, <c>IDENTITY_CLIENT_ID</c>,
    /// <c>IDENTITY_TOKEN_ENDPOINT</c>), or none (local compose).
    /// </summary>
    public static IServiceCollection AddServiceIdentity(this IServiceCollection services)
    {
        if (services.Any(descriptor => descriptor.ServiceType == typeof(IServiceTokenProvider)))
        {
            return services;
        }

        // The Keycloak provider is registered whenever the pod has that identity: RabbitMQ uses it
        // too, and one token carries both audiences.
        var workload = WorkloadTokenOptions.FromEnvironment();
        if (workload is not null)
        {
            services.AddSingleton(sp => new WorkloadTokenProvider(
                workload, sp.GetRequiredService<ILogger<WorkloadTokenProvider>>()));
        }

        if (AzureCredentialFactory.HasWorkloadIdentity)
        {
            services.AddSingleton<IServiceTokenProvider>(sp => new EntraServiceTokenProvider(
                AzureCredentialFactory.Create(), sp.GetRequiredService<IConfiguration>()["Inventory:Scope"]));
        }
        else if (workload is not null)
        {
            services.AddSingleton<IServiceTokenProvider>(sp => sp.GetRequiredService<WorkloadTokenProvider>());
        }
        else
        {
            services.AddSingleton<IServiceTokenProvider, NoServiceTokenProvider>();
        }

        return services;
    }

    /// <summary>The inventory service client: <c>Inventory__BaseUrl</c>, called with the workload's own token.</summary>
    public static IServiceCollection AddInventoryClient(this IServiceCollection services)
    {
        services.AddServiceIdentity();
        services.TryAddSingleton(sp => InventoryOptions.FromConfiguration(sp.GetRequiredService<IConfiguration>()));
        services.TryAddTransient<ServiceTokenHandler>();

        services.AddHttpClient<IInventoryClient, HttpInventoryClient>((sp, client) =>
            {
                client.BaseAddress = sp.GetRequiredService<InventoryOptions>().BaseUrl;
                client.Timeout = TimeSpan.FromSeconds(15);
            })
            .AddHttpMessageHandler<ServiceTokenHandler>();

        return services;
    }

    public static IServiceCollection AddOrderArchive(this IServiceCollection services)
    {
        services.AddSingleton(sp => ArchiveOptions.FromConfiguration(sp.GetRequiredService<IConfiguration>()));
        services.AddSingleton<IArchiveStore>(sp =>
        {
            var options = sp.GetRequiredService<ArchiveOptions>();
            var loggerFactory = sp.GetRequiredService<ILoggerFactory>();
            return options.Provider switch
            {
                ArchiveProvider.S3 => new S3ArchiveStore(options, loggerFactory.CreateLogger<S3ArchiveStore>()),
                _ => new BlobArchiveStore(options, loggerFactory.CreateLogger<BlobArchiveStore>())
            };
        });
        return services;
    }

    public static IServiceCollection AddOrderStore(this IServiceCollection services)
    {
        services.AddSqlConnections();
        services.AddSingleton<IOrderStore, SqlOrderStore>();
        return services;
    }

    private static void AddSqlConnections(this IServiceCollection services)
    {
        services.TryAddSingleton(sp => SqlOptions.FromConfiguration(sp.GetRequiredService<IConfiguration>()));
        services.TryAddKeyedSingleton<IDatabaseCredentialProvider>(SqlConnectionFactory.CredentialKey,
            (sp, _) => DatabaseCredentialProviders.ForSql(sp.GetRequiredService<IConfiguration>()));
        services.TryAddSingleton<SqlConnectionFactory>();
    }
}
