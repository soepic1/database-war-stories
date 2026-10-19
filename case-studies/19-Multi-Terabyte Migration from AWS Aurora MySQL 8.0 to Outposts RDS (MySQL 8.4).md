
# Multi-Terabyte Migration: AWS Aurora MySQL 8.0 to MySQL 8.4 on AWS Outposts

## Executive Summary

To meet hybrid-cloud data-residency requirements and reduce managed-cloud storage overhead, we migrated our production payment-processing platform (**~1.6 TB active tablespace** across 8 schemas, **2.55 billion rows**) from AWS Aurora MySQL 8.0 in a cloud region to **MySQL 8.4 on AWS Outposts RDS**.

We initially planned to use native Aurora S3 export, but discovered that restoring Aurora exports to Outposts RDS required complex ETL orchestration (AWS Glue) due to engine and storage format incompatibilities. Instead, leveraging an approved maintenance window with applications shut down, we pivoted to MySQL Shell's streaming utilities (`util.dump_instance()` and `util.load_dump()`).

By programmatically identifying and excluding 63 historical/archived tables (**~4.4 TB of non-essential data**), strategically tuning thread concurrency, and resolving MySQL 8.0-to-8.4 cross-version authentication incompatibilities, we:

* **Exported 2.55 billion rows** (746 GB uncompressed, 105 GB with `zstd` compression) in **26 minutes, 39 seconds**.
* **Recovered from a mid-transfer network interruption** (19% progress) using MySQL Shell's resumable state tracking.
* **Completed zero-data-loss restoration** with 100% row-count reconciliation and full database-object validation.

This case study documents the architecture decisions, table-filtering strategy, migration execution, compatibility resolutions, and validation methodology for moving production-scale MySQL workloads to a hybrid-cloud environment.

---

## 1. The Challenge: Why Native AWS Export Wasn't Sufficient

### Source Environment Profile

| Attribute | Value |
| :--- | :--- |
| **Source Engine** | AWS Aurora MySQL 8.0 (Cloud Region) |
| **Destination Engine** | MySQL 8.4 on AWS Outposts RDS |
| **Active Tablespace** | ~1.6 TB |
| **Historical Archive Data** | ~4.4 TB *(not required in destination)* |
| **Total Schemas** | 8 |
| **Tables in Final Export** | 216 |
| **Rows Migrated** | 2,553,431,665 |

The source database handles high-throughput payment switching, card transaction authorization, and merchant settlement. The destination needed **only active production data**, not years of historical archives.

### The Native Export Bottleneck

Our initial architecture assumed Aurora's native S3 export would provide a straightforward path:

```text
[Aurora MySQL 8.0] ──► [Native S3 Export] ──► [AWS Glue / ETL] ──► [Outposts RDS]

```

However, this approach introduced complexity:

* Aurora's native export format requires additional processing before it can be loaded onto a standard MySQL instance.
* AWS Glue jobs would be needed to validate and transform the export format.
* The process would extend beyond our approved maintenance window.

### The Strategic Pivot

Given an approved maintenance window with applications completely shut down, a requirement to exclude 4.4 TB of non-essential historical data, and direct connectivity between source region and Outposts (via Direct Connect), we chose **MySQL Shell's native streaming utilities** (`util.dump_instance()` and `util.load_dump()`) to create an end-to-end MySQL-native migration path that avoided unnecessary ETL complexity.

---

## 2. Data Scope: Identifying and Excluding Non-Essential Tables

Query analysis revealed that over **80% of raw historical disk space** was consumed by dated partition tables no longer required in the active environment.

### Why Wildcard Filtering Failed

When we attempted to pass wildcard patterns to `util.dump_instance()`, MySQL Shell rejected them:

```text
ValueError: Util.dump_instance: Argument #2: Failed to parse table to be excluded 
'<schema>.<table>*': Invalid object name, expected end of name, but got: '*'

```

> **Root Cause:** MySQL Shell's `excludeTables` option expects explicit, schema-qualified object identifiers (`schema.table`). It does not interpret SQL wildcards (`%`, `*`) or regex patterns (`/.../`) as valid identifier syntax.

### Solution: Metadata-Driven Exclusion Matrix

Instead of passing wildcard patterns, we queried `information_schema.TABLES` directly in Python mode to generate an explicit list of tables matching our archive naming conventions:

