namespace Bcd.Shared.Models;

/// <summary>
/// Produces pseudo-random <see cref="BusinessEvent"/> instances for the demo publisher.
/// </summary>
public static class BusinessEventGenerator
{
    private static readonly string[] EventTypes =
    [
        "DatacenterFailover", "NetworkPartition", "StorageDegradation", "RegionEvacuation",
        "BackupRestoreDrill", "DependencyOutage", "CapacityBreach", "SecurityIncident"
    ];

    private static readonly string[] Regions =
    [
        "eastus", "westus2", "westeurope", "northeurope", "southeastasia", "centralindia", "australiaeast"
    ];

    private static readonly string[] BusinessUnits =
    [
        "Payments", "Trading", "Logistics", "CustomerCare", "Manufacturing", "Underwriting"
    ];

    private static readonly string[] Detectors =
    [
        "synthetic-probe", "health-model", "on-call-engineer", "customer-report", "chaos-experiment"
    ];

    public static BusinessEvent Create()
    {
        var severity = Random.Shared.Next(1, 6);

        return new BusinessEvent
        {
            EventId = Guid.NewGuid(),
            EventType = Pick(EventTypes),
            Region = Pick(Regions),
            BusinessUnit = Pick(BusinessUnits),
            Severity = severity,
            EstimatedImpactUsd = Math.Round((decimal)(Random.Shared.NextDouble() * 250_000 * severity), 2),
            DetectedBy = Pick(Detectors),
            OccurredAt = DateTimeOffset.UtcNow,
            Details = new Dictionary<string, string>
            {
                ["correlationId"] = Guid.NewGuid().ToString("N"),
                ["affectedServices"] = Random.Shared.Next(1, 25).ToString(),
                ["recoveryTimeObjectiveMinutes"] = Random.Shared.Next(5, 240).ToString(),
                ["recoveryPointObjectiveMinutes"] = Random.Shared.Next(0, 60).ToString(),
                ["automatedMitigation"] = (Random.Shared.Next(0, 2) == 1).ToString()
            }
        };
    }

    private static string Pick(string[] values) => values[Random.Shared.Next(values.Length)];
}
