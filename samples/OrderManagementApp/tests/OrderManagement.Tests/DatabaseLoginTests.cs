using Microsoft.Extensions.Configuration;
using OrderManagement.Shared.Identity;

namespace OrderManagement.Tests;

/// <summary>What a database login shows when it is logged: who signs in and how, never the secret.</summary>
public sealed class DatabaseLoginTests
{
    [Fact]
    public void Logs_a_password_login_without_the_password()
    {
        var configuration = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["SQL_USERNAME"] = "api",
            ["SQL_PASSWORD"] = "S3cret-value-123"
        }).Build();

        var login = DatabaseLogin.Create(configuration, WorkloadIdentity.FromConfiguration(configuration),
            "SQL_USERNAME", "SQL_PASSWORD", DatabaseLogin.SqlScope, tokenNeedsUserName: false);

        Assert.Equal("password login 'api'", login.ToString());
        Assert.DoesNotContain("S3cret-value-123", login.ToString());
    }
}
