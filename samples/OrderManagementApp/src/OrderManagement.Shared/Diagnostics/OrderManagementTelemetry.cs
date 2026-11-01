using System.Diagnostics;

namespace OrderManagement.Shared.Diagnostics;

/// <summary>Names of the application's own trace source and meter, shared by all services.</summary>
public static class OrderManagementTelemetry
{
    public const string Name = "OrderManagement";

    public static readonly ActivitySource ActivitySource = new(Name);
}
