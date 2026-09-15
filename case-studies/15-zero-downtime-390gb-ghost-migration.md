---


# How I migrated 144 million UUID-keyed payment records with a 1-second cut-over while navigating replica lag, throttling traps, and misleading migration metrics


---

## Executive Summary

In mission-critical fintech infrastructure, database downtime is not merely an inconvenience—it translates directly into failed payment reconciliations, merchant webhook timeouts, and cascading SLA violations. Adding a single secondary index to a heavily loaded table can trigger catastrophic table locks, replication starvation across read pools, or connection pool exhaustion.

This case study documents the end-to-end architectural journey of adding a secondary index (`idx_updated_at`) to a **390 GB, 144-million-row** payment notification ledger (`notification_requests`) at Moniepoint. Running on a 128-vCPU Google Cloud SQL MySQL instance, the migration completed with:

- **Total Rows Migrated:** 143,966,521
- **Exclusive Lock Duration:** Exactly **1.006 seconds**
- **Replication Lag Impact:** Maintained strictly below **0.05 seconds**
- **Application Downtime / Error Rate:** **0.00%**
- **Storage Defragmentation Savings:** Reclaimed **~40 GB** of fragmented InnoDB storage space

This article breaks down why MySQL's native Online DDL was rejected, the exact parameter tuning required for 128-vCPU instances, the mechanics of an 8-hour idle timeout trap, and why UUID primary keys cause non-linear progress overshoots (`164.8%`).

---

## 1. High-Throughput Fintech Context

Moniepoint powers financial transactions, banking operations, and payment gateways for millions of businesses across Africa. The `notification_requests` table sits at the critical boundary of asynchronous transaction fulfillment:

```
[Payment Ingestion] ──► [notification_requests] ──► [Webhook Dispatch Worker Pool] ──► [Merchant Endpoints]
                              │
                    (High Concurrent DML:
                     INSERT / UPDATE / SELECT)
```

Every incoming bank transfer, card payment, or terminal transaction generates a notification record that is polled, processed, updated with retry states, and finalized.

### Production Table Profile:
* **Engine:** InnoDB (MySQL 8.0)
* **Instance Specification:** Google Cloud SQL Enterprise Plus (128 vCPUs, 512 GB RAM)
* **Data Size:** ~390 GB on disk
* **Row Count:** ~144,000,000 rows
* **Primary Key:** `request_id` (`VARCHAR(36)` / UUID v4)
* **Required DDL:** `ALTER TABLE notification_requests ADD INDEX idx_updated_at (updated_at);`

---

## 2. Architectural Evaluation: Why Native Online DDL Was Rejected

MySQL 8.0 supports native Online DDL (`ALGORITHM=INPLACE, LOCK=NONE`). We evaluated this approach for the migration, but the expected operational behaviour under sustained write pressure did not meet our production risk tolerance.

The primary concerns were replication impact, metadata lock contention, the behaviour of the online DDL mechanism under sustained concurrent DML, and the level of operational control available once the operation was underway:

```

+-----------------------------------+---------------------------------------------------------+-------------------------------------------------------+
| Production Failure Mode           | Native Online DDL (ALGORITHM=INPLACE)                   | Asynchronous Binlog Migration (gh-ost)                |
+-----------------------------------+---------------------------------------------------------+-------------------------------------------------------+
| 1. Read-Replica Starvation        | DDL executes as a single monolithic transaction on       | Throttles copy if replica lag exceeds 2000ms; keeps   |
|                                   | replicas, causing 45-60 min replication lag.            | read pools in real-time sync (0.04s lag).             |
+-----------------------------------+---------------------------------------------------------+-------------------------------------------------------+
| 2. Metadata Lock (MDL) Contention | Long queries before commit queue up incoming DML,       | Uses non-blocking lock acquisition; aborts and        |
|                                   | exhausting application connection pools (504 cascades). | retries within milliseconds if lock is unavailable.   |
+-----------------------------------+---------------------------------------------------------+-------------------------------------------------------+
| 3. Online DML Buffer Overflows    | Concurrent writes during DDL fill in-memory buffer      | Binlog stream has unlimited buffer capacity on disk.  |
|                                   | (`innodb_online_alter_log_max_size`), causing aborts.   |                                                       |
+-----------------------------------+---------------------------------------------------------+-------------------------------------------------------+
| 4. Operational Control            | Once triggered, cannot be paused or scheduled.          | Fully controllable via Unix socket (postpone/throttle)|
+-----------------------------------+---------------------------------------------------------+-------------------------------------------------------+

```
Because the read replicas supported real-time merchant reporting and monitoring, we needed a migration strategy that could actively respond to replication lag and production load. Based on this evaluation, we selected GitHub's `gh-ost` for its asynchronous migration model, binlog-based change capture, throttling controls, and controlled cut-over mechanism..

---

