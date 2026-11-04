using DotNet.Testcontainers.Builders;

namespace OrderManagement.Tests.Integration;

/// <summary>
/// Integration tests run their databases in containers. Without a container engine they are skipped
/// on a developer machine, but fail in CI (<c>CI=true</c>), where they must run.
/// </summary>
internal static class ContainerEngine
{
    public static bool Required => string.Equals(Environment.GetEnvironmentVariable("CI"), "true", StringComparison.OrdinalIgnoreCase);

    /// <returns>Why the container could not start, when that is because there is no container engine and that is allowed.</returns>
    public static async Task<string?> TryStartAsync(Func<Task> start)
    {
        try
        {
            await start();
            return null;
        }
        catch (DockerUnavailableException ex) when (!Required)
        {
            return $"No container engine: {ex.Message}";
        }
    }
}
