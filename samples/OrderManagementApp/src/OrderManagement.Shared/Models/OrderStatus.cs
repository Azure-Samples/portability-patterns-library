namespace OrderManagement.Shared.Models;

/// <summary>How the processor completed an order, as recorded in SQL.</summary>
public static class OrderStatus
{
    public const string Processed = "Processed";
    public const string Rejected = "Rejected";

    public const string OutOfStockReason = "out of stock";
}
