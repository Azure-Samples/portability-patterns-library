using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Options;

namespace OrderManagement.Shared.Configuration;

public static class ConnectionOptions
{
    /// <summary>
    /// Registers options read from a Radius connection (<c>CONNECTION_&lt;NAME&gt;_*</c>, what the
    /// platform provisioned) and from a configuration section (tunables, with defaults in the options
    /// class). Validated when the host starts, so a pod with bad configuration never becomes ready.
    /// </summary>
    public static OptionsBuilder<T> AddConnectionOptions<T>(
        this IServiceCollection services, string connectionName, string sectionName, Action<T, ConnectionValues> read)
        where T : class =>
        services.AddOptions<T>()
            .BindConfiguration(sectionName)
            .Configure<IConfiguration>((options, configuration) =>
                read(options, new ConnectionValues(configuration, connectionName)))
            .ValidateDataAnnotations()
            .ValidateOnStart();
}
