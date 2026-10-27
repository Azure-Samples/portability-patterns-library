using OrderManagement.Shared.Models;

namespace OrderManagement.Shared.Storage;

/// <summary>Writes each consumed order to object storage as a JSON blob.</summary>
public interface IArchiveStore
{
    Task InitializeAsync(CancellationToken cancellationToken);

    /// <returns>The absolute URI of the blob that was written.</returns>
    Task<string> ArchiveAsync(Order order, CancellationToken cancellationToken);
}
