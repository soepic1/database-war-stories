# Catching a "Ghost" Execution Plan Regression After a Nightly Partition Switch

*A SQL Server write-latency incident with no long-running queries, no blocking and fast disks: how we found it, what it cost, and what we could and could not prove.*

> **Timezones.** The database server runs on **UTC**. The team works in **WAT (UTC+1)**. Times below are written as **UTC (WAT)**, for example `00:19 UTC (01:19 WAT)`. Query Store and plan-cache timestamps are UTC. The Performance Insights screenshot and the monitoring CSV appear to use WAT, and we did not verify that.

---

## TL;DR

- **Symptom:** write latency on a high-volume payments database. Transfer-status saves breached a 15-second processing budget.
- **Not the cause:** locks, deadlocks, memory pressure, tempdb or slow storage.
- **Best-supported explanation:** a single-row status `UPDATE` ran on a plan that did far more reads per call than its normal ~46. That plan was compiled shortly after the nightly partition switch. It stayed in cache for about 13 hours. Evicting only that plan fixed it in seconds.
- **Not proven:** why the optimizer chose that plan, and why it wasn't replaced for hours. Query Store was off, and we evicted the plan before saving its XML.
- **Prevention:** Query Store with bounded settings, automatic plan correction, and a forced plan. We have **not** confirmed that forcing is enforced, so we check every morning.

---

## 1. Timeline

| UTC | WAT | Event | Source |
|---|---|---|---|
| ~00:10 | ~01:10 | Nightly partition switch. **Clock not verified** | Reported by the job owner |
| 00:19 | 01:19 | Status `UPDATE` compiles a new plan | Plan cache |
| ~06:00 | ~07:00 | Latency reported | Team |
| ~06:18:28 | ~07:18:28 | Load jumps from near 0 to ~690 average active sessions for ~30 s | Performance Insights |
| 06:18:45 | 07:18:45 | A transfer-status save exceeds its 15-second budget | Application log |
| 13:14 | 14:14 | We evict the bad plan. New plan: ~46 reads per call | Plan cache |
| 13:42–13:51 | 14:42–14:51 | Automatic statistics updates on the table | `sys.dm_db_stats_properties` |
| 13:56 | 14:56 | Statement recompiles, still ~46 reads | Plan cache |
| 22:21 (next day) | 23:21 | A plan we forced in Query Store stops running; a different, unforced plan takes over | Query Store |

---

## 2. The incident: write latency with nothing obviously wrong

The application logged this shape of error:

```text
fail: Microsoft.EntityFrameworkCore.Database.Connection[20004]
      An error occurred using the connection to database 'PaymentsDB' ...
fail: Payments.Application.Services.SyncTransferProcessorService[0]
      transfer status save for transfer <ref> ran past its 15 s budget
      System.TimeoutException ... TaskCanceledException: A task was canceled.
```

Performance Insights showed a sharp event. Average active sessions went from near zero to about **690**, held flat for about 30 seconds, then dropped away. All of it came from the application's writer login. The top SQL was the transfer-status `UPDATE`.

We have no wait-type data for that window, so **the cause of the 30-second spike is still unknown.** The sustained latency and the spike may or may not be the same problem.

### The usual suspects, ruled out

| Suspect | Evidence | Verdict |
|---|---|---|
| Long-running queries | Nothing long-running in `sys.dm_exec_requests` | Ruled out |
| Blocking and deadlocks | Deadlocks/sec 0 and memory grants pending 0 in every sample. Lock waits small | Ruled out |
| Slow storage | 15-second file-stats sample: data file **0.73 ms**, log file **0.36 ms** average write | Ruled out |
| Log can't be reused | `log_reuse_wait_desc = NOTHING`, 725 MB active log, 379 VLFs | Ruled out |
| Memory or tempdb pressure | Page life expectancy flat at 8,193. tempdb used about 9 MB. Version store 1–2 MB | Ruled out |
| Page splits | Rose about 7x (~4/s to ~30/s) around the same time, read off a chart. Writes rose by the same factor | Not the cause. See below |

**The file-latency check:**

| File type | Writes in 15 s | Avg write latency |
|---|---|---|
| Data (`ROWS`) | 20,453 | 0.73 ms |
| Log (`LOG`) | 33,165 | 0.36 ms |

**Page splits** jumped and stayed high for hours. A 30-second stall can't be explained by a rate that stayed flat for hours without a second stall. Splits and page writes rose together, which fits more write volume overall. We never ran the fragmentation checks, so we can't rule splits out as a *contributing* factor.

### The key clue: no wait type

A live snapshot of running requests showed the status `UPDATE`:

