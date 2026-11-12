using System.Security.Claims;
using System.Text.Encodings.Web;
using Microsoft.AspNetCore.Authentication;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace OrderManagement.Tests.Web;

/// <summary>
/// Signs the caller in from the test's own <c>Authorization: Test</c> header, so the API's policies
/// can be checked without an identity provider: <c>Test sub=user-1;roles=Orders.Read;scp=access_as_user</c>.
/// </summary>
public sealed class TestAuthenticationHandler(
    IOptionsMonitor<AuthenticationSchemeOptions> options, ILoggerFactory logger, UrlEncoder encoder)
    : AuthenticationHandler<AuthenticationSchemeOptions>(options, logger, encoder)
{
    public const string SchemeName = "Test";

    public static string Header(string? sub = "user-1", string roles = "", string scp = "access_as_user") =>
        $"{SchemeName} sub={sub};roles={roles};scp={scp}";

    protected override Task<AuthenticateResult> HandleAuthenticateAsync()
    {
        var header = Request.Headers.Authorization.ToString();
        if (!header.StartsWith(SchemeName + " ", StringComparison.Ordinal))
        {
            return Task.FromResult(AuthenticateResult.NoResult());
        }

        var claims = new List<Claim>();
        foreach (var part in header[(SchemeName.Length + 1)..].Split(';', StringSplitOptions.RemoveEmptyEntries))
        {
            var (name, value) = (part[..part.IndexOf('=')], part[(part.IndexOf('=') + 1)..]);
            claims.AddRange(name == "roles"
                ? value.Split(',', StringSplitOptions.RemoveEmptyEntries).Select(role => new Claim("roles", role))
                : string.IsNullOrEmpty(value) ? [] : [new Claim(name, value)]);
        }

        var identity = new ClaimsIdentity(claims, SchemeName, "name", "roles");
        return Task.FromResult(AuthenticateResult.Success(new AuthenticationTicket(new ClaimsPrincipal(identity), SchemeName)));
    }
}