## 3. High-Spec Tuning: Calibrating for 128 vCPUs

Default `gh-ost` flags are tuned conservatively for small virtual machines (`--chunk-size=1000`, `--dml-batch-size=30`). On a 128-vCPU enterprise instance with fast NVMe storage, these conservative settings bottleneck the network and protocol layers.

### Parameter Tuning Iteration

| Configuration Flag | Initial Default | Optimized Setting | Technical Rationale |
|---|---|---|---|
| `--chunk-size` | `1000` | **`3000`** | Cuts chunk iteration overhead by 3x; each `INSERT INTO ... SELECT` completes in <8ms on NVMe SSDs. |
| `--dml-batch-size` | `30` | **`100`** | Replays 100 binlog events per batch, accelerating catch-up throughput by over 3.3x. |
| `--max-load` | `Threads_running=75` | **`Threads_running=60`** | Soft limit: pauses chunk copying politely during traffic micro-bursts without aborting. |
| `--critical-load` | `Threads_running=100` | **`Threads_running=160`** | Hard limit: avoids panic exits on 128-core machines during normal spikes (~100 threads = only 78% core utilization). |
| `--max-lag-millis` | `3000` | **`2000`** | Protects downstream Cloud SQL read replicas from exceeding 2 seconds of replication lag. |

### The Production Execution Script

```bash
#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/home/sre/gh-ost_production_notification_requests.log"
PANIC_FILE="/home/sre/ghost_notification_requests.panic"
THROTTLE_FILE="/home/sre/ghost_migration.throttle"

gh-ost \
  --host=10.0.0.1 \
  --port=3306 \
  --user=ghost-user \
  --password="${DB_PASS}" \
  --database=database_name \
  --table=notification_requests \
  --alter="ADD INDEX idx_updated_at (updated_at)" \
  --allow-on-master \
  --assume-rbr \
  --chunk-size=3000 \
  --dml-batch-size=100 \
  --max-load=Threads_running=60 \
  --critical-load=Threads_running=160 \
  --max-lag-millis=2000 \
  --throttle-control-replicas=10.0.0.2:3306,10.0.0.3:3306 \
  --throttle-additional-flag-file="${THROTTLE_FILE}" \
  --panic-flag-file="${PANIC_FILE}" \
  --initially-drop-ghost-table \
  --initially-drop-old-table \
  --verbose \
  --execute >> "${LOG_FILE}" 2>&1 &

GHOST_PID=$!
echo "gh-ost running in background with PID: ${GHOST_PID}"
```

---

## 4. Production Edge Cases & Deep Dives

### Edge Case 1: The 8-Hour MySQL `wait_timeout` Disconnect Trap

During an initial execution run, a safety cron job touched the throttle file at the conclusion of an off-peak maintenance window:
```cron
50 3 * * * touch /home/sre/ghost_migration.throttle
```

**The Incident:** 
After being throttled for over 3 hours, the `gh-ost` socket suddenly returned `Connection refused`. The log showed:
```text
Copy: 117145843/84693263 138.3%; Time: 8h0m4s(total); State: throttled, flag-file; ETA: due
```

**Root Cause:**
In MySQL, client connections are governed by `wait_timeout` (default: 28,800 seconds / exactly 8 hours). When `gh-ost` is throttled via a flag file:
1. Row copying is suspended.
2. Heartbeat table writes are paused (`HeartbeatLag` climbed to 11,207 seconds).
3. Idle connections in the connection pool remain inactive until MySQL terminates them after 28,800 seconds.

**Architectural Lesson (Throttling vs. Postponing):**
Engineers must understand the distinction between throttling and postponing cut-over:

```
State: Throttled (Emergency Load Shedding)
 ├─ Row Copying: PAUSED
 ├─ Heartbeat Injector: PAUSED
 └─ Risk: Long-term idle connections hit wait_timeout and disconnect.

State: Postponed (Scheduled Maintenance Windows)
 ├─ Row Copying: Completes 100% in the background
 ├─ Heartbeat Injector: ACTIVE (continuous updates prevent idle timeouts)
 ├─ Binlog Syncer: ACTIVE (keeps lag at 0.04s with 0% extra CPU)
 └─ Result: Table is ready for an instant (<1s) atomic cut-over on demand.
```