```python
# Python mode in MySQL Shell
query = """
SELECT CONCAT(TABLE_SCHEMA, '.', TABLE_NAME)
FROM information_schema.TABLES
WHERE TABLE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
  AND (
       (TABLE_SCHEMA = 'payment_core' AND TABLE_NAME REGEXP '_[0-9]{2,4}_[0-9]{2}_[0-9]{2,4}$')
       OR (TABLE_SCHEMA = 'payment_core' AND TABLE_NAME LIKE '%_archived_%')
       OR (TABLE_SCHEMA = 'settlement_ledger' AND TABLE_NAME REGEXP '_[0-9]{2,4}_[0-9]{2}_[0-9]{2,4}$')
       OR (TABLE_SCHEMA = 'settlement_ledger' AND TABLE_NAME REGEXP '^card_account20[0-9]{2}')
  );
"""

result = session.sql(query).execute()
tables_to_exclude = [row[0] for row in result.fetch_all()]

print(f"Total dated/archive tables identified for exclusion: {len(tables_to_exclude)}")
# Output: Total dated/archive tables identified for exclusion: 63

```

> **Key Insight:** By programmatically generating the exclusion list, we achieved **Repeatability**, **Visibility** (confirming 63 tables excluded before dump starts), **Safety** (reducing manual naming errors), and **Compliance** (source environment remains available as the retrieval path).

### Scope Outcome

| Category | Count | Size / Impact |
| --- | --- | --- |
| **Tables Included** | 216 | - |
| **Rows Included** | 2,553,431,665 | - |
| **Tables Excluded** | **63** | **~4.4 TB** |
| **Uncompressed Export Payload** | - | 746 GB |
| **Compressed Payload (`zstd`)** | - | **105 GB** |
| **Compression Ratio** | - | **85.9% reduction** |

---

## 3. Migration Architecture: S3-Based Staging

We used AWS S3 as an intermediary staging layer, avoiding the need for direct database-to-database connectivity across network boundaries:

```text
┌─────────────────────────────────────────────────────────────────┐
│                    SOURCE (AWS REGION)                          │
│                                                                  │
│         [Aurora MySQL 8.0]                                       │
│              │                                                   │
│              │ mysqlsh (16 threads, 128 MB chunks)              │
│              ▼                                                   │
│         [S3 Bucket]  ◄─── 746 GB (uncompressed)                │
│                            105 GB (zstd compressed)             │
└──────────────┬─────────────────────────────────────────────────┘
               │
               │ Direct Connect / Local Gateway
               │
┌──────────────▼─────────────────────────────────────────────────┐
│                 DESTINATION (OUTPOSTS)                          │
│                                                                  │
│         [Outposts VM] ──► [S3 Access]                          │
│              │                                                   │
│              │ mysqlsh (12 threads, resumed from checkpoint)    │
│              ▼                                                   │
│         [MySQL 8.4 on Outposts RDS]                            │
└─────────────────────────────────────────────────────────────────┘

```

Why this topology:

* **Decoupled Workloads:** Source and destination exports/imports work independently without requiring persistent dual-endpoint connectivity.
* **Auditability:** All transferred chunks are logged and verifiable in S3.
* **Resumability:** If transfer fails mid-flight, we resume from the last completed chunk, not from the beginning.
* **Scalability:** Thread counts can be tuned per environment without blocking either side.

---

## 4. Export Phase: Streaming to S3

### Configuration & Execution

```python
util.dump_instance(
    "s3://backup-bucket/aurora-to-outposts-migration/",
    {
        "s3BucketName": "backup-bucket",
        "s3Region": "eu-west-2",
        "threads": 16,                          # Match CPU cores for throughput
        "bytesPerChunk": "128M",                # Optimal for S3 transfer
        "consistent": False,                    # Safe because apps are shut down
        "compatibility": [
            "strip_restricted_grants",          # Aurora-specific grants -> standard MySQL
            "strip_definers",                   # Remove Aurora-specific DEFINER clauses
            "ignore_missing_pks"                # Handle edge cases gracefully
        ],
        "showProgress": True,
        "excludeTables": tables_to_exclude      # Our 63-table exclusion array
    }
)

```

### Why These Settings Matter

| Setting | Rationale |
| --- | --- |
| **`threads: 16`** | Parallel I/O increases throughput; matched to source instance's available CPU. |
| **`bytesPerChunk: 128M`** | Balances S3 API overhead vs. chunk size; 128 MB is optimal for streaming performance. |
| **`consistent: False`** | Safe because applications are completely shut down; no concurrent writes during export. |
| **`strip_restricted_grants`** | Aurora-specific roles (`rds_superuser_role`, `aurora_stat_reset`) don't exist on standard MySQL 8.4. |
| **`strip_definers`** | Removes Aurora internal `DEFINER` clauses that would be invalid post-migration. |
| **`ignore_missing_pks`** | Gracefully handles tables without explicit primary keys (prevents hard failures). |