| Wait type | Sessions | Avg elapsed |
|---|---|---|
| `NULL` (running or queuing for CPU) | 3 | **457 ms** |

No wait type means it wasn't blocked and wasn't waiting on I/O. It was spending time on CPU. A single-row update by primary key should take a few milliseconds, so each call was doing far more work than it should.

---

## 3. Finding the smoking gun

### Which statement was using the CPU?

A monitoring job sampled top queries by CPU once a minute. Summing the samples showed one statement, the status `UPDATE`, using **94% to 96% of all sampled query CPU in every minute**, about 31 to 46 CPU-seconds per minute.

| Statement | Share of sampled CPU |
|---|---|
| Status `UPDATE` (the version that sets several status columns) | **94–96%** |
| Everything else, including CDC capture, the replication log reader and `fn_dblog` reads | The next-largest used roughly 100× less |

That share was constant from at least 07:10 WAT. Only the 30-second spike was an obvious event, so the problem was already building before it.

### What the plan cache showed

```sql
SELECT qs.plan_handle,
       qs.statement_start_offset,
       qs.creation_time,
       qs.execution_count,
       qs.total_logical_reads / NULLIF(qs.execution_count, 0)                    AS avg_reads,
       CAST(qs.total_worker_time / NULLIF(qs.execution_count, 0) / 1000.0 AS DECIMAL(10,2)) AS avg_cpu_ms
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
WHERE CHARINDEX('UPDATE [Transactions] SET [StatusCode]', st.text) > 0
ORDER BY qs.creation_time DESC;
```

| Plan | Compiled (UTC) | What we know |
|---|---|---|
| Plan in use during the incident | 00:19 | By far the most executions of any plan for this statement. Exact per-call reads were lost: the pasted columns ran together, so we can only say it was far above normal |
| Older plans | 13 Oct and 30 Oct | **46 to 134 reads** per call |
| Plan after we evicted the bad one | 13:14 | **~46 reads**, ~3.5 ms CPU per call |

For a single-row update by `Id`, ~46 reads is a seek. Reads far above that suggest a scan. The disk looked healthy because those reads came from memory, which is why storage was fine while CPU was saturated.

### Why we didn't see a "slow query"

The statement never ran for seconds. It ran for hundreds of milliseconds, thousands of times a minute. A slow-query alert at 5 seconds would never fire. That's what makes this kind of regression a "ghost".

---

## 4. Likely cause, and what we actually established

The table is partitioned, and a job switches a partition out every night. The bad plan was created at **00:19 UTC (01:19 WAT)**.

**Working theory:** the switch changes table metadata and invalidates its cached plans. The next execution compiled against a table holding far fewer rows than during the day, so the optimizer picked a plan that is cheap on a small table. As the table refilled, every call got more expensive. By the 07:00 WAT ramp, that was visible as CPU saturation.

### What's established and what isn't

| Claim | Status |
|---|---|
| The statement ran on a plan with vastly more reads than normal | **Confirmed** |
| Storage, locking and memory weren't the problem | **Confirmed** |
| No restart or failover cleared the cache | **Confirmed.** The instance had been up since 10 Oct |
| Compatibility level or statistics settings changed | **Ruled out.** Compatibility level 150, auto-update statistics on |
| Only `Transactions` and `Transactions_Archive` plans compiled between 00:00 and 00:40 UTC | **Confirmed** (three plans). Another `Transactions` update statement also recompiled about a minute after the bad one, and it came out healthy |
| The bad plan compiled 9 minutes after the switch | **Not confirmed.** True only if "00:10" is on the server clock. If it's WAT, the switch ran at 23:10 UTC and the gap is 69 minutes |
| The table was nearly empty when the plan compiled | **Not established.** Row counts rose from about 1.34M at 12:12 UTC to about 1.56M at 13:51 UTC, which fits a daily refill. The partition row-count check was never completed |
| The switch caused the bad plan | **Consistent with the evidence, not proven** |
| Why the plan stayed in cache for about 13 hours | **Unknown.** The statement was later seen recompiling roughly twice a minute |
| Cause of the 30-second spike | **Unknown** |

### A pointer on the switch time

Later, Query Store showed average reads per call falling from about 43.6 at 22:45 UTC to about 35 by 23:15 UTC, well before 00:10 UTC. A shallower index on a smaller table would produce that pattern. It may mean the switch ran closer to 23:10 UTC (00:10 WAT) than we assumed. We did not resolve this. It is the first thing to check against the job's own log.

### A second finding: statistics the switch seems to leave behind

Four auto-created column statistics had not been updated since early October. Each showed `modification_counter = 0`, and one still described **15,051,802 rows** when the table held about **1.56 million**. The others described about 198,000 rows.

