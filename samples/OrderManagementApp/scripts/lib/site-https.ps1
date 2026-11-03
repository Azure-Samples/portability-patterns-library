# HTTPS to services on site whose certificates come from the site's own CA, which the management
# machine doesn't trust. Rather than turning certificate checks off, the client trusts that CA alone,
# read from the cluster through the authenticated kubectl connection, and still checks that the
# certificate names the address it connects to.

# An HttpClient that trusts only the CA certificate in $CaPem. Dispose it when done.
function New-OmsSiteHttpClient {
    param(
        [Parameter(Mandatory = $true)][string]$CaPem,
        [int]$TimeoutSeconds = 30
    )

    $trust = [Security.Cryptography.X509Certificates.X509Certificate2Collection]::new()
    $trust.ImportFromPem($CaPem)
    if ($trust.Count -eq 0) { throw 'The CA PEM holds no certificate.' }

    $chainPolicy = [Security.Cryptography.X509Certificates.X509ChainPolicy]::new()
    $chainPolicy.TrustMode = [Security.Cryptography.X509Certificates.X509ChainTrustMode]::CustomRootTrust
    $chainPolicy.CustomTrustStore.AddRange($trust)
    # The site CA publishes no revocation list a disconnected site could reach.
    $chainPolicy.RevocationMode = [Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck

    $handler = [Net.Http.SocketsHttpHandler]::new()
    $handler.SslOptions = [Net.Security.SslClientAuthenticationOptions]@{ CertificateChainPolicy = $chainPolicy }
    $client = [Net.Http.HttpClient]::new($handler, $true)
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
    $client
}
