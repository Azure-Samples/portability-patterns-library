using System.Security.Claims;
using Microsoft.Identity.Web;

namespace OrderManagement.Api;

/// <summary>
/// App roles and the delegated scope. Entra defines them on the API app registration; on Azure
/// Local the platform makes Keycloak issue the same names, mapped from Active Directory groups.
/// </summary>
public static class OrderRoles
{
    public const string Read = "Orders.Read";
    public const string Create = "Orders.Create";
    public const string ManageInventory = "Inventory.Manage";
    public const string ApiScope = "access_as_user";
}

public static class OrderPolicies
{
    public const string Read = "Orders.Read";
    public const string Create = "Orders.Create";
    public const string ManageInventory = "Inventory.Manage";
}

public static class UserIdentity
{
    /// <summary>Stable, opaque per-user key: Entra's <c>oid</c>, falling back to <c>sub</c>. Safe to log.</summary>
    public static string CustomerId(ClaimsPrincipal user) =>
        user.GetObjectId()
        ?? user.FindFirstValue("sub")
        ?? user.FindFirstValue(ClaimTypes.NameIdentifier)
        ?? throw new MissingUserIdentifierException();

    /// <summary>The user's name or e-mail address, shown to the user and stored with the order. Never logged.</summary>
    public static string DisplayName(ClaimsPrincipal user) =>
        user.FindFirstValue("preferred_username")
        ?? user.FindFirstValue("name")
        ?? CustomerId(user);

    public static IReadOnlyList<string> Roles(ClaimsPrincipal user) =>
        user.FindAll("roles").Concat(user.FindAll(ClaimTypes.Role))
            .Select(claim => claim.Value)
            .Distinct(StringComparer.Ordinal)
            .ToList();
}
