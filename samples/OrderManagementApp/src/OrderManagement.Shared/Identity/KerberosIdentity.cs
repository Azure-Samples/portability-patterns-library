namespace OrderManagement.Shared.Identity;

/// <summary>
/// Detects a Kerberos identity attached to the pod by the platform.
///
/// On Azure Local the container Recipe mounts a client keytab for the application's Active
/// Directory account and sets <c>KRB5_CLIENT_KTNAME</c>. MIT Kerberos then obtains and renews tickets
/// from that keytab on its own, so SQL Server accepts the application with integrated authentication
/// and no password. The directory runs on site, so this keeps working without Azure.
/// </summary>
public static class KerberosIdentity
{
    /// <summary>True when the platform attached a Kerberos client keytab to this pod.</summary>
    public static bool IsAvailable
    {
        get
        {
            var keytab = Environment.GetEnvironmentVariable("KRB5_CLIENT_KTNAME");
            if (string.IsNullOrWhiteSpace(keytab))
            {
                return false;
            }

            var path = keytab.StartsWith("FILE:", StringComparison.Ordinal) ? keytab[5..] : keytab;
            return File.Exists(path);
        }
    }
}
