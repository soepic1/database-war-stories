##  Executive Summary
To optimize high-throughput card transaction lookups and merchant reconciliation queries on our core payment gateway, we needed to add two secondary indexes (`masked_card_number` and the virtual generated column `last_four_digits`) to our primary ledger table, `transaction` (~96 million rows).

While our standard operational playbook mandates asynchronous binlog-based tooling (`gh-ost`), the migration was immediately aborted by pre-flight checks: **a critical child table (`tokenized_transaction`, ~61 million rows) held a parent-side foreign key referencing `transaction.id`.**

Using `gh-ost` would risk severing referential integrity due to MySQL's internal data dictionary rename semantics, while `pt-online-schema-change`'s `rebuild_constraints` mode threatened to hold exclusive metadata locks on 61 million child rows for hours, risking a major payment outage.

Instead, we designed and executed an optimized **Native MySQL 8.0 Online DDL (`ALGORITHM=INPLACE, LOCK=NONE`)** pattern paired with an expanded in-memory concurrent DML buffer and replica durability tuning. The migration completed in **37 minutes on production** with **zero dropped transactions, zero connection pool spikes, and zero gateway timeouts**.

---

##  1. High-Throughput Production Table Profile

The `transaction` table anchors all card payment attempts across POS terminals, virtual cards, and web checkouts:

```
[Card Terminal / Web Checkout] ──► [transaction (96M Rows)]
                                          │
                               (1:N Foreign Key)
                                          ▼
                         [tokenized_transaction (61M Rows)]
```

### Table DDL Definition:
```sql
CREATE TABLE `transaction` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `payment_provider_id` bigint DEFAULT NULL,
  `transaction_record_id` bigint NOT NULL,
  `charge_status` varchar(32) NOT NULL,
  `masked_card_number` varchar(20) DEFAULT NULL,
  `card_expiry_date` varchar(4) DEFAULT NULL,
  `provider_response_code` varchar(255) DEFAULT NULL,
  `created_on` datetime NOT NULL,
  `last_modified_on` datetime NOT NULL,
  `status` varchar(64) NOT NULL,
  `card_type` varchar(20) DEFAULT NULL,
  `last_four_digits` varchar(4) GENERATED ALWAYS AS (right(`masked_card_number`,4)) VIRTUAL,
  PRIMARY KEY (`id`),
  KEY `FK_card_trans_tran_record_id` (`transaction_record_id`),
  KEY `FK_card_trans_payment_provider_id` (`payment_provider_id`),
  KEY `idx_transaction_created_on` (`created_on`),
  CONSTRAINT `FK_card_trans_payment_provider_id` FOREIGN KEY (`payment_provider_id`) REFERENCES `provider` (`id`),
  CONSTRAINT `FK_card_trans_tran_record_id` FOREIGN KEY (`transaction_record_id`) REFERENCES `transaction_record` (`id`)
) ENGINE=InnoDB AUTO_INCREMENT=96771116 DEFAULT CHARSET=utf8mb3;
```

### The Required Schema Change:
```sql
ALTER TABLE transaction 
  ADD INDEX IDX_transaction_masked_card_number (masked_card_number), 
  ADD INDEX IDX_transaction_last_four_digits (last_four_digits);
```

---

##  2. The Architectural Dilemma: Tooling Evaluation

### A. Why `gh-ost` Failed at Pre-Flight
When initializing `gh-ost 1.1.7`, the inspector threw a fatal error:
```text
2026-09-21 23:00:01 ERROR Found 1 parent-side foreign keys on `databasename`.`transaction`. 
Parent-side foreign keys are not supported. Bailing out
```

Querying `INFORMATION_SCHEMA.KEY_COLUMN_USAGE` revealed the blocker:
```sql
SELECT TABLE_NAME, CONSTRAINT_NAME, REFERENCED_TABLE_NAME 
FROM INFORMATION_SCHEMA.KEY_COLUMN_USAGE 
WHERE REFERENCED_TABLE_NAME = 'transaction';
-- Result: `tokenized_transaction` (61.4M rows) references `transaction` (id)
```

**The Mechanics:** In InnoDB, foreign key constraints reference the table's internal dictionary object ID, not merely its string name. During `gh-ost` cut-over (`RENAME TABLE transaction TO _del, _gho TO transaction`), child constraints follow the old table (`_del`), permanently severing relationships to the new table. To prevent silent corruption, `gh-ost` enforces a hard exit.

### B. Why `pt-online-schema-change` Was Rejected
1. **Trigger Tax:** `pt-osc` attaches synchronous triggers (`AFTER INSERT, UPDATE, DELETE`) to live payment writes, which would double write latency during card transaction spikes.
2. **The 61M-Row Constraint Rebuild Lock:** With `--alter-foreign-keys-method=rebuild_constraints`, `pt-osc` executes `ALTER TABLE tokenized_transaction DROP FOREIGN KEY ..., ADD CONSTRAINT ...`. Re-adding an FK on 61M rows requires an exclusive metadata lock and a full validation scan under shared read lock (`LOCK=SHARED`), freezing writes on tokenization for an estimated 20–40 minutes.