```sql
SELECT s.name, c.name AS column_name, sp.last_updated, sp.rows, sp.rows_sampled, sp.modification_counter
FROM sys.stats s
JOIN sys.stats_columns sc ON sc.object_id = s.object_id AND sc.stats_id = s.stats_id
JOIN sys.columns c ON c.object_id = sc.object_id AND c.column_id = sc.column_id
CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) sp
WHERE s.object_id = OBJECT_ID('dbo.Transactions')
ORDER BY sp.last_updated DESC;
```

This is **consistent with** a partition switch not counting as row modifications, which would stop automatic updates firing on those columns. We didn't prove that mechanism, and we didn't show these statistics were used by the incident plan. Every index statistic had been auto-updated by about 13:50 UTC, with a ~3% sample.

---

## 5. Immediate fix: evict only the bad plan

We did **not** run an unscoped `DBCC FREEPROCCACHE`. Clearing every plan on a busy production server forces a recompile storm. We removed only the bad plan:

```sql
-- plan_handle values are 44 bytes (88 hex characters after 0x)
DBCC FREEPROCCACHE (0x06000600...);
```

The statement recompiled against the populated table and came back at about **46 reads and 3.5 ms CPU per call**, and CPU and timeouts settled.

A few practical lessons from the fix:
- **Look the handle up and evict it in one batch.** If the handle doesn't match, `DBCC` finishes without error and does nothing.
- **Check that it worked.** Re-run the plan-cache query a minute later. You want a new `creation_time` and reads back near 46.
- **Save the plan XML before you evict.** We didn't. That is the main reason the root cause is still a theory.

---

## 6. Preventing a repeat

Evicting a plan isn't protection. Every recompile is another chance for a bad plan. The statement was later seen recompiling about **twice a minute** (`plan_generation_num` went from about 2,195 to about 3,829 in 13 hours). It updates indexed status columns, which probably trips statistics thresholds constantly, though we didn't confirm the trigger.

We put two options in front of the CTO:

| | Plan guide | Query Store with plan forcing |
|---|---|---|
| Runtime overhead | Negligible (used only at compile time) | Low, **not measured on our system** |
| Plan history | None | Yes |
| Pinned plan becomes invalid | The statement can **error** | Falls back to a normal compile, counts the failure |
| Query text changes | Silently stops matching | New query, no forced plan |
| Works without Query Store | Yes | No |
| Effort | Low | Medium, plus a staged rollout |

**How a plan guide would have been created:**

```sql
EXEC sp_create_plan_guide_from_handle
     @name = N'PG_Transactions_StatusUpdate',
     @plan_handle = 0x06000600...,
     @statement_start_offset = 324;   -- offset of the UPDATE inside the batch, not the SET statements before it
```

**The CTO chose Query Store.** The overhead concern was the reason we presented both, and we never settled it by measurement. We enabled it with bounded settings:

```sql
ALTER DATABASE [PaymentsDB] SET QUERY_STORE = ON
(
  OPERATION_MODE              = READ_WRITE,
  QUERY_CAPTURE_MODE          = AUTO,
  MAX_STORAGE_SIZE_MB         = 2048,
  SIZE_BASED_CLEANUP_MODE     = AUTO,
  CLEANUP_POLICY              = (STALE_QUERY_THRESHOLD_DAYS = 14),
  DATA_FLUSH_INTERVAL_SECONDS = 900,
  INTERVAL_LENGTH_MINUTES     = 15,
  WAIT_STATS_CAPTURE_MODE     = OFF
);

ALTER DATABASE [PaymentsDB] SET AUTOMATIC_TUNING (FORCE_LAST_GOOD_PLAN = ON);
```

**Automatic plan correction is a safety net, not a "best plan forever" switch.** It only acts after it detects a regression, it needs an earlier good plan to go back to, and it stops working if Query Store fills up and goes read-only.

### What actually happened after we forced a plan

We manually forced one plan (plan 8). About 1.4 seconds after its last execution, a *different* plan (plan 47, a different plan hash, not forced) took over and ran all the traffic from then on.

| | Plan 8 (forced) | Plan 47 (not forced) |
|---|---|---|
| Executions | ~23,000 | ~700,000 by the next morning |
| Average reads | 48.6 | 40.7 |
| Average CPU | 3.62 ms | 3.67 ms |
| Last ran | 22:21 UTC the evening we forced it | Still running the next morning |

Query Store recorded **no forcing failure** (`force_failure_count = 0`). Over the following night, through the partition switch and the morning peak (up to about 82,000 executions per 15 minutes), the statement stayed on plan 47 at **34 to 43 reads per call**, across roughly 700 recompiles.

**What we can say:** performance stayed steady, and the bad plan didn't come back.

