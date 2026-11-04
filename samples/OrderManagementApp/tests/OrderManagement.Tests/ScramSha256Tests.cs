using System.Security.Cryptography;
using System.Text;
using OrderManagement.DbSetup;

namespace OrderManagement.Tests;

/// <summary>The SCRAM-SHA-256 verifier the database setup job gives PostgreSQL instead of the password.</summary>
public sealed class ScramSha256Tests
{
    // The exchange in RFC 7677, section 3: user "user", password "pencil".
    private const string Salt = "W22ZaJ0SNY7soEsUEjb6gQ==";
    private const string AuthMessage =
        "n=user,r=rOprNGfwEbeRWgbNEkqO," +
        "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096," +
        "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0";
    private const string ClientProof = "dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=";
    private const string ServerSignature = "6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=";

    [Fact]
    public void Matches_the_rfc_7677_exchange()
    {
        var verifier = ScramSha256.CreateVerifier("pencil", Convert.FromBase64String(Salt), 4096);

        Assert.StartsWith($"SCRAM-SHA-256$4096:{Salt}$", verifier);
        var keys = verifier.Split('$')[2].Split(':');
        var storedKey = Convert.FromBase64String(keys[0]);
        var serverKey = Convert.FromBase64String(keys[1]);

        // The server checks the client's proof against StoredKey, and signs with ServerKey.
        var clientSignature = HMACSHA256.HashData(storedKey, Encoding.UTF8.GetBytes(AuthMessage));
        var clientKey = Convert.FromBase64String(ClientProof).Zip(clientSignature, (a, b) => (byte)(a ^ b)).ToArray();
        Assert.Equal(storedKey, SHA256.HashData(clientKey));
        Assert.Equal(ServerSignature, Convert.ToBase64String(HMACSHA256.HashData(serverKey, Encoding.UTF8.GetBytes(AuthMessage))));
    }

    [Fact]
    public void Salts_every_verifier_and_never_contains_the_password()
    {
        var first = ScramSha256.CreateVerifier("Local-only-Passw0rd");
        var second = ScramSha256.CreateVerifier("Local-only-Passw0rd");

        Assert.NotEqual(first, second);
        Assert.DoesNotContain("Local-only-Passw0rd", first);
        Assert.DoesNotContain("'", first);
    }
}
