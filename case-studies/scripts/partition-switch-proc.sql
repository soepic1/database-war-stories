CREATE OR ALTER PROCEDURE dbo.usp_ArchiveTransfers_PartitionSwitch
    @MaxDmsLagMinutes        INT = 60,
    @MaxPartitionsPerRun     INT = 10,
    @ExplicitPartitionNumber INT = NULL,
    @DebugPrint              BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @run_id UNIQUEIDENTIFIER = NEWID();
    DECLARE @PartitionNumber INT, @BoundaryValue DATETIME2(7);
    DECLARE @ArchiveRows BIGINT, @SourceRows BIGINT;
    DECLARE @log_id BIGINT, @ProcessedCount INT = 0, @ErrMsg NVARCHAR(4000);
    DECLARE @LastPartitionNo INT;
    DECLARE @SingleShot BIT = CASE WHEN @ExplicitPartitionNumber IS NOT NULL THEN 1 ELSE 0 END;

    SELECT @LastPartitionNo = fanout FROM sys.partition_functions WHERE name = 'PF_Transfers_CreatedDay';

    WHILE @ProcessedCount < @MaxPartitionsPerRun
    BEGIN
        SET @PartitionNumber = NULL; SET @BoundaryValue = NULL;

        IF @ExplicitPartitionNumber IS NOT NULL
        BEGIN
            SELECT @PartitionNumber = p.partition_number, @SourceRows = p.rows
            FROM sys.partitions p
            JOIN sys.indexes i ON i.object_id = p.object_id AND i.index_id = p.index_id
            WHERE p.object_id = OBJECT_ID('dbo.Transfers') AND i.index_id = 1
              AND p.partition_number = @ExplicitPartitionNumber;
        END
        ELSE
        BEGIN
            SELECT TOP 1 @PartitionNumber = p.partition_number, @SourceRows = p.rows
            FROM sys.partitions p
            JOIN sys.indexes i ON i.object_id = p.object_id AND i.index_id = p.index_id
            WHERE p.object_id = OBJECT_ID('dbo.Transfers') AND i.index_id = 1 AND p.rows > 0
            ORDER BY p.partition_number ASC;
        END

        IF @PartitionNumber IS NULL OR ISNULL(@SourceRows,0) = 0
        BEGIN
            IF @DebugPrint = 1 PRINT 'Nothing to switch.';
            BREAK;
        END

        IF @PartitionNumber = @LastPartitionNo
        BEGIN
            IF @DebugPrint = 1 PRINT 'That is the open-ended future partition - cannot switch it.';
            BREAK;
        END

        SELECT @BoundaryValue = CONVERT(DATETIME2(7), prv.value)
        FROM sys.partition_range_values prv
        JOIN sys.partition_functions pf ON pf.function_id = prv.function_id
        WHERE pf.name = 'PF_Transfers_CreatedDay' AND prv.boundary_id = @PartitionNumber;

        IF @BoundaryValue IS NULL OR SYSUTCDATETIME() < DATEADD(MINUTE, @MaxDmsLagMinutes, @BoundaryValue)
        BEGIN
            IF @DebugPrint = 1 PRINT CONCAT('Partition ', @PartitionNumber, ' not safely closed yet.');
            BREAK;
        END

        SELECT @ArchiveRows = p.rows
        FROM sys.partitions p
        JOIN sys.indexes i ON i.object_id = p.object_id AND i.index_id = p.index_id
        WHERE p.object_id = OBJECT_ID('dbo.Transfers_Archive') AND i.index_id = 1
          AND p.partition_number = @PartitionNumber;

        IF ISNULL(@ArchiveRows,0) > 0
        BEGIN
            IF @DebugPrint = 1 PRINT CONCAT('BLOCKED: partition ', @PartitionNumber, ' target not empty (', @ArchiveRows, ' rows). Needs manual remediation.');
            BREAK;
        END

        BEGIN TRY
            ALTER TABLE dbo.Transfers SWITCH PARTITION @PartitionNumber TO dbo.Transfers_Archive PARTITION @PartitionNumber;
            IF @DebugPrint = 1 PRINT CONCAT('SWITCHED partition ', @PartitionNumber, ' (', @SourceRows, ' rows).');
        END TRY
        BEGIN CATCH
            SET @ErrMsg = ERROR_MESSAGE();
            IF @DebugPrint = 1 PRINT CONCAT('FAILED partition ', @PartitionNumber, ': ', @ErrMsg);
            BREAK;
        END CATCH

        SET @ProcessedCount += 1;
        IF @SingleShot = 1 BREAK;
    END
END
