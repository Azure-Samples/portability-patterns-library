using OrderManagement.Shared.Models;

namespace OrderManagement.Tests;

/// <summary>How an order request is checked and priced from the inventory service's products.</summary>
public sealed class OrderPricingTests
{
    private static readonly Product[] Products =
    [
        new() { Sku = "GEN-500", Name = "Generator", UnitPrice = 100m, Currency = "USD", Available = 5, ReorderLevel = 1 },
        new() { Sku = "UPS-20", Name = "UPS", UnitPrice = 25.5m, Currency = "USD", Available = 0, ReorderLevel = 1 },
        new() { Sku = "EU-1", Name = "Euro part", UnitPrice = 10m, Currency = "EUR", Available = 5, ReorderLevel = 1 }
    ];

    [Fact]
    public void Prices_from_the_catalog_and_merges_lines_for_the_same_product()
    {
        var (lines, currency, errors) = OrderPricing.Price(Request(("GEN-500", 1), ("gen-500", 2), ("UPS-20", 1)), Products);

        Assert.Null(errors);
        Assert.Equal("USD", currency);
        Assert.Equal(2, lines!.Count);
        Assert.Equal(3, lines.Single(line => line.Sku == "GEN-500").Quantity);
        Assert.Equal(325.5m, lines.Sum(line => line.LineTotal));
    }

    [Fact]
    public void Leaves_stock_to_the_processor() =>
        Assert.Null(OrderPricing.Price(Request(("UPS-20", 3)), Products).Errors);

    [Theory]
    [InlineData("NOPE", 1, "items[0].sku")]
    [InlineData("GEN-500", 0, "items[0].quantity")]
    [InlineData("GEN-500", OrderPricing.MaxQuantity + 1, "items[0].quantity")]
    public void Refuses_unknown_products_and_bad_quantities(string sku, int quantity, string field) =>
        Assert.Contains(field, OrderPricing.Price(Request((sku, quantity)), Products).Errors!.Keys);

    [Fact]
    public void Refuses_more_than_the_maximum_quantity_of_one_product_across_lines() =>
        Assert.Contains("items.GEN-500",
            OrderPricing.Price(Request(("GEN-500", OrderPricing.MaxQuantity), ("GEN-500", 1)), Products).Errors!.Keys);

    [Fact]
    public void Refuses_an_empty_order_and_too_many_lines()
    {
        Assert.Contains("items", OrderPricing.Price(new OrderRequest(), Products).Errors!.Keys);
        Assert.Contains("items", OrderPricing.Price(
            Request(Enumerable.Repeat(("GEN-500", 1), OrderPricing.MaxLines + 1).ToArray()), Products).Errors!.Keys);
    }

    [Fact]
    public void Refuses_a_mix_of_currencies() =>
        Assert.Contains("items", OrderPricing.Price(Request(("GEN-500", 1), ("EU-1", 1)), Products).Errors!.Keys);

    private static OrderRequest Request(params (string Sku, int Quantity)[] items) => new()
    {
        Items = items.Select(item => new OrderRequestItem { Sku = item.Sku, Quantity = item.Quantity }).ToList()
    };
}
