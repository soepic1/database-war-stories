#  Multi-Terabyte Migration from AWS Aurora MySQL 8.0 to Outposts RDS (MySQL 8.4)

## Executive Summary

We migrated the required production datasets from an AWS Aurora MySQL 8.0 environment to Amazon RDS for MySQL 8.4 on AWS Outposts to meet hybrid-cloud data-residency requirements and reduce managed-cloud storage overhead.

The source environment spanned eight schemas with an approximately 1.6 TB active tablespace footprint, alongside more than 4.4 TB of historical partition and archive data identified as outside the required destination scope. Rather than transfer all historical data, we used metadata-driven filtering to identify 63 tables for exclusion.

Our initial plan involved Aurora's native S3 export capabilities. After evaluating the destination compatibility and processing requirements, we used MySQL Shell's util.dump_instance() and util.load_dump() utilities to stream the required data through Amazon S3 during an approved maintenance window.

The resulting export covered 216 active tables and approximately 2.55 billion rows, with 746 GB of uncompressed data compressed to 105 GB using zstd. The dump completed in 26 minutes and 39 seconds. During restoration, we addressed MySQL 8.0-to-8.4 account compatibility issues, transient transfer failures, and target-side capacity constraints. The load resumed after interruption, and our recorded final validation reported no warnings or errors.

This case study documents the migration decisions, the failure modes encountered, the safeguards used, and the lessons learned when moving a large MySQL dataset between different managed database environments.

---

## 1. High-Throughput Production Profile & Migration Challenge

The primary database cluster handles live payment switching, card transaction authorization, and merchant settlement across core production schemas:

```
[Aurora MySQL 8.0 (AWS Region)] ──► [Streaming `zstd` Dump] ──► [AWS S3 Bucket]
                                                                      │
                                                           (Direct Connect / LGW)
                                                                      ▼
                                                       [Outposts RDS MySQL 8.4]

```

### Source Environment Specifications

* **Source Instance:** AWS Aurora MySQL 8.0
* **Destination Instance:** AWS Outposts RDS (MySQL Community 8.4)
* **Active Storage Footprint:** ~1.6 TB provisioned tablespace (expanded storage)
* **Payload Characteristics:** High write-throughput transaction records, partitioned daily card account tables, and legacy archive tables (`backoffice_transaction_records_archived_*`)

### The Structural Bottleneck & Architecture Shift

1. **The Native Export Trap:** We initially intended to export the database directly to S3 via native Aurora snapshot export. However, restoring native S3 export files onto MySQL 8.4 on Outposts RDS requires complex, time-consuming ETL pipelines (AWS Glue) to format and map tablespaces.
2. **Maintenance Window Advantage:** Because applications were completely shut down for the maintenance window, we could utilize `mysqlsh` streaming directly to S3 without active transaction mutations occurring during the final pass.
3. **Data Stripping Strategy:** Inspection of `information_schema.TABLES` revealed that **over 80% of the raw historical disk space was consumed by dated partition tables** that were no longer required in the active destination environment:

| Table Name | Total Size (GB) | Data Size (GB) | Index Size (GB) | Estimated Rows |
| --- | --- | --- | --- | --- |
| `backoffice_transaction_records_archived_<REDACTED>` | 864.78 GB | 675.68 GB | 189.10 GB | 534,444,216 |
| `backoffice_transaction_records_<REDACTED>` | 331.93 GB | 236.17 GB | 95.75 GB | 181,438,168 |
| `transaction_duplicate_check_records_<REDACTED>` | 302.64 GB | 81.58 GB | 221.05 GB | 1,149,994,405 |
| `withdrawal_card_daily_limit_<REDACTED>` | 84.48 GB | 22.62 GB | 61.86 GB | 73,988,624 |

---

## 2. The Architectural Dilemma: Tooling & Filter Failure Modes

### A. Why Wildcard Slashes & S3 Regex Failed in `mysqlsh`

When attempting to pass wildcard or regex patterns to `util.dump_instance()` using standard SQL `%` symbols or JavaScript slashes (`/.../`), MySQL Shell threw fatal parameter validation exceptions:

