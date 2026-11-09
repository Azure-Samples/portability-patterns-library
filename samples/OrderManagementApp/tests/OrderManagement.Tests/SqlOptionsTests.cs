using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using OrderManagement.Shared.Configuration;

namespace OrderManagement.Tests;

/// <summary>How the SQL connection's values set up TLS: the server's certificate is always verified.</summary>
public sealed class SqlOptionsTests
{
    private static readonly Dictionary<string, string?> Sql = new()
    {
        ["CONNECTION_SQL_HOST"] = "sql.ns.svc.cluster.local",
        ["CONNECTION_SQL_PORT"] = "1433",
        ["CONNECTION_SQL_DATABASE"] = "omsdb"
    };

    [Fact]
    public void Encrypts_and_verifies_the_certificate_by_default()
    {
        var builder = Read(Sql).CreateConnectionStringBuilder();

        Assert.Equal(SqlConnectionEncryptOption.Mandatory, builder.Encrypt);
        Assert.False(builder.TrustServerCertificate);
    }

    [Fact]
    public void Never_trusts_a_certificate_implicitly_even_when_tls_is_optional()
    {
        var builder = Read(new(Sql) { ["CONNECTION_SQL_TLS"] = "optional" }).CreateConnectionStringBuilder();

        Assert.Equal(SqlConnectionEncryptOption.Optional, builder.Encrypt);
        Assert.False(builder.TrustServerCertificate);
    }

    [Fact]
    public void Refuses_a_port_that_is_not_a_number() =>
        Assert.Throws<InvalidOperationException>(() => Read(new(Sql) { ["CONNECTION_SQL_PORT"] = "1433x" }));

    [Fact]
    public void Requires_a_database() =>
        Assert.Throws<OptionsValidationException>(() => Read(new(Sql) { ["CONNECTION_SQL_DATABASE"] = null }));

    private static SqlOptions Read(Dictionary<string, string?> values) =>
        OptionsReader.Read<SqlOptions>(values, services => SqlOptions.Add(services));
}