### Measured Results

```text
Export Duration:        26 minutes, 39 seconds
Rows Exported:          2,553,431,665
Uncompressed Size:      746 GB
Compressed Size:        105 GB (zstd)
Compression Ratio:      85.9%
Average Throughput:     466 MB/s (uncompressed)

```

---

## 5. Cross-Version Compatibility: MySQL 8.0 ➔ 8.4 Friction Points

Moving between major MySQL versions introduced two critical compatibility issues we had to resolve during the load phase.

### Issue #1: Removed Authentication Plugin (`mysql_native_password`)

When we first attempted the load with `"loadUsers": True`, the process crashed:

```text
MySQL Error 2013 (HY000): Lost connection to MySQL server during query occurred while executing the user accounts script (@.post.sql)

```

> **Root Cause:** MySQL 8.4 removes `mysql_native_password` by default. When `util.load_dump()` tried to execute the source's user grant file (`@.post.sql`), it contained `IDENTIFIED WITH mysql_native_password` clauses that the 8.4 server rejected, crashing the thread.

### Issue #2: Network Socket Drops Under Load

During high-concurrency streaming (16 parallel threads), we encountered transient connection failures:

```text
ERROR: [Worker001] <schema>@<table>@66.tsv.zst:
MySQL Error 2000 (00000): Connection died, tried 5 times before giving up (CURLcode = 55)

```

Occurring at approximately **19% through the load (142.83 GB processed)**, `CURLcode = 55` indicates a socket-level transport error, likely due to network timeouts over Direct Connect during sustained I/O.

---

### Solutions Implemented

#### Solution #1: Decouple User Provisioning from Data Load

```python
util.load_dump(
    "s3://backup-bucket/aurora-to-outposts-migration/",
    {
        "s3BucketName": "backup-bucket",
        "s3Region": "eu-west-2",
        "threads": 12,                          # Reduced for resumed load after VM resize
        "loadUsers": False,                     # ← CRITICAL: Skip problematic user grants
        "ignoreExistingObjects": True,          # Ignore pre-existing Outposts system objects
        "deferTableIndexes": "off",
        "analyzeTables": "on",
        "showProgress": True
    }
)

```

By setting `"loadUsers": False`, we decoupled data and object restoration from account creation. Application accounts were provisioned after the dump completed, using MySQL 8.4–compatible syntax:

```sql
-- Post-load, explicit account provisioning for MySQL 8.4
CREATE USER IF NOT EXISTS 'app_user'@'%' IDENTIFIED WITH caching_sha2_password BY '<password>';
GRANT ALL PRIVILEGES ON payment_core.* TO 'app_user'@'%';
GRANT ALL PRIVILEGES ON settlement_ledger.* TO 'app_user'@'%';
FLUSH PRIVILEGES;

```

#### Solution #2: Pre-tune Network Timeouts & Packet Size

Before initiating load, we configured the target Outposts instance:

```sql
SET GLOBAL net_read_timeout = 3600;        -- 1 hour (vs. default 30 seconds)
SET GLOBAL net_write_timeout = 3600;       -- 1 hour (vs. default 60 seconds)
SET GLOBAL max_allowed_packet = 1073741824; -- 1 GB (vs. default 64 MB)

```

#### Solution #3: Leverage Resumable Load State & VM Resize

When the 19% socket drop occurred, instead of restarting:

1. We cancelled the in-flight load (`Ctrl+C`).
2. Resized the destination VM from **8 vCPUs to 16 vCPUs** to provide additional I/O and memory headroom.
3. Resumed the load using `util.load_dump()`. MySQL Shell automatically detected the local progress state file and resumed from chunk 67 without dropping or duplicating data.

---

## 6. Post-Migration Validation

### 6.1 Row-Count Reconciliation

We compared source and destination row counts for every included table:

```sql
-- Example validation query (run on both source and destination)
SELECT 
    TABLE_SCHEMA,
    TABLE_NAME,
    TABLE_ROWS
FROM information_schema.TABLES
WHERE TABLE_SCHEMA IN ('payment_core', 'settlement_ledger')
ORDER BY TABLE_SCHEMA, TABLE_NAME;

```

