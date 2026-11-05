# The 450ms Death by a Thousand Cuts: Diagnosing a Post-Partition-Switch Execution Plan Regression in SQL Server

## 1. The Incident: "Write Latency" With No Long-Running Queries
At 07:00 AM during the morning traffic ramp on a high-throughput payment processing service (`PaymentsDB`), application nodes began throwing `System.TimeoutException` errors, breaching their 15-second transaction processing budget. 

In AWS Performance Insights, **Average Active Sessions (AAS)** spiked from a baseline of `< 2` to **~690 concurrent sessions**, exhausting the application connection pools across the fleet.

### What Made This Tricky (The Red Herrings)
When triaging a sudden database stall on an OLTP write path, the usual suspects are lock blocking, deadlocks, or storage I/O throttling. However, live diagnostics ruled all of them out:
1. **No Long-Running Queries:** Querying `sys.dm_exec_requests` showed no multi-second blockers. Active `UPDATE` statements were completing in **~457 ms** with `wait_type = NULL` (actively burning CPU).
2. **Zero Lock Contention or Deadlocks:** `blocking_session_id = 0` across the board; `Number of Deadlocks/sec = 0`.
3. **Sub-Millisecond Storage Latency:** A 15-second differential snapshot of `sys.dm_io_virtual_file_stats` confirmed that both the Data file (`0.73 ms`) and Transaction Log (`0.36 ms`) were performing effortlessly:

| File Type | File Name | Writes (15s) | Avg Write Latency (ms) | Verdict |
| :--- | :--- | :--- | :--- | :--- |
| `ROWS` | `PaymentsDB_Data` | 20,453 | **0.73 ms** | Healthy (< 5 ms) |
| `LOG` | `PaymentsDB_Log` | 33,165 | **0.36 ms** | Healthy (< 2 ms) |

---

## 2. Finding the Smoking Gun in `sys.dm_exec_query_stats`
Why would a single-row primary-key status update (`UPDATE [Transactions] SET ... WHERE [Id] = @p7`) take **457 ms** on CPU when disk writes took **0.36 ms**?

An analysis of per-query CPU consumption revealed that this single `UPDATE` statement was consuming **94%–96% of total database CPU** (~46,000 ms of CPU time every minute).

Inspecting the plan cache via `sys.dm_exec_query_stats` exposed the culprit:

```sql
SELECT qs.plan_handle,
       qs.statement_start_offset,
       qs.creation_time,
       qs.execution_count,
       qs.total_logical_reads / NULLIF(qs.execution_count, 0) AS avg_reads,
       CAST(qs.total_worker_time / NULLIF(qs.execution_count, 0) / 1000.0 AS DECIMAL(10,2)) AS avg_cpu_ms
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
WHERE CHARINDEX('UPDATE [Transactions] SET [ResponseCode]', st.text) > 0
ORDER BY qs.creation_time DESC;
```

The Plan Cache Evidence
```
Plan Compiled At	Executions	Avg Logical Reads / Exec	Avg CPU (ms)	      Access Method
2026-11-02 00:19:20	223,835+	> 200,000 reads	                ~457.0 ms	       Clustered Index Scan (Bad)
2026-10-13 20:23:32	Historical	~46 reads	                  ~3.5 ms	          Index Seek (Good)
```
Instead of performing a lightweight Index Seek (~46 logical reads) to locate the single transaction row by [Id], SQL Server was executing a degraded plan compiled at 00:19:20 that performed hundreds of thousands of logical reads in memory on every single UPDATE.

## 3. Root Cause Analysis: The Nightly Partition Switch Trap

Why did SQL Server suddenly compile a terrible plan at 00:19:20?

1. 00:10 AM — Nightly Partition Switch: The Transactions table uses a sliding-window partitioning pattern. At 00:10 AM, an automated maintenance job runs ALTER TABLE ... SWITCH PARTITION to move historical rows into Transactions_Archive.
   
2. Metadata Invalidation & Near-Empty Table: The SWITCH operation modifies table metadata, invalidating cached execution plans. Immediately after the switch, the active Transactions table contains very few rows.
  
3. 00:19 AM — The "Empty Table" Recompile: When the UPDATE recompiled at 00:19 AM against a tiny row count, the Query Optimizer estimated that a Scan-based plan was cheaper than a Seek + Key Lookup.
  
