USE [monitoring]
GO

/****** Object:  Table [dbo].[PerformanceLog]    Script Date: 7/17/2026 10:19:25 PM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE TABLE [dbo].[PerformanceLog](
	[log_id] [bigint] IDENTITY(1,1) NOT NULL,
	[snapshot_time] [datetime2](7) NOT NULL,
	[monitored_db] [varchar](100) NOT NULL,
	[metric_category] [varchar](50) NOT NULL,
	[metric_name] [varchar](100) NOT NULL,
	[metric_value] [bigint] NULL,
	[metric_value_decimal] [decimal](18, 4) NULL,
	[metric_text] [nvarchar](max) NULL,
	[session_id] [int] NULL,
	[sql_text] [nvarchar](max) NULL,
	[query_plan] [xml] NULL,
	[program_name] [nvarchar](200) NULL,
	[host_name] [nvarchar](200) NULL,
	[login_name] [nvarchar](200) NULL,
	[database_name] [nvarchar](200) NULL,
	[extra_json] [nvarchar](max) NULL,
 CONSTRAINT [PK_PerformanceLog] PRIMARY KEY CLUSTERED 
(
	[log_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]
GO

ALTER TABLE [dbo].[PerformanceLog] ADD  CONSTRAINT [DF_PerformanceLog_snapshot_time]  DEFAULT (sysdatetime()) FOR [snapshot_time]
GO


USE [monitoring]
GO

/****** Object:  StoredProcedure [dbo].[usp_CapturePerformanceSnapshot]    Script Date: 7/17/2026 10:20:31 PM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE   PROCEDURE [dbo].[usp_CapturePerformanceSnapshot]
    @TargetDatabase NVARCHAR(128) = N'AccountSwitch'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @snapshot_time DATETIME2 = SYSDATETIME();
    DECLARE @TargetDBId INT = DB_ID(@TargetDatabase);
    IF @TargetDBId IS NULL RETURN;

    DECLARE @long_threshold_sec INT =
        (SELECT CAST(config_value AS INT) FROM dbo.AlertConfig WHERE config_key='long_query_threshold_sec');

    ---------- 1. live long-running queries ----------
    INSERT INTO dbo.PerformanceLog
        (snapshot_time, monitored_db, metric_category, metric_name, metric_value, metric_value_decimal,
         session_id, sql_text, program_name, host_name, login_name, database_name, extra_json)
    SELECT @snapshot_time, @TargetDatabase, 'long_running_query', 'elapsed_seconds',
           DATEDIFF(SECOND, r.start_time, GETDATE()), r.logical_reads/1.0, r.session_id,
           SUBSTRING(t.text, r.statement_start_offset/2+1,
               ((CASE r.statement_end_offset WHEN -1 THEN DATALENGTH(t.text)
                   ELSE r.statement_end_offset END - r.statement_start_offset)/2)+1),
           s.program_name, s.host_name, s.login_name, DB_NAME(r.database_id),
           '{"wait_type":"'+ISNULL(r.wait_type,'')+'","cpu_time_ms":'+CAST(r.cpu_time AS VARCHAR)
           +',"blocking_session_id":'+CAST(ISNULL(r.blocking_session_id,0) AS VARCHAR)+'}'
    FROM sys.dm_exec_requests r
    JOIN sys.dm_exec_sessions s ON r.session_id=s.session_id
    CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) t
    WHERE s.is_user_process=1 AND r.database_id=@TargetDBId
      AND DATEDIFF(SECOND, r.start_time, GETDATE()) >= @long_threshold_sec
      AND s.program_name NOT LIKE '%DMS%' AND s.program_name NOT LIKE '%AWS%'
      AND s.program_name NOT LIKE '%SQLAgent%' AND s.program_name NOT LIKE '%Management Studio%'
      AND ISNULL(r.wait_type,'')<>'WAITFOR' AND t.text NOT LIKE '%sp_MScdc%' AND t.text NOT LIKE '%fn_dblog%';

    ---------- 2. blocking ----------
    INSERT INTO dbo.PerformanceLog
        (snapshot_time, monitored_db, metric_category, metric_name, metric_value,
         session_id, sql_text, program_name, host_name, login_name, extra_json)
    SELECT @snapshot_time, @TargetDatabase, 'blocking', 'wait_seconds', r.wait_time/1000, r.session_id,
           SUBSTRING(t.text, r.statement_start_offset/2+1,
               ((CASE r.statement_end_offset WHEN -1 THEN DATALENGTH(t.text)
                   ELSE r.statement_end_offset END - r.statement_start_offset)/2)+1),
           s.program_name, s.host_name, s.login_name,
           '{"blocking_session_id":'+CAST(r.blocking_session_id AS VARCHAR)+',"wait_type":"'+ISNULL(r.wait_type,'')+'"}'
    FROM sys.dm_exec_requests r
    JOIN sys.dm_exec_sessions s ON r.session_id=s.session_id
    CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) t
    WHERE r.blocking_session_id>0 AND r.database_id=@TargetDBId AND r.wait_time>10000
      AND s.program_name NOT LIKE '%DMS%' AND s.program_name NOT LIKE '%AWS%';

    ---------- 3. wait stats (cumulative -> delta in Grafana) ----------
    INSERT INTO dbo.PerformanceLog (snapshot_time, monitored_db, metric_category, metric_name, metric_value)
    SELECT @snapshot_time, @TargetDatabase, 'wait_stats', wait_type, wait_time_ms
    FROM sys.dm_os_wait_stats
    WHERE wait_type IN ('LCK_M_U','LCK_M_X','LCK_M_S','LCK_M_IX','PAGEIOLATCH_SH','PAGEIOLATCH_EX',
                        'WRITELOG','CXPACKET','SOS_SCHEDULER_YIELD','RESOURCE_SEMAPHORE','ASYNC_NETWORK_IO');

    ---------- 4. system metrics (point-in-time) ----------
    INSERT INTO dbo.PerformanceLog (snapshot_time, monitored_db, metric_category, metric_name, metric_value)
    SELECT @snapshot_time, @TargetDatabase, 'system', 'active_sessions', COUNT(*)
    FROM sys.dm_exec_sessions
    WHERE is_user_process=1 AND status='running' AND database_id=@TargetDBId
      AND program_name NOT LIKE '%DMS%' AND program_name NOT LIKE '%AWS%' AND program_name NOT LIKE '%SQLAgent%';

    INSERT INTO dbo.PerformanceLog (snapshot_time, monitored_db, metric_category, metric_name, metric_value)
    SELECT @snapshot_time, @TargetDatabase, 'system', 'page_life_expectancy', cntr_value
    FROM sys.dm_os_performance_counters
    WHERE RTRIM(counter_name)='Page life expectancy' AND object_name LIKE '%Buffer Manager%';

    INSERT INTO dbo.PerformanceLog (snapshot_time, monitored_db, metric_category, metric_name, metric_value_decimal)
    SELECT @snapshot_time, @TargetDatabase, 'system', 'buffer_cache_hit_ratio',
           CAST((a.cntr_value*1.0/NULLIF(b.cntr_value,0))*100 AS DECIMAL(5,2))
    FROM sys.dm_os_performance_counters a
    JOIN sys.dm_os_performance_counters b ON a.object_name=b.object_name
    WHERE RTRIM(a.counter_name)='Buffer cache hit ratio' AND RTRIM(b.counter_name)='Buffer cache hit ratio base';

    ---------- 5. NEW: tempdb + version store (point-in-time) ----------
    INSERT INTO dbo.PerformanceLog (snapshot_time, monitored_db, metric_category, metric_name, metric_value)
    SELECT @snapshot_time, @TargetDatabase, 'tempdb', 'version_store_mb',
           SUM(version_store_reserved_page_count)*8/1024 FROM tempdb.sys.dm_db_file_space_usage
    UNION ALL
    SELECT @snapshot_time, @TargetDatabase, 'tempdb', 'tempdb_free_mb',
           SUM(unallocated_extent_page_count)*8/1024 FROM tempdb.sys.dm_db_file_space_usage
    UNION ALL
    SELECT @snapshot_time, @TargetDatabase, 'tempdb', 'tempdb_used_mb',
           SUM(user_object_reserved_page_count + internal_object_reserved_page_count)*8/1024
    FROM tempdb.sys.dm_db_file_space_usage;

    ---------- 6. NEW: throughput + health counters ----------
    -- the "/sec" ones are CUMULATIVE counts -> delta in Grafana; Memory Grants Pending is a gauge
    INSERT INTO dbo.PerformanceLog (snapshot_time, monitored_db, metric_category, metric_name, metric_value)
    SELECT @snapshot_time, @TargetDatabase, 'throughput', RTRIM(counter_name), cntr_value
    FROM sys.dm_os_performance_counters
    WHERE (RTRIM(counter_name)='Batch Requests/sec'      AND object_name LIKE '%SQL Statistics%')
       OR (RTRIM(counter_name)='SQL Compilations/sec'    AND object_name LIKE '%SQL Statistics%')
       OR (RTRIM(counter_name)='SQL Re-Compilations/sec' AND object_name LIKE '%SQL Statistics%')
       OR (RTRIM(counter_name)='Transactions/sec'        AND object_name LIKE '%Databases%' AND RTRIM(instance_name)='_Total')
       OR (RTRIM(counter_name)='Memory Grants Pending'   AND object_name LIKE '%Memory Manager%');

    ---------- 7. NEW: deadlocks (cumulative -> delta in Grafana) ----------
    INSERT INTO dbo.PerformanceLog (snapshot_time, monitored_db, metric_category, metric_name, metric_value)
    SELECT @snapshot_time, @TargetDatabase, 'deadlocks', 'Number of Deadlocks/sec', cntr_value
    FROM sys.dm_os_performance_counters
    WHERE RTRIM(counter_name)='Number of Deadlocks/sec' AND RTRIM(instance_name)='_Total';
END
GO

--TRAFFIC LIGHT QUERY---
SELECT Signal, [Now], Status, Meaning FROM (
  SELECT 0 ord, 'Monitoring heartbeat' Signal,
         CONCAT(COUNT(*),' metrics / 5 min') [Now],
         CASE WHEN COUNT(*)=0 THEN 'RED' ELSE 'GREEN' END Status,
         'RED = monitoring stopped' Meaning
  FROM dbo.PerformanceLog WHERE snapshot_time > DATEADD(MINUTE,-5,SYSDATETIME())
  UNION ALL
  SELECT 1,'Blocking',
         CONCAT(COUNT(*),' blocked, max ',ISNULL(MAX(metric_value),0),'s'),
         CASE WHEN ISNULL(MAX(metric_value),0)>=60 OR COUNT(*)>=5 THEN 'RED'
              WHEN COUNT(*)>0 THEN 'AMBER' ELSE 'GREEN' END,
         'Transactions waiting on each other'
  FROM dbo.PerformanceLog WHERE metric_category='blocking' AND snapshot_time>DATEADD(MINUTE,-2,SYSDATETIME())
  UNION ALL
  SELECT 2,'Long-running queries',
         CONCAT(COUNT(*),' running, max ',ISNULL(MAX(metric_value),0),'s'),
         CASE WHEN ISNULL(MAX(metric_value),0)>=300 THEN 'RED'
              WHEN COUNT(*)>0 THEN 'AMBER' ELSE 'GREEN' END,
         'A query is stuck / very slow'
  FROM dbo.PerformanceLog WHERE metric_category='long_running_query' AND snapshot_time>DATEADD(MINUTE,-2,SYSDATETIME())
  UNION ALL
  SELECT 3,'Active sessions',CAST(metric_value AS VARCHAR),
         CASE WHEN metric_value>=150 THEN 'RED' WHEN metric_value>=100 THEN 'AMBER' ELSE 'GREEN' END,
         'Spike = app stampede / pile-up'
  FROM (SELECT TOP 1 metric_value FROM dbo.PerformanceLog
        WHERE metric_category='system' AND metric_name='active_sessions' ORDER BY snapshot_time DESC) x
  UNION ALL
  SELECT 4,'Memory (PLE)',CONCAT(metric_value,'s'),
         CASE WHEN metric_value<300 THEN 'RED' WHEN metric_value<600 THEN 'AMBER' ELSE 'GREEN' END,
         'Low = memory pressure / big scans'
  FROM (SELECT TOP 1 metric_value FROM dbo.PerformanceLog
        WHERE metric_category='system' AND metric_name='page_life_expectancy' ORDER BY snapshot_time DESC) y
) v ORDER BY ord;
