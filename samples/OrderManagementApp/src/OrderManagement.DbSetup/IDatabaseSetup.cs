namespace OrderManagement.DbSetup;

/// <summary>
/// Brings one database to the state the services expect, as its administrator: database, schema,
/// seed data, the services' principals and their grants. Safe to run again at any time.
/// </summary>
public interface IDatabaseSetup
{
    /// <summary>For logs, for example <c>SQL</c>.</summary>
    string Name { get; }

    Task RunAsync(CancellationToken cancellationToken);
}
