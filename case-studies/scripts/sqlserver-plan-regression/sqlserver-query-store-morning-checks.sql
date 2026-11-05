/* =============================================================================
   sqlserver-query-store-morning-checks.sql
   Read-only daily health check for Query Store, forced plans and plan drift.
   Safe to run at any time. Query Store timestamps are UTC.
   Referenced in case study #23.
   ============================================================================= */
USE PaymentsDB;
GO
DECLARE @query_id      BIGINT        = 7;                            -- Query Store query_id you're protecting
DECLARE @stmt_fragment NVARCHAR(200) = N'UPDATE [Transactions] SET'; -- text that identifies it in the plan cache

-- 1. Query Store and automatic tuning state
--    PASS: READ_WRITE, under 80% storage, tuning ON


SELECT actual_state_desc, readonly_reason, current_storage_size_mb, max_storage_size_mb,
       CAST(100.0 * current_storage_size_mb / NULLIF(max_storage_size_mb, 0) AS DECIMAL(5,1)) AS pct_used
FROM sys.database_query_store_options;

SELECT name, desired_state_desc, actual_state_desc, reason_desc
FROM sys.database_automatic_tuning_options;


-- 2. Forced plans
--    PASS: force_failure_count = 0 and the forced plan executed recently
SELECT q.query_id, p.plan_id, p.query_plan_hash, p.plan_forcing_type_desc,
       p.force_failure_count, p.last_force_failure_reason_desc, p.last_execution_time
FROM sys.query_store_plan p
JOIN sys.query_store_query q ON q.query_id = p.query_id
WHERE p.is_forced_plan = 1;

-- 3. Plans for the protected query in the last 24 hours
--    PASS: one or two plans with low, stable reads. ESCALATE: a new plan_id with a large jump in reads
SELECT p.plan_id, p.query_plan_hash, p.is_forced_plan,
       SUM(rs.count_executions) AS execs,
       CAST(SUM(rs.avg_logical_io_reads * rs.count_executions) / NULLIF(SUM(rs.count_executions), 0) AS DECIMAL(12,1)) AS avg_reads,
       CAST(SUM(rs.avg_cpu_time * rs.count_executions) / NULLIF(SUM(rs.count_executions), 0) / 1000 AS DECIMAL(10,2)) AS avg_cpu_ms,
       MIN(rsi.start_time) AS first_seen, MAX(rs.last_execution_time) AS last_seen
FROM sys.query_store_plan p
JOIN sys.query_store_runtime_stats rs ON rs.plan_id = p.plan_id
JOIN sys.query_store_runtime_stats_interval rsi ON rsi.runtime_stats_interval_id = rs.runtime_stats_interval_id
WHERE p.query_id = @query_id
  AND rsi.start_time >= DATEADD(HOUR, -24, SYSDATETIMEOFFSET())
GROUP BY p.plan_id, p.query_plan_hash, p.is_forced_plan
ORDER BY first_seen;

-- 4. Hourly trend: catches slow drift and spikes around maintenance windows
SELECT DATEADD(HOUR, DATEDIFF(HOUR, 0, rsi.start_time), 0) AS hour_utc,
       SUM(rs.count_executions) AS execs,
       CAST(SUM(rs.avg_logical_io_reads * rs.count_executions) / NULLIF(SUM(rs.count_executions), 0) AS DECIMAL(12,1)) AS avg_reads,
       CAST(SUM(rs.avg_cpu_time * rs.count_executions) / NULLIF(SUM(rs.count_executions), 0) / 1000 AS DECIMAL(10,2)) AS avg_cpu_ms
FROM sys.query_store_runtime_stats rs
JOIN sys.query_store_runtime_stats_interval rsi ON rsi.runtime_stats_interval_id = rs.runtime_stats_interval_id
JOIN sys.query_store_plan p ON p.plan_id = rs.plan_id
WHERE p.query_id = @query_id
  AND rsi.start_time >= DATEADD(HOUR, -24, SYSDATETIMEOFFSET())
GROUP BY DATEADD(HOUR, DATEDIFF(HOUR, 0, rsi.start_time), 0)
ORDER BY hour_utc;

-- 5. What automatic tuning has done (no rows = no regression detected)
SELECT name, reason, score, JSON_VALUE(state, '$.currentValue') AS state, last_refresh
FROM sys.dm_db_tuning_recommendations
ORDER BY last_refresh DESC;

-- 6. Is the plan in cache the forced one? Compare query_plan_hash with check 2
SELECT qs.query_plan_hash, qs.creation_time, qs.execution_count, qs.plan_generation_num,
       qs.total_logical_reads / NULLIF(qs.execution_count, 0) AS avg_reads
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
WHERE CHARINDEX(@stmt_fragment, st.text) > 0
  AND qs.execution_count > 100
ORDER BY qs.last_execution_time DESC;
GO
