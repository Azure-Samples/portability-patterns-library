using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.AspNetCore.Authorization;
using Microsoft.IdentityModel.Tokens;

namespace OrderManagement.Inventory;

/// <summary>
/// App roles the calling services hold. Entra defines them on the inventory app registration and
/// assigns them to the services' managed identities; on Azure Local Keycloak issues the same names.
/// Both put them in the <c>roles</c> claim.
/// </summary>
public static class InventoryRoles
{
    public const string Read = "Inventory.Read";
    public const string Reserve = "Inventory.Reserve";
    public const string Restock = "Inventory.Restock";
}

public static class InventoryAuthentication
{
    /// <summary>
    /// Validates service tokens from the <c>InventoryAuth</c> section: <c>Authority</c> (the issuer),
    /// optional <c>MetadataAddress</c>, and <c>Audience</c>. Every endpoint needs a valid token with
    /// the role its policy names. Only in the Development environment may the authority be left out,
    /// as in local compose: then the API is open, and says so at startup.
    /// </summary>
    /// <returns>Whether callers must present a token.</returns>
    public static bool AddInventoryAuthentication(this WebApplicationBuilder builder)
    {
        var authorization = builder.Services.AddAuthorizationBuilder()
            .SetFallbackPolicy(new AuthorizationPolicyBuilder().RequireAuthenticatedUser().Build());
        foreach (var role in new[] { InventoryRoles.Read, InventoryRoles.Reserve, InventoryRoles.Restock })
        {
            authorization.AddPolicy(role, policy => policy.RequireAuthenticatedUser().RequireRole(role));
        }

        var section = builder.Configuration.GetSection("InventoryAuth");
        var authority = section["Authority"];
        if (string.IsNullOrWhiteSpace(authority))
        {
            if (!builder.Environment.IsDevelopment())
            {
                throw new InvalidOperationException(
                    "InventoryAuth__Authority is required: the inventory API accepts calls only with a service token. " +
                    "Only the Development environment may run without one.");
            }

            builder.Services.AddAuthentication();
            return false;
        }

        var audience = section["Audience"];
        if (string.IsNullOrWhiteSpace(audience))
        {
            throw new InvalidOperationException("InventoryAuth__Audience is required when InventoryAuth__Authority is set.");
        }

        var metadataAddress = section["MetadataAddress"];
        var issuer = authority.TrimEnd('/');

        builder.Services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
            .AddJwtBearer(options =>
            {
                options.Authority = authority;
                if (!string.IsNullOrWhiteSpace(metadataAddress))
                {
                    // Keycloak: tokens name the public issuer, while the service reads the
                    // signing keys from inside the cluster.
                    options.MetadataAddress = metadataAddress;
                }

                options.RequireHttpsMetadata = !(metadataAddress ?? authority)
                    .StartsWith("http://", StringComparison.OrdinalIgnoreCase);
                options.MapInboundClaims = false;
                options.TokenValidationParameters = new TokenValidationParameters
                {
                    ValidIssuers = [issuer, issuer + "/"],
                    // Entra v2 tokens carry the client ID; the api:// form covers the application ID URI.
                    ValidAudiences = [audience, $"api://{audience}"],
                    RoleClaimType = "roles",
                    NameClaimType = "sub"
                };
            });

        return true;
    }
}
