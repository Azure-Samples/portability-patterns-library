using OrderManagement.Shared.Models;

namespace OrderManagement.Inventory.Data;

/// <summary>
/// What a reservation attempt came to: a result (reserved or out of stock), or the SKUs that do not
/// exist, in which case nothing was recorded.
/// </summary>
public sealed record ReservationOutcome(ReservationResult? Result, IReadOnlyList<string> UnknownSkus)
{
    public static ReservationOutcome Of(ReservationResult result) => new(result, []);

    public static ReservationOutcome Unknown(IReadOnlyList<string> skus) => new(null, skus);
}