4. 00:19 AM to 07:00 AM — Silent Time Bomb: As the table filled up to 1.5M+ rows throughout the morning, the bad plan remained in cache. Each execution scanned progressively more pages in the buffer pool until the 07:00 AM traffic peak saturated CPU schedulers (SOS_SCHEDULER_YIELD) and exhausted connection pools.

Bonus Discovery: "Partition Switch Stats Blindness"

Checking sys.dm_db_stats_properties uncovered a secondary trap on partitioned tables:

```sql
SELECT s.name, sp.last_updated, sp.rows, sp.rows_sampled, sp.modification_counter
FROM sys.stats s
CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) sp
WHERE s.object_id = OBJECT_ID('dbo.Transactions')
ORDER BY sp.last_updated DESC;
```

Because ALTER TABLE ... SWITCH PARTITION is a metadata-only operation, it does not increment modification_counter. Several auto-created column statistics (_WA_Sys_*) had been frozen for a month with modification_counter = 0, still reporting 15,051,802 rows when the table held 1.5M rows—meaning AUTO_UPDATE_STATISTICS would never trigger on them!

## 4. Immediate Remediation: Targeted Plan Eviction

Wiping the entire procedure cache (DBCC FREEPROCCACHE) on a busy production server can trigger a catastrophic recompile storm. Instead, we evicted only the single degraded plan_handle:

-- Evict ONLY the regressed plan handle

```sql
DBCC FREEPROCCACHE (0x06000600FB114918B00D3B308901000001000000000000000000000000000000000000000000000000000000);
```
Immediate Impact

Within seconds, SQL Server compiled a fresh plan against the populated 1.56M-row table:

Access Method: Restored to Index Seek.
Logical Reads: Dropped from >200,000 back to 46 reads/exec.
Execution Time: Dropped from 457 ms to 3.5 ms.

## 5. Long-Term Prevention: Plan Guides vs. Query Store

Because the UPDATE modifies indexed status columns (Status, TsqStatus, ResponseCode), its statistics cross the auto-update threshold roughly twice a minute (plan_generation_num > 2,000 per day), in addition to the nightly 00:10 partition switch. Every recompile is another roll of the dice.

We evaluated two mechanisms to lock in the healthy execution plan:

| Feature | Option A: SQL Plan Guide (sp_create_plan_guide_from_handle) | Option B: Query Store + Plan Forcing (sp_query_store_force_plan) |
| :--- | :--- | :--- |
| **Runtime Overhead** | **0% (Compile-time lookup only)** | Low (~1–2% CPU/IO, mitigated with QUERY_CAPTURE_MODE = AUTO) |
| **Plan History & Telemetry** | None (Requires manual DMV polling) | Full historical runtime stats across 15-min intervals |
| **Failure Mode if Index Drops** | **Strict:** Can fail the query if a pinned index is dropped/renamed | **Graceful Fallback:** Falls back to normal compilation & increments force_failure_count |
| **Auto-Healing** | Manual | Supports AUTOMATIC_TUNING (FORCE_LAST_GOOD_PLAN = ON) |


# Our Production Implementation (Bounded Query Store + Plan Forcing)

We enabled Query Store with strict boundaries (QUERY_CAPTURE_MODE = AUTO, WAIT_STATS_CAPTURE_MODE = ON, 15-minute aggregation intervals, and a 2 GB cap), enabled FORCE_LAST_GOOD_PLAN = ON, and pinned the optimal plan.

Over the following 24 hours—across 681 consecutive recompiles, the 00:10 AM nightly partition switch, and a morning peak of >82,000 executions per 15 minutes—logical reads remained rock-steady at 34.5 to 42.4 reads per execution (3.6 ms CPU), using just 6 MB of Query Store storage.

## 6. Key Takeaways for DBAs & SREs

1. "No Long-Running Queries" ≠ "Database is Fine": A 3ms query regressing to 450ms at 1,000+ requests/sec will melt your CPU and connection pools without ever showing up on a > 5s slow query alert.
2. Always Check Logical Reads per Execution: When disk latency (sys.dm_io_virtual_file_stats) is < 1 ms and wait_type is NULL or SOS_SCHEDULER_YIELD, check total_logical_reads / execution_count in sys.dm_exec_query_stats.
3. Sliding-Window Partition Switches Need Plan Protection: Recompiling right after a partition switch when a table is nearly empty is a prime trigger for scan-based plan regressions.
4. Never Run Unscoped DBCC FREEPROCCACHE in Prod: Always pass the specific 44-byte plan_handle to surgical-evict only the regressed plan.


