using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Options;
using OrderManagement.DbSetup;
using OrderManagement.Shared.Configuration;
using OrderManagement.Shared.DependencyInjection;
using OrderManagement.Shared.Identity;
using OrderManagement.Shared.Persistence;
using Testcontainers.MsSql;

namespace OrderManagement.Tests.Integration;

/// <summary>
/// A SQL Server set up by the database setup job, as for the api and the processor: the
/// <c>omsdb</c> database and their SQL logins.
/// </summary>
public sealed class SqlServerFixture : IAsyncLifetime
{
    // The same image as the platform's (infra/azurelocal/images.txt).
    private const string Image = "mcr.microsoft.com/mssql/server:2022-CU27-GDR1-ubuntu-22.04";

    private MsSqlContainer? _container;

    public string? Unavailable { get; private set; }

    public Dictionary<string, string?> Settings { get; private set; } = [];

    public async Task InitializeAsync()
    {
        Unavailable = await ContainerEngine.TryStartAsync(async () =>
        {
            _container = new MsSqlBuilder(Image).Build();
            await _container.StartAsync();
        });
        if (Unavailable is not null)
        {
            return;
        }

        Settings = new Dictionary<string, string?>
        {
            ["CONNECTION_SQL_HOST"] = _container!.Hostname,
            ["CONNECTION_SQL_PORT"] = _container.GetMappedPublicPort(MsSqlBuilder.MsSqlPort).ToString(),
            ["CONNECTION_SQL_DATABASE"] = "omsdb",
            // The test server has no certificate from a CA this machine trusts.
            ["CONNECTION_SQL_TLS"] = "optional",
            ["SQL_ADMIN_USERNAME"] = MsSqlBuilder.DefaultUsername,
            ["SQL_ADMIN_PASSWORD"] = MsSqlBuilder.DefaultPassword,
            ["SQL_API_PASSWORD"] = $"Pw1-{Guid.NewGuid():N}!",
            ["SQL_PROCESSOR_PASSWORD"] = $"Pw2-{Guid.NewGuid():N}!"
        };

        await RunSetupAsync();
    }

    /// <summary>Runs the database setup job against the server.</summary>
    public async Task RunSetupAsync()
    {
        var configuration = new ConfigurationBuilder().AddInMemoryCollection(Settings).Build();
        var services = new ServiceCollection().AddLogging().AddSingleton<IConfiguration>(configuration);
        services.AddWorkloadIdentity(configuration);
        services.AddOptions<DbSetupOptions>();
        SqlOptions.Add(services);
        services.AddSingleton<SqlServerSetup>();
        await using var provider = services.BuildServiceProvider();
        await provider.GetRequiredService<SqlServerSetup>().RunAsync(CancellationToken.None);
    }

    /// <summary>Connections as a service's own login: <c>api</c>, <c>processor</c>, or <c>sa</c>.</summary>
    public SqlConnectionFactory ConnectAs(string login)
    {
        var password = login == MsSqlBuilder.DefaultUsername ? Settings["SQL_ADMIN_PASSWORD"] : Settings[$"SQL_{login.ToUpperInvariant()}_PASSWORD"];
        var configuration = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>(Settings)
        {
            ["SQL_USERNAME"] = login,
            ["SQL_PASSWORD"] = password
        }).Build();
        return new SqlConnectionFactory(
            Options.Create(OptionsReader.Read<SqlOptions>(Settings, services => SqlOptions.Add(services))),
            DatabaseLogin.Create(configuration, WorkloadIdentity.FromConfiguration(configuration), "SQL_USERNAME", "SQL_PASSWORD",
                DatabaseLogin.SqlScope, tokenNeedsUserName: false));
    }

    public async Task<T> QueryAsAdminAsync<T>(string sql)
    {
        await using var connection = await ConnectAs(MsSqlBuilder.DefaultUsername).OpenAsync(CancellationToken.None);
        await using var command = new SqlCommand(sql, connection);
        return (T)(await command.ExecuteScalarAsync())!;
    }

    public async Task DisposeAsync()
    {
        if (_container is not null)
        {
            await _container.DisposeAsync();
        }
    }
}

[CollectionDefinition(Name)]
public sealed class SqlServerCollection : ICollectionFixture<SqlServerFixture>
{
    public const string Name = "SQL Server";
}
