using OrderManagement.Shared.Configuration;
using OrderManagement.Shared.Identity;
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
                    CreateTokenProvider(options, loggerFactory)),
                _ => throw new InvalidOperationException($"Unhandled queue provider '{options.Provider}'.")
            };
        });

        services.AddSingleton<IMessagePublisher>(sp => sp.GetRequiredService<IMessageBroker>());
        services.AddSingleton<IMessageSubscriber>(sp => sp.GetRequiredService<IMessageBroker>());

        return services;
    }

    private static WorkloadTokenProvider? CreateTokenProvider(
        QueueOptions options, ILoggerFactory loggerFactory)
    {
        if (!options.UseOAuth) { return null; }

        return new WorkloadTokenProvider(
            new WorkloadTokenOptions
            {
                TokenEndpoint = options.OAuthTokenEndpoint!,
                ClientId = options.OAuthClientId!,
                AssertionFile = options.OAuthAssertionFile!,
                CaFile = options.OAuthCaFile
            },
            loggerFactory.CreateLogger<WorkloadTokenProvider>());
    }

    public static IServiceCollection AddOrderArchive(this IServiceCollection services)
    {
        services.AddSingleton(sp => ArchiveOptions.FromConfiguration(sp.GetRequiredService<IConfiguration>()));
        services.AddSingleton<IArchiveStore, BlobArchiveStore>();
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
        services.TryAddSingleton<SqlConnectionFactory>();
    }
}