> **Result:** `100% row-count match across all 216 included tables.`

### 6.2 Database-Object Validation

| Object Type | Status | Validation Method |
| --- | --- | --- |
| **Indexes (B-Tree, Full-Text)** | ✅ Migrated | Verified via `SHOW INDEXES` |
| **Stored Procedures** | ✅ Migrated | Syntax checked on 8.4 parser |
| **Stored Functions** | ✅ Migrated | Tested successfully |
| **Events (Scheduled Tasks)** | ✅ Migrated | Verified in `information_schema.EVENTS` |
| **Views** | ✅ Migrated | Query execution verified |
| **Triggers** | N/A | Source did not use triggers |

### 6.3 Application-Level Validation

Before marking migration complete, we ran representative application transactions against the destination:

* **Payment authorization queries:** Confirmed response times and result consistency.
* **Settlement ledger rollup aggregations:** Verified complex `JOIN`s and `GROUP BY` queries return matching datasets.
* **Merchant reconciliation reports:** Validated row counts in key reporting views.

### 6.4 Archive Table Exclusion Audit

We explicitly verified that the 63 excluded tables were not present in the destination:

```sql
-- Verify excluded tables are absent
SELECT COUNT(*) as archived_tables_in_destination
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = 'payment_core' 
  AND TABLE_NAME REGEXP '_[0-9]{2,4}_[0-9]{2}_[0-9]{2,4}$';

-- Expected result: 0

```

### Validation Summary

| Validation Scope | Result | Evidence |
| --- | --- | --- |
| **Row counts (all 216 tables)** | ✅ 100% match | Query results identical on source/destination |
| **Indexes** | ✅ Present & valid | `SHOW INDEXES` confirmed all indexes |
| **Stored procedures** | ✅ Migrated & functional | 8.4 parser accepted all DDL without error |
| **Stored functions** | ✅ Migrated & functional | Test invocations completed successfully |
| **Events** | ✅ Migrated & enabled | `information_schema.EVENTS` confirmed scheduling |
| **Application transactions** | ✅ Passed | Workflows validated |
| **Archive exclusion** | ✅ Confirmed | 63 tables absent from destination |

---

## 7. Measured Production Outcomes

```text
SOURCE DATA:
  Total rows migrated:           2,553,431,665
  Uncompressed export size:      746 GB
  Compressed size (zstd):        105 GB
  Compression ratio:             85.9%

EXPORT PHASE:
  Duration:                      26 minutes, 39 seconds
  Throughput:                    466 MB/s (uncompressed)
  Parallel threads:              16

TRANSFER & LOAD PHASE:
  Network interruption point:    ~19% (142.83 GB)
  Recovery method:               Resumed from checkpoint
  Data loss during recovery:     0 rows
  Destination VM resize:         8 vCPU → 16 vCPU
  Resume thread count:           12 threads
  Final load completion:         100%
  Load report status:            0 warnings, 0 errors

POST-MIGRATION VALIDATION:
  Row-count reconciliation:      216/216 tables matched
  Database objects validated:    Indexes , Procedures , Events 
  Application testing:           Payment, settlement, reconciliation 
  Total validation time:         ~1 hours

```

---

## 8. Key Engineering Lessons

1. **Evaluate the Full Pipeline Before Choosing Tooling:** Native cloud export features (Aurora S3 export) sound convenient but often require downstream ETL. MySQL Shell's streaming utilities provide a simple end-to-end MySQL-to-MySQL path.
2. **Query Metadata to Drive Filtering:** When wildcards fail, query `information_schema` programmatically to generate explicit, validated lists.
3. **Decouple Data & User Management on Major Version Boundaries:** Load schemas and data first (`"loadUsers": False`), then provision application accounts explicitly using target-version syntax.
4. **Pre-tune Network Timeouts for High-Concurrency Streaming:** Set `net_read_timeout` and `net_write_timeout` to 1 hour or higher before starting long-running transfers.
5. **Leverage Progress State for Safe Resume & VM Resize:** MySQL Shell writes local progress state on the host, enabling safe resumption after interruptions without losing progress.
6. **Validate at Multiple Layers:** Always compare row counts, verify database objects, and run application transactions.

---

## Conclusion

Migrating 2.55 billion rows between managed MySQL environments required strategic scoping, metadata-driven filtering, cross-version compatibility planning, resilient architecture, and multi-layer validation.

The result: **zero data loss**, **100% row-count reconciliation**, and a production-ready destination in a single maintenance window.

```

```
