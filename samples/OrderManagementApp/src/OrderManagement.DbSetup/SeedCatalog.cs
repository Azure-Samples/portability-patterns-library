namespace OrderManagement.DbSetup;

/// <summary>
/// The products the inventory starts with, inserted only into an empty table so that stock changed
/// since is never reset.
/// </summary>
public static class SeedCatalog
{
    public const string Currency = "USD";
    public const int StartingStock = 25;
    public const int ReorderLevel = 5;

    public static IReadOnlyList<(string Sku, string Name, decimal UnitPrice)> Products { get; } =
    [
        ("GEN-500", "Backup generator 500 kW", 18500.00m),
        ("UPS-20", "UPS battery module 20 kVA", 2400.00m),
        ("SAT-01", "Satellite uplink terminal", 6100.00m),
        ("RAD-10", "Two-way radio kit (10 units)", 1250.00m),
        ("WAT-200", "Water purification unit", 890.00m)
    ];
}
