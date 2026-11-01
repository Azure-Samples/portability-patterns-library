using System.Net.Http.Headers;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
using System.Text.Json;
using Microsoft.Extensions.Logging;

namespace OrderManagement.Shared.Identity;

/// <summary>Settings for exchanging a Kubernetes ServiceAccount token for an access token.</summary>
public sealed class WorkloadTokenOptions
{
    /// <summary>Token endpoint of the issuer, for example <c>https://host/realms/oms/protocol/openid-connect/token</c>.</summary>
    public required string TokenEndpoint { get; init; }

    /// <summary>Client the workload authenticates as. The issuer matches it on the assertion's subject.</summary>
    public required string ClientId { get; init; }

    /// <summary>Projected ServiceAccount token, presented as the client assertion.</summary>
    public required string AssertionFile { get; init; }

    /// <summary>PEM certificate authority of the issuer, when it does not chain to a public root.</summary>
    public string? CaFile { get; init; }

    /// <summary>
    /// Reads the identity the platform gave this pod: <c>IDENTITY_TOKEN_FILE</c>,
    /// <c>IDENTITY_CLIENT_ID</c> and <c>IDENTITY_TOKEN_ENDPOINT</c>, set by the Azure Local Recipe
    /// Pack the way Entra Workload ID sets <c>AZURE_*</c> on Azure. Returns null when any is
    /// missing, so the pod has no such identity.
    /// </summary>
    public static WorkloadTokenOptions? FromEnvironment()
    {
        var tokenFile = Environment.GetEnvironmentVariable("IDENTITY_TOKEN_FILE");
        var clientId = Environment.GetEnvironmentVariable("IDENTITY_CLIENT_ID");
        var tokenEndpoint = Environment.GetEnvironmentVariable("IDENTITY_TOKEN_ENDPOINT");

        if (string.IsNullOrWhiteSpace(tokenFile) ||
            string.IsNullOrWhiteSpace(clientId) ||
            string.IsNullOrWhiteSpace(tokenEndpoint))
        {
            return null;
        }

        return new WorkloadTokenOptions
        {
            TokenEndpoint = tokenEndpoint,
            ClientId = clientId,
            AssertionFile = tokenFile
        };
    }
}

/// <summary>
/// Obtains an access token using the pod's ServiceAccount token as a client assertion, which is the
/// same federated flow Entra Workload ID uses on AKS. Nothing here is a stored credential: the
/// assertion is minted by the cluster and rotated in place by the kubelet.
///
/// One token per workload: the issuer adds every audience the workload calls (RabbitMQ and the
/// inventory service), so the queue and the inventory client share this provider.
/// </summary>
public sealed class WorkloadTokenProvider : IServiceTokenProvider, IDisposable
{
    // Renew early so a request never carries a token that expires mid-flight.
    private static readonly TimeSpan RenewBefore = TimeSpan.FromSeconds(60);

    private readonly WorkloadTokenOptions _options;
    private readonly ILogger<WorkloadTokenProvider> _logger;
    private readonly HttpClient _client;
    private readonly HttpClientHandler _handler;
    private readonly SemaphoreSlim _lock = new(1, 1);

    private string? _accessToken;
    private DateTimeOffset _expiresAt = DateTimeOffset.MinValue;

    public WorkloadTokenProvider(WorkloadTokenOptions options, ILogger<WorkloadTokenProvider> logger)
    {
        _options = options;
        _logger = logger;

        _handler = new HttpClientHandler();

        if (!string.IsNullOrWhiteSpace(options.CaFile))
        {
            var ca = X509CertificateLoader.LoadCertificateFromFile(options.CaFile);

            // Validate against the issuer's CA rather than disabling validation, so a wrong or
            // substituted certificate is still rejected.
            _handler.ServerCertificateCustomValidationCallback = (_, certificate, _, errors) =>
            {
                if (errors == SslPolicyErrors.None) { return true; }
                if (certificate is null) { return false; }

                using var chain = new X509Chain();
                chain.ChainPolicy.TrustMode = X509ChainTrustMode.CustomRootTrust;
                chain.ChainPolicy.RevocationMode = X509RevocationMode.NoCheck;
                chain.ChainPolicy.CustomTrustStore.Add(ca);
                return chain.Build(certificate);
            };
        }

        _client = new HttpClient(_handler) { Timeout = TimeSpan.FromSeconds(30) };
    }

    async Task<string?> IServiceTokenProvider.GetAccessTokenAsync(CancellationToken cancellationToken) =>
        await GetAccessTokenAsync(cancellationToken).ConfigureAwait(false);

    public async Task<string> GetAccessTokenAsync(CancellationToken cancellationToken)
    {
        if (_accessToken is not null && DateTimeOffset.UtcNow < _expiresAt - RenewBefore)
        {
            return _accessToken;
        }

        await _lock.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (_accessToken is not null && DateTimeOffset.UtcNow < _expiresAt - RenewBefore)
            {
                return _accessToken;
            }

            // Re-read every time: the kubelet replaces this file as the token approaches expiry.
            var assertion = (await File.ReadAllTextAsync(_options.AssertionFile, cancellationToken)
                .ConfigureAwait(false)).Trim();

            using var content = new FormUrlEncodedContent(new Dictionary<string, string>
            {
                ["grant_type"] = "client_credentials",
                ["client_id"] = _options.ClientId,
                ["client_assertion_type"] = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
                ["client_assertion"] = assertion
            });

            using var response = await _client.PostAsync(_options.TokenEndpoint, content, cancellationToken)
                .ConfigureAwait(false);
            var body = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);

            if (!response.IsSuccessStatusCode)
            {
                throw new InvalidOperationException(
                    $"Token request to {_options.TokenEndpoint} failed with {(int)response.StatusCode}: {body}");
            }

            using var document = JsonDocument.Parse(body);
            var token = document.RootElement.GetProperty("access_token").GetString()
                ?? throw new InvalidOperationException("The token response carried no access_token.");
            var lifetime = document.RootElement.TryGetProperty("expires_in", out var expiresIn)
                ? expiresIn.GetInt32()
                : 300;

            _accessToken = token;
            _expiresAt = DateTimeOffset.UtcNow.AddSeconds(lifetime);

            _logger.LogInformation(
                "Obtained an access token for {ClientId}, valid for {Lifetime}s", _options.ClientId, lifetime);

            return token;
        }
        finally
        {
            _lock.Release();
        }
    }

    public void Dispose()
    {
        _client.Dispose();
        _handler.Dispose();
        _lock.Dispose();
    }
}
