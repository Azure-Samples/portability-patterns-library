namespace OrderManagement.Api;

/// <summary>
/// Settings the browser app needs at runtime, from the <c>Spa</c> configuration section. Only the
/// values differ between Entra ID (<c>ProtocolMode=AAD</c>) and Keycloak (<c>ProtocolMode=OIDC</c>).
/// </summary>
public sealed class SpaSettings
{
    public required object ClientConfiguration { get; init; }

    public required string ContentSecurityPolicy { get; init; }

    public static SpaSettings FromConfiguration(IConfiguration configuration)
    {
        var section = configuration.GetSection("Spa");
        var authority = section["Authority"];

        var knownAuthorities = (section["KnownAuthorities"] ?? string.Empty)
            .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);

        // The browser talks to the identity provider directly (discovery, token endpoint and the
        // hidden iframe MSAL uses for silent renewal), so only that origin is allowed besides self.
        var identityOrigin = Uri.TryCreate(authority, UriKind.Absolute, out var authorityUri)
            ? authorityUri.GetLeftPart(UriPartial.Authority)
            : null;
        var external = identityOrigin is null ? string.Empty : $" {identityOrigin}";

        return new SpaSettings
        {
            ClientConfiguration = new
            {
                authority,
                clientId = section["ClientId"],
                protocolMode = section["ProtocolMode"] ?? "AAD",
                knownAuthorities,
                apiScope = section["ApiScope"],
                identityProvider = section["IdentityProvider"] ?? "Microsoft Entra ID",
                environment = section["Environment"] ?? string.Empty
            },
            ContentSecurityPolicy =
                "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; " +
                $"connect-src 'self'{external}; frame-src{(identityOrigin is null ? " 'none'" : external)}; " +
                "object-src 'none'; base-uri 'self'; frame-ancestors 'none'"
        };
    }
}
