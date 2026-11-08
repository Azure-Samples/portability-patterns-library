using Duende.AccessTokenManagement;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Diagnostics.HealthChecks;
using Microsoft.Extensions.Http.Resilience;
using Microsoft.Extensions.Options;
using OrderManagement.Shared.Configuration;
using OrderManagement.Shared.Diagnostics;
using OrderManagement.Shared.Identity;
using OrderManagement.Shared.Inventory;
using OrderManagement.Shared.Messaging;
using OrderManagement.Shared.Persistence;
using OrderManagement.Shared.Storage;
using RabbitMQ.Client;

namespace OrderManagement.Shared.DependencyInjection;

/// <summary>
/// Wires up the provider implementations chosen from the Radius-injected connection values and the
/// pod's workload identity. This is the single place where "which environment am I in" is decided;
/// nothing else in the application needs to know.
/// </summary>
public static class ServiceCollectionExtensions
{
    private static readonly TimeSpan HealthCheckTimeout = TimeSpan.FromSeconds(10);

    /// <summary>
    /// The workload identity the platform gave the pod (<see cref="WorkloadIdentity"/>). With a
    /// Keycloak identity, Duende.AccessTokenManagement requests, caches and renews its token, with the
    /// ServiceAccount token as the client assertion.
    /// </summary>
    public static WorkloadIdentity AddWorkloadIdentity(this IServiceCollection services, IConfiguration configuration)
    {
        if (services.FirstOrDefault(service => service.ServiceType == typeof(WorkloadIdentity))?.ImplementationInstance
            is WorkloadIdentity registered)
        {
            return registered;
        }

        var identity = WorkloadIdentity.FromConfiguration(configuration);
        services.AddSingleton(identity);

        if (identity.Keycloak is { } keycloak)
        {
            services.AddSingleton(keycloak);
            services.AddTransient<IClientAssertionService, ServiceAccountTokenAssertion>();
            services.AddClientCredentialsTokenManagement()
                .AddClient(KeycloakWorkloadIdentity.ClientName, client =>
                {
                    client.TokenEndpoint = keycloak.TokenEndpoint;
                    client.ClientId = ClientId.Parse(keycloak.ClientId);
                });
        }

        return identity;
    }

    public static IServiceCollection AddOrderQueue(this IServiceCollection services, IConfiguration configuration)
    {
        var identity = services.AddWorkloadIdentity(configuration);
        QueueOptions.Add(services);

        if (identity.Keycloak is not null)
        {
            services.TryAddSingleton<ICredentialsProvider, KeycloakCredentialsProvider>();
        }

        services.AddSingleton<IMessageQueue>(sp => sp.GetRequiredService<IOptions<QueueOptions>>().Value.Provider switch
        {
            QueueProvider.ServiceBus => ActivatorUtilities.CreateInstance<ServiceBusMessageBroker>(sp),
            _ => ActivatorUtilities.CreateInstance<RabbitMqMessageBroker>(sp)
        });

        services.AddHealthChecks().Add(new HealthCheckRegistration(
            "queue", sp => sp.GetRequiredService<IMessageQueue>(), failureStatus: null, tags: [HealthTags.Ready], HealthCheckTimeout));

        return services;
    }

    /// <summary>
    /// The inventory service client, called with the workload's own token. Retries, timeouts and the
    /// circuit breaker come from the standard resilience handler, tuned in <c>Inventory:Resilience</c>.
    /// </summary>
    public static IServiceCollection AddInventoryClient(this IServiceCollection services, IConfiguration configuration)
    {
        var identity = services.AddWorkloadIdentity(configuration);
        InventoryOptions.Add(services);

        // The resilience handler's timeouts end when the response headers arrive; HttpClient reads
        // the body afterwards. The same total limit on the HttpClient covers the body too, so an
        // answer that stalls halfway can't hold a caller (on RabbitMQ, the processor's only delivery).
        var resilience = new HttpStandardResilienceOptions();
        configuration.GetSection($"{InventoryOptions.SectionName}:Resilience").Bind(resilience);
        var totalTimeout = resilience.TotalRequestTimeout.Timeout;

        var client = services.AddHttpClient<IInventoryClient, HttpInventoryClient>((sp, http) =>
            http.BaseAddress = sp.GetRequiredService<IOptions<InventoryOptions>>().Value.BaseUrl);

        // Outermost, so each attempt gets a current token. Restocking adds stock each time it is
        // sent, so a POST is never repeated; reserving is repeated by the processor, which can.
        client.AddStandardResilienceHandler(options =>
        {
            configuration.GetSection($"{InventoryOptions.SectionName}:Resilience").Bind(options);
            options.Retry.DisableFor(HttpMethod.Post);
        });
        // After the resilience handler, which turns the HttpClient's timeout off.
        client.ConfigureHttpClient(http => http.Timeout = totalTimeout);

        if (identity.Entra is { } entra)
        {
            client.AddHttpMessageHandler(sp =>
                new EntraTokenHandler(entra.Credential, sp.GetRequiredService<IOptions<InventoryOptions>>().Value.Scope!));
        }
        else if (identity.Keycloak is not null)
        {
            client.AddHttpMessageHandler(sp => new KeycloakTokenHandler(sp.GetRequiredService<IClientCredentialsTokenManager>()));
        }

        return services;
    }

    /// <summary>
    /// Object storage: a blob container with the workload identity, or an S3 bucket with the keys the
    /// platform issued, as the environment's <c>Archive__Provider</c> says. The S3 bucket is created
    /// once at startup when it doesn't exist.
    /// </summary>
    public static IServiceCollection AddOrderArchive(this IServiceCollection services, IConfiguration configuration)
    {
        services.AddWorkloadIdentity(configuration);
        ArchiveOptions.Add(services);

        switch (configuration.GetValue<ArchiveProvider?>($"{ArchiveOptions.SectionName}:Provider"))
        {
            case ArchiveProvider.S3:
                services.AddSingleton<S3ArchiveStore>();
                services.AddSingleton<IArchiveStore>(sp => sp.GetRequiredService<S3ArchiveStore>());
                services.AddHostedService<S3BucketInitializer>();
                break;
            case ArchiveProvider.AzureBlob:
                services.AddSingleton<IArchiveStore, BlobArchiveStore>();
                break;
            default:
                throw new InvalidOperationException(
                    $"Set {ArchiveOptions.SectionName}__Provider to AzureBlob or S3: which object store backs the archive connection is the environment's choice.");
        }

        return services;
    }

    /// <summary>
    /// The orders database, signed in as the service's own principal: <c>SQL_USERNAME</c> with
    /// <c>SQL_PASSWORD</c>, or the pod's Entra workload identity.
    /// </summary>
    public static IServiceCollection AddOrderStore(this IServiceCollection services, IConfiguration configuration)
    {
        var identity = services.AddWorkloadIdentity(configuration);
        SqlOptions.Add(services);

        var login = DatabaseLogin.Create(configuration, identity, "SQL_USERNAME", "SQL_PASSWORD",
            DatabaseLogin.SqlScope, tokenNeedsUserName: false);
        services.AddSingleton(sp => new SqlConnectionFactory(sp.GetRequiredService<IOptions<SqlOptions>>(), login));
        services.AddSingleton<IOrderStore, SqlOrderStore>();

        services.AddHealthChecks().Add(new HealthCheckRegistration(
            "sql", sp => ActivatorUtilities.CreateInstance<SqlHealthCheck>(sp), failureStatus: null, tags: [HealthTags.Ready], HealthCheckTimeout));

        return services;
    }
}
