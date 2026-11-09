using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging.Abstractions;
using Npgsql;
using OrderManagement.DbSetup;
using OrderManagement.Shared.Configuration;
using OrderManagement.Shared.DependencyInjection;
using OrderManagement.Shared.Identity;
using OrderManagement.Shared.Persistence;
using Testcontainers.PostgreSql;

namespace OrderManagement.Tests.Integration;

/// <summary>
/// A PostgreSQL server set up by the database setup job, as for the inventory service: the
/// <c>inventory</c> database and the <c>inventory</c> password role.
/// </summary>
public sealed class PostgresFixture : IAsyncLifetime
{
    // The same image as the platform's (infra/azurelocal/images.txt).
    private const string Image = "docker.io/library/postgres:17.11-alpine";

    private PostgreSqlContainer? _container;

    public string? Unavailable { get; private set; }

    /// <summary>The configuration the job and the inventory service get.</summary>
    public Dictionary<string, string?> Settings { get; private set; } = [];

    public IConfiguration Configuration { get; private set; } = null!;

    /// <summary>Signed in as the server's administrator, for test data and checks.</summary>
    public NpgsqlDataSource Admin { get; private set; } = null!;

    /// <summary>Signed in as the inventory service's own role, with only its grants.</summary>
    public NpgsqlDataSource Inventory { get; private set; } = null!;

    public async Task InitializeAsync()
    {
        Unavailable = await ContainerEngine.TryStartAsync(async () =>
        {
            _container = new PostgreSqlBuilder(Image).Build();
            await _container.StartAsync();
        });
        if (Unavailable is not null)
        {
            return;
        }

        var password = $"Test-{Guid.NewGuid():N}";
        Settings = new Dictionary<string, string?>
        {
            ["CONNECTION_INVENTORYDB_HOST"] = _container!.Hostname,
            ["CONNECTION_INVENTORYDB_PORT"] = _container.GetMappedPublicPort(PostgreSqlBuilder.PostgreSqlPort).ToString(),
            ["CONNECTION_INVENTORYDB_DATABASE"] = "inventory",
            ["CONNECTION_INVENTORYDB_TLS"] = "optional",
            ["POSTGRES_ADMIN_USERNAME"] = PostgreSqlBuilder.DefaultUsername,
            ["POSTGRES_ADMIN_PASSWORD"] = PostgreSqlBuilder.DefaultPassword,
            ["INVENTORY_DB_PASSWORD"] = password,
            ["POSTGRES_USERNAME"] = PostgresSetup.Role,
            ["POSTGRES_PASSWORD"] = password
        };
        Configuration = new ConfigurationBuilder().AddInMemoryCollection(Settings).Build();

        await RunSetupAsync();

        Admin = NpgsqlDataSource.Create(new NpgsqlConnectionStringBuilder(_container.GetConnectionString()) { Database = "inventory" }.ConnectionString);
        Inventory = PostgresDataSourceFactory.Create(
            OptionsReader.Read<PostgresOptions>(Settings, services => PostgresOptions.Add(services)),
            DatabaseLogin.Create(Configuration, WorkloadIdentity.FromConfiguration(Configuration), "POSTGRES_USERNAME", "POSTGRES_PASSWORD",
                DatabaseLogin.PostgresScope, tokenNeedsUserName: true),
            NullLoggerFactory.Instance);
    }

    /// <summary>Runs the database setup job against the server.</summary>
    public async Task RunSetupAsync()
    {
        var services = new ServiceCollection().AddLogging().AddSingleton(Configuration);
        services.AddWorkloadIdentity(Configuration);
        services.AddOptions<DbSetupOptions>();
        PostgresOptions.Add(services);
        services.AddSingleton<PostgresSetup>();
        await using var provider = services.BuildServiceProvider();
        await provider.GetRequiredService<PostgresSetup>().RunAsync(CancellationToken.None);
    }

    public async Task DisposeAsync()
    {
        if (Unavailable is null)
        {
            await Admin.DisposeAsync();
            await Inventory.DisposeAsync();
        }

        if (_container is not null)
        {
            await _container.DisposeAsync();
        }
    }
}

[CollectionDefinition(Name)]
public sealed class PostgresCollection : ICollectionFixture<PostgresFixture>
{
    public const string Name = "PostgreSQL";
}
