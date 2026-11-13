using System.Net;
using Microsoft.Extensions.Configuration;
using OrderManagement.Api;

namespace OrderManagement.Tests.Web;

/// <summary>
/// The browser app's response headers: its pages can't be framed or cached into a sign-in response,
/// except MSAL's redirect bridge, which MSAL frames on the app's own origin for silent renewal.
/// </summary>
public sealed class BrowserAppHeadersTests(ApiAuthorizationTests.ApiFactory factory)
    : IClassFixture<ApiAuthorizationTests.ApiFactory>
{
    [Fact]
    public async Task Pages_cannot_be_framed()
    {
        var response = await factory.CreateClient().GetAsync("/");

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal("DENY", Header(response, "X-Frame-Options"));
        Assert.Contains("frame-ancestors 'none'", Header(response, "Content-Security-Policy"));
    }

    [Fact]
    public async Task The_redirect_bridge_is_framed_by_this_origin_only_and_never_stored()
    {
        var response = await factory.CreateClient().GetAsync(SpaSettings.RedirectBridgePath);

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal("SAMEORIGIN", Header(response, "X-Frame-Options"));
        Assert.Contains("frame-ancestors 'self'", Header(response, "Content-Security-Policy"));
        Assert.True(response.Headers.CacheControl?.NoStore);
    }

    [Fact]
    public void Allows_the_identity_provider_and_this_origin_in_frames_and_calls()
    {
        var configuration = new ConfigurationBuilder()
            .AddInMemoryCollection(new Dictionary<string, string?> { ["Spa:Authority"] = "https://login.microsoftonline.com/tenant-id" })
            .Build();

        var policy = SpaSettings.FromConfiguration(configuration).ContentSecurityPolicy;

        Assert.Contains("frame-src 'self' https://login.microsoftonline.com;", policy);
        Assert.Contains("connect-src 'self' https://login.microsoftonline.com;", policy);
        Assert.Contains("script-src 'self';", policy);
    }

    private static string Header(HttpResponseMessage response, string name) =>
        string.Join(",", response.Headers.TryGetValues(name, out var values) ? values : []);
}