**What we can't say:** that forcing protected us. The optimizer may have chosen well every time. We don't know why the running plan didn't match the forced one. A text search for a forcing marker in the cached plan also came back "not forced", but we hadn't verified which marker this build uses. So we do not call this statement "locked".

The next step is to force the plan that is actually running, then confirm its hash stays the same through recompiles.

Query Store used about **6 MB of its 2 GB cap**. That is a good sign for storage. It says nothing about CPU or write overhead, which we watched in CloudWatch.

---

## 7. Morning checks: trust, but verify

For the first couple of weeks we ran a short read-only check each morning, then moved to weekly.

| Check | Pass | Escalate |
|---|---|---|
| Query Store state | `READ_WRITE`, under 80% of storage cap | `READ_ONLY`, or storage near full |
| Forced plans | `force_failure_count = 0`, recently executed | Failures, or the forced plan idle while its query is busy |
| Plans for the protected query (24 h) | One or two plans, low and stable reads | A new `plan_id` with a large jump in reads |
| Hourly trend | Flat through the maintenance window and the morning peak | A spike or a climb |
| Automatic tuning recommendations | None, or verified | Repeated recommendations on the same query |
| Plan in cache vs forced plan | Hashes match | Mismatch: forcing may not be enforced |
| CPU and application timeouts (outside SQL Server) | At baseline | Sustained rise |

Practical notes:
- **Identify the statement by `query_id` and its text.** The `query_hash` Query Store showed did not match the one in the plan cache, and we couldn't explain why.
- **Query Store times are UTC.** Convert before comparing with application logs.
- **Rollback, in order:** `AUTOMATIC_TUNING = OFF`, then `OPERATION_MODE = READ_ONLY`, then `QUERY_STORE = OFF`. Turning Query Store off also stops any forcing.

Script: [`sqlserver-query-store-morning-checks.sql`](scripts/sqlserver-plan-regression/sqlserver-query-store-morning-checks.sql)

---

## 8. Other things we found along the way

These aren't proven causes, but they're worth knowing.

- **A mostly-empty log of ~462 GB.** The log file was about 462 GB with only ~725 MB in use. SQL Server zero-fills log growth, and a large autogrowth can freeze writes. We never checked the growth settings or the growth history, so we can't link it to the 30-second spike.
- **Minute-by-minute monitoring jobs overwrote job history.** Three monitoring jobs wrote history every minute, which pushed out the overnight job runs. That left us without the evidence for what ran at 00:10. Raise job-history retention.
- **The default trace came back empty** for the overnight window. It probably rolled over, so absence of rows isn't evidence that nothing happened.
- **Several versions of the status `UPDATE` exist.** The ORM only includes changed columns, so each combination is a separate statement with its own plan. Plan forcing or a guide covers one statement text only.

---

## 9. What we don't know yet

- Why the optimizer chose the bad plan, and whether the near-empty-table theory is right.
- Whether the switch runs on the server clock or on WAT, and so how long after it the bad plan compiled.
- Why the bad plan stayed in cache for about 13 hours when the statement normally recompiles every few minutes.
- What caused the 30-second flat spike. We never captured wait types for it.
- Whether Query Store plan forcing is enforced for this statement.
- The real CPU and write overhead of Query Store on this workload.

---

## 10. Takeaways

1. **"No long-running queries" doesn't mean the database is fine.** A few-millisecond statement that regresses to hundreds of milliseconds at high concurrency saturates CPU without looking slow.
2. **When storage latency is under a millisecond and nothing is blocked, check reads per execution.** Look at `total_logical_reads / execution_count` in `sys.dm_exec_query_stats`.
3. **A missing wait type is a clue.** Sessions with no wait are on CPU, not stuck behind something.
4. **Save the plan XML before you evict it.** Without it, a regression is much harder to explain.
5. **Turn on Query Store before you need it.** We had no plan history for the incident, so everything about the bad plan is inferred.
6. **Evict one plan, not the whole cache.** Pass the specific `plan_handle`, and check the eviction worked.
7. **Partition switches deserve a plan-protection strategy.** Recompiles after a switch are a plausible trigger, and the statistics a switch leaves behind can go stale quietly.
8. **"Forced" in the catalog is not proof.** Compare the forced plan with the plan that is actually running.
9. **Agree on one clock before you start.** Server, application logs and dashboards were on two timezones, and it changed how we read the timeline.
10. **Write down what you don't know.** It stops a plausible theory turning into a "fact" in the postmortem.

---

## Scripts

- [`sqlserver-query-store-morning-checks.sql`](scripts/sqlserver-plan-regression/sqlserver-query-store-morning-checks.sql): read-only daily health check