### C. The Solution: Native MySQL 8.0 `INPLACE`
In MySQL 8.0, adding secondary indexes using `ALGORITHM=INPLACE` **does not rebuild the table**. It reads the clustered index, sorts the key values, and constructs isolated secondary B-Trees in tablespace pages, allowing completely concurrent, non-blocking DML (`LOCK=NONE`).

---

##  3. Execution & Safety Engineering Runbook

Prior to production execution at **02:00 AM WAT** (traffic valley), we performed an isolated staging dry-run on a restored replica instance, validating an execution duration of **30 minutes and 4 seconds**.

### Staging Verification Baseline:
```text
Start Time:  Tue Sep 22 07:50:15 GMT 2026
Finish Time: Tue Sep 22 08:20:19 GMT 2026
Duration:    30 mins 4 secs
Rows Altered: 0 (Metadata updated, B-Trees constructed)
```

### Production Hardening Controls:

```
                  PRODUCTION HARDENING PIPELINE
                                │
        ┌───────────────────────┼───────────────────────┐
        ▼                       ▼                       ▼
 [1. Metadata Lock Shield] [2. Memory Buffer Ceiling] [3. Replica Catch-up Tuning]
  SET lock_wait_timeout=30  innodb_online_alter_log   sync_binlog=0
  (Aborts if blocked)        _max_size=1GB            innodb_flush_log...=2
```

#### Step 1: Pre-Flight Lock & Transaction Inspection
Before initiating DDL, we ensured no active or lingering transactions held open locks:
```sql
SELECT trx_id, trx_state, trx_started, 
       TIMESTAMPDIFF(SECOND, trx_started, NOW()) AS duration_sec, trx_query 
FROM information_schema.innodb_trx 
WHERE TIMESTAMPDIFF(SECOND, trx_started, NOW()) > 5;
```

#### Step 2: Session & Global Parameter Tuning
```sql
-- Safeguard: Fail fast in 30 seconds rather than queueing payment transactions
SET SESSION lock_wait_timeout = 30;

```

#### Step 3: Replica Durability Acceleration (Preventing Extended Lag)
While `INPLACE` DDL runs on the primary, read replicas apply the statement sequentially via SQL worker threads. To accelerate binlog catch-up post-execution, we temporarily adjusted durability flags on both read replicas:
```sql
-- Executed on Read Replicas
SET GLOBAL sync_binlog = 0;
SET GLOBAL innodb_flush_log_at_trx_commit = 2;
```

#### Step 4: Live Execution
```sql
ALTER TABLE databasename.transaction 
  ADD INDEX IDX_transaction_masked_card_number (masked_card_number), 
  ADD INDEX IDX_transaction_last_four_digits (last_four_digits),
  ALGORITHM=INPLACE, 
  LOCK=NONE;
```

---

##  4. Real-Time Telemetry & Production Results

During the migration window, real-time stage progression was monitored via `performance_schema`:

```sql
SELECT 
    EVENT_NAME, 
    WORK_COMPLETED, 
    WORK_ESTIMATED, 
    ROUND((WORK_COMPLETED / NULLIF(WORK_ESTIMATED, 0)) * 100, 2) AS pct_completed
FROM performance_schema.events_stages_current
WHERE EVENT_NAME LIKE 'stage/innodb/alter%';
```

```
[Phase 1: Read Clustered Index & Sort Keys] ──► 100% Completed
                                                     │
                                                     ▼
[Phase 2: Insert into Secondary B-Trees]   ──► 100% Completed
                                                     │
                                                     ▼
[Phase 3: Apply Online Concurrent DML Log] ──► 100% Completed (1GB Buffer Utilized: <80MB)
                                                     │
                                                     ▼
                                            [Index Active & Online]
```

### Production Outcomes:
* **Total Execution Time:** **37 minutes, 12 seconds** (accounting for live concurrent writes).
* **Payment Ingestion Disruption:** **0.00%** (zero queued lock waits, zero failed card authorizations).
* **Online Log Buffer Headroom:** Peak concurrent write churn consumed less than 8% of the 1GB buffer.
* **Storage Growth:** Added ~5.2 GB of index page extents to `transaction.ibd`, well within provisioned capacity.
* **Replica Lag Recovery:** Replicas caught up to `Seconds_Behind_Source: 0` in under 8 minutes post-execution with relaxed `sync_binlog` settings.



##  Key Engineering Takeaways

1. **Know Your Tooling Limits:** `gh-ost` and `pt-osc` are not silver bullets. When parent-side foreign keys exist, asynchronous rename-based tooling introduces referential integrity corruption risks or child-table locking traps.
2. **Secondary Index Adds Do Not Rebuild Tables:** In MySQL 8.0 InnoDB, adding secondary indexes using `ALGORITHM=INPLACE` operates solely on the index B-Trees. It does not rebuild or duplicate raw table extents.
3. **Always Cap `lock_wait_timeout`:** Setting `SET SESSION lock_wait_timeout = 30;` is the ultimate defensive safety net. If metadata lock acquisition contention occurs, the operation fails fast rather than backing up production connection pools.
4. **Buffer Concurrent Writes:** When running `INPLACE` on write-heavy tables, standard `innodb_online_alter_log_max_size` (128MB) can easily overflow. Increasing to a hight value guarantees ample headroom for sustained ingestion.



