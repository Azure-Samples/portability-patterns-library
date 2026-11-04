using System.Security.Cryptography;
using System.Text;

namespace OrderManagement.DbSetup;

/// <summary>
/// A PostgreSQL SCRAM-SHA-256 password verifier (RFC 5802, RFC 7677), as <c>psql \password</c>
/// computes it: <c>SCRAM-SHA-256$&lt;iterations&gt;:&lt;salt&gt;$&lt;StoredKey&gt;:&lt;ServerKey&gt;</c>. The
/// server stores it as given and authenticates the password against it, so the password itself never
/// reaches the server, its logs or its statement history.
/// </summary>
public static class ScramSha256
{
    public const int DefaultIterations = 4096;

    public static string CreateVerifier(string password, int iterations = DefaultIterations) =>
        CreateVerifier(password, RandomNumberGenerator.GetBytes(16), iterations);

    public static string CreateVerifier(string password, byte[] salt, int iterations)
    {
        // SASLprep, which clients apply to the password, is NFKC normalization for any password that
        // isn't prohibited outright.
        var saltedPassword = Rfc2898DeriveBytes.Pbkdf2(
            Encoding.UTF8.GetBytes(password.Normalize(NormalizationForm.FormKC)), salt, iterations, HashAlgorithmName.SHA256, 32);
        var storedKey = SHA256.HashData(HMACSHA256.HashData(saltedPassword, "Client Key"u8));
        var serverKey = HMACSHA256.HashData(saltedPassword, "Server Key"u8);

        return $"SCRAM-SHA-256${iterations}:{Convert.ToBase64String(salt)}${Convert.ToBase64String(storedKey)}:{Convert.ToBase64String(serverKey)}";
    }
}
