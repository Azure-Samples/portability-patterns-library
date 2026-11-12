using OrderManagement.Shared.Models;

namespace OrderManagement.Shared.Storage;

/// <summary>
/// Writes each consumed order to object storage as a JSON document. Writes only: the container or
/// bucket is the platform's.
/// </summary>
public interface IArchiveStore
{
    /// <returns>The absolute URI of the object that was written.</returns>
    Task<string> ArchiveAsync(Order order, CancellationToken cancellationToken);
}