```text
ValueError: Util.dump_instance: Argument #2: Failed to parse table to be excluded '<REDACTED_DB>.<REDACTED_TABLE>*': Invalid object name, expected end of name, but got: '*'.
ValueError: Util.dump_instance: Argument #2: Failed to parse table to be excluded '/<REDACTED_DB>\.<REDACTED_TABLE>_.*/': Invalid character in identifier

```

**The Mechanics:** MySQL Shell's `excludeTables` option evaluates array items strictly as explicit MySQL object identifiers (`schema.table`). It does not interpret unescaped wildcard symbols (`*`, `%`) or forward slashes (`/`) as valid identifier characters.

### B. The MySQL 8.0 $\rightarrow$ 8.4 Cross-Version Friction

When attempting to restore database accounts using `loadUsers: True`, `util.load_dump()` crashed with connection loss:

```text
ERROR: While executing user accounts SQL: MySQL Error 2013 (HY000): Lost connection to MySQL server during query

```

**The Mechanics:** MySQL 8.4 **removed the legacy `mysql_native_password` plugin by default** and deprecated Aurora-specific system roles (`rds_superuser_role`, `aurora_stat_reset`). When `mysqlsh` attempted to execute `@.post.sql`, the 8.4 server rejected the legacy grant syntax, triggering a thread crash.

### C. Network Socket Drops over Direct Connect (`CURLcode = 55`)

During high-concurrency streaming (16 parallel threads), transient socket drops occurred between the Outposts host and AWS S3:

```text
ERROR: [Worker001] <REDACTED_DB>@<REDACTED_TABLE>@66.tsv.zst: 
MySQL Error 2000 (00000): Connection died, tried 5 times before giving up (CURLcode = 55)

```

---

## 3. Execution & Safety Engineering Runbook

### Step 1: Programmatic Dynamic Exclusion Matrix

Instead of hardcoding table names or passing illegal wildcards, we leveraged MySQL Shell's Python mode (`Py >`) to query `information_schema.TABLES` dynamically, extracting exact string matches for all 63 dated/archived tables into an array:

```python
# Programmatically query information_schema for dated and archive tables
query = """
SELECT CONCAT(TABLE_SCHEMA, '.', TABLE_NAME)
FROM information_schema.TABLES
WHERE TABLE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
  AND (
       (TABLE_SCHEMA = '<PRIMARY_SCHEMA_1>' AND TABLE_NAME REGEXP '_[0-9]{2,4}_[0-9]{2}_[0-9]{2,4}$')
       OR (TABLE_SCHEMA = '<PRIMARY_SCHEMA_1>' AND TABLE_NAME LIKE '%_archived_%')
       OR (TABLE_SCHEMA = '<PRIMARY_SCHEMA_2>' AND TABLE_NAME REGEXP '_[0-9]{2,4}_[0-9]{2}_[0-9]{2,4}$')
       OR (TABLE_SCHEMA = '<PRIMARY_SCHEMA_2>' AND TABLE_NAME REGEXP '^card_account20[0-9]{2}')
  );
"""

result = session.sql(query).execute()
tables_to_exclude = [row[0] for row in result.fetch_all()]
print(f"Total dated/archive tables identified for exclusion: {len(tables_to_exclude)}")
# Output: Total dated/archive tables identified for exclusion: 63

```

### Step 2: S3 Dump Execution with Compatibility Stripping

We initiated `util.dump_instance()` with 16 parallel threads, chunking data into 128 MB blocks streaming directly to AWS S3:

```python
util.dump_instance(
    "<REDACTED_DUMP_PREFIX>",
    {
        "s3BucketName": "<REDACTED_S3_BUCKET>",
        "s3Region": "<REDACTED_REGION>",
        "threads": 16,
        "bytesPerChunk": "128M",
        "consistent": False,
        "compatibility": [
            "strip_restricted_grants",
            "strip_definers",
            "ignore_missing_pks"
        ],
        "showProgress": True,
        "excludeTables": tables_to_exclude
    }
)

```

### Step 3: Network Timeout & Outposts Target Tuning

