namespace OrderManagement.Shared.Inventory;

/// <summary>
/// The inventory service could not be reached, timed out or failed (5xx). Transient: the same call
/// may succeed shortly.
/// </summary>
public sealed class InventoryUnavailableException(string message, Exception? innerException = null)
    : Exception(message, innerException);
