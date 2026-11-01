namespace OrderManagement.Shared.Identity;

/// <summary>
/// A database credential. With <see cref="IsAccessToken"/> the secret is an Entra ID token: SQL
/// Server takes it as the connection's access token, PostgreSQL as the password.
/// </summary>
public sealed record DatabaseCredential(string? UserName, string Secret, bool IsAccessToken)
{
    // Keeps the secret out of logs and debugger displays.
    public override string ToString() =>
        $"{(IsAccessToken ? "access token" : "password")} for {UserName ?? "(token subject)"}";
}
