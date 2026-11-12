using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Options;
using OrderManagement.Shared.DependencyInjection;

namespace OrderManagement.Tests;

/// <summary>Resolves options the way a service does at startup, from configuration as Radius injects it.</summary>
internal static class OptionsReader
{
    public static T Read<T>(Dictionary<string, string?> values, Action<IServiceCollection> register) where T : class
    {
        var configuration = new ConfigurationBuilder().AddInMemoryCollection(values).Build();
        var services = new ServiceCollection().AddSingleton<IConfiguration>(configuration);
        services.AddWorkloadIdentity(configuration);
        register(services);
        using var provider = services.BuildServiceProvider();
        return provider.GetRequiredService<IOptions<T>>().Value;
    }
}
