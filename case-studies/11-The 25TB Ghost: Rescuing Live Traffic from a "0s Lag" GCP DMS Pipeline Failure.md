

# The 25TB Ghost: Rescuing Live Traffic from a "0s Lag" GCP DMS Pipeline Failure

**Category:** MySQL, GCP DMS, Disaster Recovery, Data Reconciliation

---

## 📌 Executive Summary

During a database migration intended to downsize a massive, over-provisioned **25 TB MySQL instance** to a right-sized target containing a **100 GB schema**, a silent CDC (Change Data Capture) pipeline failure occurred on GCP Database Migration Service (DMS).

Despite the GCP UI console reporting **"0 Seconds Replication Lag"** and maintaining a green healthy status, the CDC worker had crashed hours prior due to an unhandled administrative DDL query.

This post-mortem details the root cause of the silent failure, why metrics lied, and how we safely halted application traffic, executed a custom multi-stage Python reconciliation tool (`rollback_reconciliation_new.py`), and backfilled **105,560 account state changes** and **88,999 history logs** with **zero data loss** (`VERIFY PASSED`).

---

## 🏢 Architecture & Context

```text
[ Application Traffic ]
          │
          ▼
┌──────────────────┐               GCP DMS (CDC)               ┌──────────────────┐
│   Source DB      │ ────────────────────────────────────────> │    Target DB     │
│ (25TB Provisioned│                 [CRASHED]                 │  (Right-sized)   │
│   8.228.63.88)   │                                           │  34.89.109.165   │
└──────────────────┘                                           └──────────────────┘
         ▲                                                               │
         │                                                               │
         └───────────── [ Custom Reconciliation Tool ] ──────────────────┘
                            (Staged Delta Backfill)

```

* **Source Instance:** Primary production database (`8.228.63.88`), heavily over-provisioned at 25 TB storage for a 100 GB dataset.
* **Target Instance:** New instance (`34.89.109.165`) provisioned for cost optimization.
* **Replication Mechanism:** GCP Database Migration Service (DMS) running full dump + continuous CDC replication.

---

## 🚨 The Incident: The "0s Lag" Deception

### 1. The Trigger

An automated monitoring cleanup query ran on the source database:

```sql
ALTER EVENT monitoring.ev_kill_slow_select_queries DISABLE;

```

This DDL statement was recorded in the MySQL binary log. When GCP DMS attempted to replay this statement on the target database, the target threw:

> `MySQL Error 1539 (HY000): Unknown event 'ev_kill_slow_select_queries'`

Because the target instance did not contain the custom DBA `monitoring` schema or event definition, the replication worker crashed immediately.

### 2. Why the Dashboard Showed 0s Lag

Replication lag in CDC pipeline metrics is calculated as:


$$\text{Lag} = T_{\text{current}} - T_{\text{last\_processed\_binlog\_timestamp}}$$

When the DMS replication worker hard-crashed, **no new binlog positions were evaluated**. The metric engine stopped updating telemetry, leaving the GCP dashboard frozen on the last successfully reported value: **`0 seconds lag`**.

Unaware that replication had stopped, traffic was cut over to the target database, allowing live application writes to occur on the target while the pipeline was broken.

---

## 🛠️ The Rescue: State-Aware Delta Reconciliation

Resuming DMS was impossible without risking primary key collisions and GTID sequence corruption. We aborted the cutover, halted application traffic to freeze the database state, and executed a custom 5-stage Python reconciliation tool (`rollback_reconciliation_new.py`) to backfill target updates to the source instance.

### The 5-Stage Reconciliation Framework

The script followed a strict, non-destructive execution pipeline:

```bash
python3 rollback_reconciliation_new.py --mode [measure|capture|classify|apply|verify]

```

#### 1. Measure (`--mode measure`)

Scanned target tables across the live cutover window (`BOUNDARY_TS = 2026-08-29 01:28:02`) to calculate target write volumes and verify traffic cutoff by checking if `latest_timestamp` was frozen.

#### 2. Capture (`--mode capture`)

Extracted all rows modified on the target database during the live window and staged them into temporary scratch tables (`recon_delta_*`) on the source server in 500-row chunks with JSON checkpointing.

```text
04:08:21 | accounts_for_allocation: 105,560 rows staged
04:08:25 | deallocated_accounts: 1 row staged
04:14:25 | account_use_history: 88,999 rows staged

```

#### 3. Classify (`--mode classify`)

Performed a read-only audit categorizing staged data into expected `INSERT`, `UPDATE`, or `NOOP` operations on the source database to ensure zero primary key overlap or pool collision.

```text
04:15:26 | accounts_for_allocation   staged= 105,560  insert= 27,262  update= 78,298
04:15:26 | deallocated_accounts      staged=       1  insert=      1  update=      0
04:15:26 | account_use_history        staged=  88,999  insert= 88,999  (append-only)
04:15:26 | Accounts in BOTH pool and deallocated on target: 0

```

#### 4. Apply (`--mode apply`)

Executed batch upserts (`INSERT ... ON DUPLICATE KEY UPDATE`) on the source database within explicit transaction blocks and batch delays to avoid lock escalation.

#### 5. Verify (`--mode verify`)

Ran automated post-apply validation comparing row counts, checksums, and missing keys across source and staged target tables.

```text
04:16:19 | accounts_for_allocation   missing=0  diverged=0
04:16:19 | deallocated_accounts     missing=0  diverged=0
04:16:19 | account_use_history       unapplied=0
04:16:19 | VERIFY PASSED

```

---

## 🔑 Key Lessons & Takeaways

1. **Never Trust Lag Graphs on Dead Pipeline Workers:** CDC lag metrics track transaction processing delays—if the pipeline worker crashes entirely, lag metrics may freeze at `0` rather than raising an alert.
2. **Filter Administrative Schemas in Replication:** Always configure replication filters (e.g., in GCP DMS or `binlog-ignore-db`) to exclude system or DBA management schemas (`mysql`, `sys`, `monitoring`, `performance_schema`).
3. **Reconcile Before Resuming Traffic:** Never point application traffic back to a fallback server until a full delta reconciliation and verification (`missing=0`, `diverged=0`) has completed.
4. **Build State-Aware Reconciliation Tools Early:** Having a modular, stage-based script (`measure` $\rightarrow$ `capture` $\rightarrow$ `classify` $\rightarrow$ `apply` $\rightarrow$ `verify`) turned a potential production outage into a controlled, zero-data-loss recovery.
