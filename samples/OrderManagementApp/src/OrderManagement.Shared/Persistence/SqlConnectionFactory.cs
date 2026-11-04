using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using OrderManagement.Shared.Configuration;
using OrderManagement.Shared.Identity;

namespace OrderManagement.Shared.Persistence;

/// <summary>
/// Opens connections to Azure SQL Database (Entra ID token from the workload identity) or to a SQL
/// Server container (SQL login). Shared by every SQL-backed store. The schema belongs to dbsetup; the
/// principals this opens connections as can only read and write rows.
/// </summary>
public sealed class SqlConnectionFactory
{
    private readonly SqlOptions _options;
    private readonly DatabaseLogin _login;
    private readonly SqlRetryLogicBaseProvider _openRetry;
    private readonly Func<SqlAuthenticationParameters, CancellationToken, Task<SqlAuthenticationToken>>? _tokenCallback;

    public SqlConnectionFactory(IOptions<SqlOptions> options, DatabaseLogin login)
    {
        _options = options.Value;
        _login = login;
        _openRetry = _options.CreateOpenRetryProvider();

        // One callback for the factory's lifetime: SqlClient pools connections per callback, and asks
        // it for a token only when it opens a new physical connection.
        _tokenCallback = login.UsesToken
            ? async (_, cancellationToken) =>
            {
                var token = await login.GetTokenAsync(cancellationToken).ConfigureAwait(false);
                return new SqlAuthenticationToken(token.Token, token.ExpiresOn);
            }
            : null;
    }

    public SqlOptions Options => _options;

    /// <param name="database">Another database on the same server, such as <c>master</c>; null for the application database.</param>
    public SqlConnection CreateConnection(string? database = null)
    {
        var builder = _options.CreateConnectionStringBuilder(database);
        if (!_login.UsesToken)
        {
            builder.UserID = _login.UserName;
            builder.Password = _login.Password;
        }

        return new SqlConnection(builder.ConnectionString)
        {
            AccessTokenCallback = _tokenCallback,
            RetryLogicProvider = _openRetry
        };
    }

    public Task<SqlConnection> OpenAsync(CancellationToken cancellationToken) => OpenAsync(null, cancellationToken);

    public async Task<SqlConnection> OpenAsync(string? database, CancellationToken cancellationToken)
    {
        var connection = CreateConnection(database);
        try
        {
            await connection.OpenAsync(cancellationToken).ConfigureAwait(false);
            return connection;
        }
        catch
        {
            await connection.DisposeAsync().ConfigureAwait(false);
            throw;
        }
    }
}
