using Bcd.Shared.Models;
using Dapper;

namespace Bcd.Shared.Persistence;

/// <summary>Records each consumed event in SQL Server.</summary>
public interface IEventRecordStore
{
    Task InitializeAsync(CancellationToken cancellationToken);

    Task RecordAsync(BusinessEvent businessEvent, string archiveUri, CancellationToken cancellationToken);
}

/// <summary>
/// SQL Server implementation that targets both a containerized SQL Server (SQL login) and Azure SQL
/// Database (Entra ID access token obtained through Workload Identity).
/// </summary>
public sealed class SqlEventRecordStore(SqlConnectionFactory connections) : IEventRecordStore
{
    private const string CreateTableSql = """
        IF OBJECT_ID(N'dbo.BusinessEvents', N'U') IS NULL
        BEGIN
            CREATE TABLE dbo.BusinessEvents
            (
                EventId                 UNIQUEIDENTIFIER NOT NULL PRIMARY KEY,
                EventType               NVARCHAR(100)    NOT NULL,
                Region                  NVARCHAR(50)     NOT NULL,
                BusinessUnit            NVARCHAR(100)    NOT NULL,
                Severity                INT              NOT NULL,
                EstimatedImpactUsd      DECIMAL(18, 2)   NOT NULL,
                DetectedBy              NVARCHAR(100)    NOT NULL,
                OccurredAt              DATETIMEOFFSET   NOT NULL,
                ArchiveUri              NVARCHAR(1000)   NOT NULL,
                ProcessedAt             DATETIMEOFFSET   NOT NULL
            );

            CREATE INDEX IX_BusinessEvents_OccurredAt ON dbo.BusinessEvents (OccurredAt DESC);
        END
        """;

    public Task InitializeAsync(CancellationToken cancellationToken) =>
        connections.EnsureSchemaAsync(CreateTableSql, "business events", cancellationToken);

    private const string UpsertSql = """
        MERGE dbo.BusinessEvents AS target
        USING (SELECT @EventId AS EventId) AS source
        ON target.EventId = source.EventId
        WHEN NOT MATCHED THEN
            INSERT (EventId, EventType, Region, BusinessUnit, Severity, EstimatedImpactUsd,
                    DetectedBy, OccurredAt, ArchiveUri, ProcessedAt)
            VALUES (@EventId, @EventType, @Region, @BusinessUnit, @Severity, @EstimatedImpactUsd,
                    @DetectedBy, @OccurredAt, @ArchiveUri, @ProcessedAt);
        """;

    public async Task RecordAsync(BusinessEvent businessEvent, string archiveUri, CancellationToken cancellationToken)
    {
        await using var connection = await connections.OpenAsync(cancellationToken).ConfigureAwait(false);

        // MERGE keeps the consumer idempotent: queue redelivery must not create duplicate rows.
        await connection.ExecuteAsync(new CommandDefinition(UpsertSql, new
        {
            businessEvent.EventId,
            businessEvent.EventType,
            businessEvent.Region,
            businessEvent.BusinessUnit,
            businessEvent.Severity,
            businessEvent.EstimatedImpactUsd,
            businessEvent.DetectedBy,
            businessEvent.OccurredAt,
            ArchiveUri = archiveUri,
            ProcessedAt = DateTimeOffset.UtcNow
        }, cancellationToken: cancellationToken)).ConfigureAwait(false);
    }
}