*(This finding led directly to upstream PR #1767 on `github/gh-ost`).*

---

### Edge Case 2: The 164.8% Progress Overshoot & Non-Linear UUID Keyspaces

As the migration progressed, status queries returned perplexing metrics:

```text
Copy: 140344662/85169027 164.8%; Applied: 40995; State: migrating; ETA: due
```

**Why Did Progress Exceed 100%?**
1. **Statistical Estimation Divergence:** `gh-ost` determines initial total row count using `EXPLAIN` optimizer estimates (which estimated ~85.16M rows).
2. **Lexicographical Traversal:** Because the table's primary key is a UUID v4 string (`VARCHAR(36)`), `gh-ost` chunks lexicographical ranges from `00000000-0000...` to `ffffffff-ffff...`.
3. Hexadecimal distribution density does not map linearly to statistical sampling. The row copy traversed 140M+ keys before reaching the end of the `f...` hex boundary.

**The Operator Heuristic:**
When migrating string or UUID primary key tables, operators must not rely on `ETA: due`. Instead, monitor the highest key copied in the ghost table relative to the live table's absolute maximum:

```sql
-- Check Live Table Upper Bound
SELECT MAX(request_id) FROM database_name.notification_requests;
-- Output: fffffffd-2a9e-4d16-adf5-1dc24df351bb

-- Check Current Ghost Table Frontier
SELECT MAX(request_id) FROM database_name._notification_requests_gho;
-- Output: fffe8c6e-b68c-4277-9759-a20dcec5877d
```
When the prefix matches (`fff...` vs `ffffff...`), the migration is within seconds of cut-over.

---

## 5. The Cut-Over Sequence & Results

At 06:29:47 UTC, `gh-ost` reached the final primary key chunk and executed its atomic table rename/swap:

```text
2026-09-15 06:29:47 INFO Setting RENAME timeout as 3 seconds
2026-09-15 06:29:47 INFO Session renaming tables is 4384727
2026-09-15 06:29:47 INFO Issuing atomic rename:
  notification_requests      TO _notification_requests_del,
  _notification_requests_gho TO notification_requests
2026-09-15 06:29:48 INFO Tables renamed
2026-09-15 06:29:48 INFO Lock & rename duration: 1.006178683s. During this time, queries were briefly queued.
2026-09-15 06:29:54 INFO Done migrating notification_requests
```

```
[Live Table: notification_requests]   [Ghost Table: _notification_requests_gho]
                 │                                        │
                 └───────────────┐        ┌───────────────┘
                                 ▼        ▼
                      [ATOMIC TABLE SWAP (1.006s)]
                                 │        │
                 ┌───────────────┘        └───────────────┐
                 ▼                                        ▼
[Backup: _notification_requests_del]  [New Live Table: notification_requests]
```

### Key Production Results:
* **Zero Transaction Dropped:** Database connection pool queues absorbed the 1.006-second metadata lock without a single gateway timeout.
* **Storage Defragmentation:** The new table occupied **350 GB** compared to the fragmented original table's **390 GB**—yielding an immediate **40 GB disk space savings**.
* **Index Health:** The new index `idx_updated_at` immediately began serving high-speed range queries for webhook polling workers.

---

## 6. Safely Decommissioning 390GB Legacy Tables

`gh-ost` leaves the old table as `_notification_requests_del` as an instant rollback safety net. However, issuing a raw `DROP TABLE` on a 390GB table in production can cause:
1. **InnoDB Buffer Pool Mutex Freezes:** InnoDB scans the entire buffer pool to invalidate pages, freezing active queries.
2. **Filesystem I/O Spikes:** Deallocating millions of extent pages simultaneously saturates storage write IOPS.

### The Safe Decommissioning Playbook:
On managed cloud databases (Google Cloud SQL / AWS RDS):
1. **Retain for 24 Hours:** Keep `_notification_requests_del` intact during business hours as insurance.
2. **Execute During Midnight Maintenance Window:** Run the drop statement during the lowest traffic valley:
   ```sql
   DROP TABLE IF EXISTS database_name._notification_requests_del;
   ```

---

## 7. Open Source Impact & Upstream Contributions

The lessons learned from this 144M-row migration were synthesized into direct open-source contributions to the `github/gh-ost` repository:

1. **GitHub Issue #1766:** *Operational insights & ETA overshoot on large UUID-keyed tables (140M+ rows)*
2. **GitHub Pull Request #1767:** *Clarify operational differences between throttling and postponing cut-over*
3. **GitHub Pull Request #1745 (Merged in Release v1.1.8):** *Clarify replica selection requirements for `--throttle-control-replicas`*

---

## Conclusion & SRE Takeaways

1. **Hardware Dictates Configuration:** Never run default `gh-ost` flags on high-vCPU cloud instances. Benchmark `--chunk-size` (3000) and `--dml-batch-size` (100) to maximize throughput while respecting replica lag.
2. **Postpone, Don't Throttle:** For multi-hour migrations spanning maintenance windows, use `echo postpone` to allow copying to finish while keeping binlog streams active and immune to MySQL `wait_timeout`.
3. **Verify Alphanumeric Boundaries via SQL:** Do not rely on progress percentages on UUID tables; query `SELECT MAX(pk)` directly.
4. **Asynchronous Migration Wins:** With the right architecture, even 390GB core payment tables can undergo complex schema modifications with zero downtime and sub-second locking.

---

