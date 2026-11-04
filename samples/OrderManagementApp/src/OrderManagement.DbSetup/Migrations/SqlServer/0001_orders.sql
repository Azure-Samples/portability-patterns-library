-- The orders database. The processor records each order once, as processed or rejected; the API
-- reads a customer's orders newest first.
CREATE TABLE dbo.Orders
(
    OrderId         UNIQUEIDENTIFIER NOT NULL CONSTRAINT PK_Orders PRIMARY KEY,
    CustomerId      NVARCHAR(128)    NOT NULL,
    CustomerName    NVARCHAR(256)    NOT NULL,
    LineCount       INT              NOT NULL,
    Total           DECIMAL(18, 2)   NOT NULL,
    Currency        NCHAR(3)         NOT NULL,
    LinesJson       NVARCHAR(MAX)    NOT NULL,
    PlacedAt        DATETIMEOFFSET   NOT NULL,
    ArchiveUri      NVARCHAR(1000)   NOT NULL,
    ProcessedAt     DATETIMEOFFSET   NOT NULL,
    Status          NVARCHAR(16)     NOT NULL CONSTRAINT DF_Orders_Status DEFAULT N'Processed',
    StatusReason    NVARCHAR(256)    NULL,
    CONSTRAINT CK_Orders_Status CHECK (Status IN (N'Processed', N'Rejected'))
);

CREATE INDEX IX_Orders_Customer_PlacedAt ON dbo.Orders (CustomerId, PlacedAt DESC);
