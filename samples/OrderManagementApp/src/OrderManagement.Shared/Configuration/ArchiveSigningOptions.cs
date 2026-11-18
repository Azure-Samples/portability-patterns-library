using System.ComponentModel.DataAnnotations;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Options;
using OrderManagement.Shared.Storage;

namespace OrderManagement.Shared.Configuration;

/// <summary>
/// The key the processor signs each archived order with, from the <c>ArchiveSigning</c> section.
///
/// The key lives in Azure Key Vault. The platform delivers it as a file at <see cref="KeyPath"/>:
/// on Azure the Key Vault CSI driver mounts it, and on Azure Local the Key Vault Secret Store
/// extension copies it into a Kubernetes Secret, which keeps working when the site loses its link to
/// Azure. The application reads the same file either way.
/// </summary>
public sealed class ArchiveSigningOptions
{
    public const string SectionName = "ArchiveSigning";
    public const string DefaultKeyPath = "/var/run/secrets/archive-signing/key";

    [Required]
    public string KeyPath { get; set; } = DefaultKeyPath;

    /// <summary>How often the file is read again, so a rotated key is used without a restart.</summary>
    public TimeSpan RefreshInterval { get; set; } = TimeSpan.FromMinutes(1);

    public static OptionsBuilder<ArchiveSigningOptions> Add(IServiceCollection services) =>
        services.AddOptions<ArchiveSigningOptions>()
            .BindConfiguration(SectionName)
            .ValidateDataAnnotations()
            .Validate(options => ArchiveSigner.TryReadKey(options.KeyPath, out _),
                $"The archive signing key is missing or shorter than {ArchiveSigner.MinimumKeyLength} bytes. The platform mounts it from Key Vault at {DefaultKeyPath}; set {SectionName}__KeyPath for another path.")
            .ValidateOnStart();
}