Before initiating the restoration on Outposts RDS, we set global network read/write timeouts to prevent socket drops over Direct Connect:

```python
# Executed on Target Instance
session.run_sql("SET GLOBAL net_read_timeout = 3600;")
session.run_sql("SET GLOBAL net_write_timeout = 3600;")
session.run_sql("SET GLOBAL max_allowed_packet = 1073741824;") # 1 GB

```

### Step 4: Resumable Outposts Load Execution

To decouple user creation errors, we set `"loadUsers": False` and `"ignoreExistingObjects": True`, allowing progress tracking to handle resumption after mid-flight host resizing (upgrading VM to 16 vCPUs):

```python
util.load_dump(
    "<REDACTED_DUMP_PREFIX>",
    {
        "s3BucketName": "<REDACTED_S3_BUCKET>",
        "s3Region": "<REDACTED_REGION>",
        "threads": 12,                          # Scaled for 16-vCPU VM headroom
        "loadUsers": False,                     # Decoupled to bypass MySQL 8.4 grant crash
        "ignoreExistingObjects": True,          # Ignores pre-existing rdsadmin system objects
        "deferTableIndexes": "off",
        "analyzeTables": "on",
        "showProgress": True
    }
)

```

### Step 5: MySQL 8.4 Post-Load Application User Provisioning

Once the data restore hit 100%, application accounts were created explicitly using `caching_sha2_password`:

```sql
CREATE USER IF NOT EXISTS '<APP_USER>'@'%' IDENTIFIED WITH caching_sha2_password BY '<REDACTED_SECURE_PASSWORD>';
GRANT ALL PRIVILEGES ON <PRIMARY_SCHEMA_1>.* TO '<APP_USER>'@'%';
GRANT ALL PRIVILEGES ON <PRIMARY_SCHEMA_2>.* TO '<APP_USER>'@'%';
FLUSH PRIVILEGES;

```

---

## 4. Real-Time Telemetry & Production Results

```
[Aurora MySQL 8.0] ──► 2.55B Rows (746 GB) ──► [S3 Bucket (105 GB zstd)] ──► [Outposts RDS 8.4]
                        │                                                     │
               (26 Mins Export)                                     (100% Load Completed)

```

### Measured Production Outcomes:

* **Payload Reduction:** Stripped **4.4+ Terabytes** of historical archive data, reducing the export payload to **746 GB uncompressed** (105 GB compressed `zstd`).
* **Dump Speed:** Exported 2,553,431,665 rows across 216 active tables in **26 minutes, 39 seconds** at an average uncompressed throughput of **466 MB/s**.
* **Restore Resilience:** After a transient network drop at 19% (142.83 GB), `util.load_dump()`'s state tracking file resumed seamlessly without dropping or duplicating a single chunk.
* **Target Integrity:** Restored 100% of data and rebuilt B-Tree indexes on MySQL 8.4 with **0 warnings and 0 errors**.

---

## Key Engineering Takeaways

1. **Evaluate Target ETL Complexity Before Choosing Export Tooling:** Native AWS S3 Aurora exports sound convenient, but restoring them onto self-managed or Outposts targets requires complex glue logic. `mysqlsh` (`util.dump_instance` / `util.load_dump`) provides an end-to-end, native MySQL-to-MySQL pipeline.
2. **Programmatic Metadata Filtering Beats Hardcoded Wildcards:** When `mysqlsh` filtering options (`excludeTables`) reject string wildcards, query `information_schema.TABLES` via Python mode in `mysqlsh` to build clean, explicit array inputs.
3. **Decouple User Account Imports on Major Version Jumps:** Crossing major engine boundaries (MySQL 8.0 $\rightarrow$ 8.4) often breaks legacy user grant files (`@.post.sql`) due to removed authentication plugins (`mysql_native_password`). Load schemas and data first (`loadUsers: False`), then provision application users explicitly.
4. **Leverage Native Progress Tracking for Hot Resizing:** `util.load_dump()` writes local progress state on the host. If VM compute or memory limits bottleneck ingestion during a maintenance window, you can safely cancel (`Ctrl+C`), resize the VM host, and resume without losing previously loaded tablespace pages.
