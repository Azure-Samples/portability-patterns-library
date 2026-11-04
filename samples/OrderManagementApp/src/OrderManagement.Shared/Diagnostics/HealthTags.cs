namespace OrderManagement.Shared.Diagnostics;

/// <summary>
/// Tags that sort health checks into the two probes every service maps: <c>/healthz</c> (liveness)
/// runs the checks tagged <see cref="Live"/>, <c>/healthz/ready</c> (readiness) those tagged
/// <see cref="Ready"/>. A service with no liveness check is live while it answers.
/// </summary>
public static class HealthTags
{
    public const string Live = "live";
    public const string Ready = "ready";
}
