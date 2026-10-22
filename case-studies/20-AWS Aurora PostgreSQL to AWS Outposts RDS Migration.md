
# AWS Aurora PostgreSQL to AWS Outposts RDS Migration

A production-tested runbook and technical strategy for migrating PostgreSQL databases across network boundaries from **AWS Aurora PostgreSQL (Cloud Region)** to **RDS PostgreSQL on AWS Outposts** using an S3 staging layer.

---

## 📌 Architectural Overview

When migrating across hybrid cloud topologies, cross-network socket instability or latency over Direct Connect can break direct, long-running database dump streams. This pattern decouples the **Export (Cloud)** and **Import (Outposts)** operations using AWS S3 as an intermediate, fault-tolerant staging area.


```

┌──────────────────────────────────────────────────────────┐
│                   SOURCE (AWS REGION)                    │
│                                                          │
│     [Aurora PostgreSQL 14.x Writer Endpoint]             │
│                      │                                   │
│                      │ pg_dump -Fd -j 4 (Directory)      │
│                      ▼                                   │
│                 [Cloud VM]                               │
│                      │                                   │
│                      │ tar -czf & aws s3 cp              │
│                      ▼                                   │
│                 [S3 Bucket]                              │
└──────────────────────┬───────────────────────────────────┘
│
│ AWS Direct Connect / Local Gateway
│
┌──────────────────────▼───────────────────────────────────┐
│                 DESTINATION (OUTPOSTS)                   │
│                                                          │
│                 [Outposts VM]                            │
│                      │                                   │
│                      │ aws s3 cp & tar -xzf              │
│                      │ pg_restore -Fd -j 4               │
│                      ▼                                   │
│         [RDS PostgreSQL 17.x on AWS Outposts]            │
└──────────────────────────────────────────────────────────┘

```

---

## 🛠 Prerequisites & Client Setup

1. **Client Utility Matching:** The `pg_dump` and `pg_restore` versions installed on the EC2 VMs **must be equal to or newer than the target PostgreSQL engine version** (PostgreSQL 17.x in this implementation).
2. **PostgreSQL Client Installation (Ubuntu/Debian):**
   ```bash
   sudo apt update && sudo apt install -y postgresql-common
   sudo /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh
   sudo apt update && sudo apt install -y postgresql-client-17

```

3. **Storage Allocation:** Ensure the Cloud VM root volume has sufficient free disk space (`df -h .`) to hold uncompressed parallel dump directory files before archiving.

---

## 🚀 Execution Steps

### Step 1: Export Dumps from Source (Cloud VM)

Run the multi-threaded directory format dump (`-Fd`) inside a persistent session (`tmux` or `screen`) to ensure network resilience:

```bash
# Environment setup
export PGSSLMODE=require
read -s PGPASSWORD && export PGPASSWORD

SOURCE_HOST="aurora-writer-endpoint.rds.amazonaws.com"
DB_USER="admin_user"

# Execute multi-threaded directory dumps
pg_dump -h $SOURCE_HOST -U$DB_USER -d mpi_db -Fd -j 4 --no-owner --no-acl -v -f ./mpi_db_dump 2>&1 | tee dump_mpi.log
pg_dump -h $SOURCE_HOST -U$DB_USER -d taccs_clearing_db -Fd -j 4 --no-owner --no-acl -v -f ./taccs_clearing_db_dump 2>&1 | tee dump_taccs_clearing.log
pg_dump -h $SOURCE_HOST -U$DB_USER -d taccs_fee_db -Fd -j 4 --no-owner --no-acl -v -f ./taccs_fee_db_dump 2>&1 | tee dump_taccs_fee.log

# Archive and push to S3 Staging
tar -czvf all_databases_dump.tar.gz ./mpi_db_dump ./taccs_clearing_db_dump ./taccs_fee_db_dump
aws s3 cp all_databases_dump.tar.gz s3://your-migration-bucket/pg_migration/

```

---

### Step 2: Target Database & Role Preparation

Connect to the target Outposts RDS PostgreSQL instance and prepare roles and target databases:

```sql
-- Connect via psql as master user
CREATE DATABASE mpi_db OWNER app_owner_role;
CREATE DATABASE taccs_clearing_db OWNER app_owner_role;
CREATE DATABASE taccs_fee_db OWNER app_owner_role;

-- Grant role membership to allow object creation under owner context
GRANT app_owner_role TO target_master_user;

```

---

### Step 3: Download & Import (Outposts VM)

Pull the archive from S3 and trigger parallel `pg_restore`:

```bash
# Download and extract archive
aws s3 cp s3://your-migration-bucket/pg_migration/all_databases_dump.tar.gz .
tar -xzvf all_databases_dump.tar.gz

# Environment setup
export TARGET_HOST="10.59.4.223" # Outposts Local Gateway / Private IP
export PGSSLMODE=require
read -s PGPASSWORD && export PGPASSWORD

TARGET_USER="target_master_user"
APP_ROLE="app_owner_role"

# Restore databases using application owner context
pg_restore -h $TARGET_HOST -U $TARGET_USER -d mpi_db -j 4 --no-owner --no-acl --role=$APP_ROLE -v ./mpi_db_dump 2>&1 | tee restore_mpi.log
pg_restore -h $TARGET_HOST -U $TARGET_USER -d taccs_clearing_db -j 4 --no-owner --no-acl --role=$APP_ROLE -v ./taccs_clearing_db_dump 2>&1 | tee restore_taccs_clearing.log
pg_restore -h $TARGET_HOST -U $TARGET_USER -d taccs_fee_db -j 4 --no-owner --no-acl --role=$APP_ROLE -v ./taccs_fee_db_dump 2>&1 | tee restore_taccs_fee.log

```

---

## ⚡ Troubleshooting & Operational Edge Cases

### 1. `pg_restore: error: unsupported version (1.16) in file header`

* **Root Cause:** Occurs when attempting to restore a directory dump generated by `pg_dump` v17+ using an older `pg_restore` binary (v14 or lower).
* **Fix:** Upgrade the local `postgresql-client` packages on the restore host to matching PostgreSQL 17 binaries.

### 2. `ERROR: zero-length delimited identifier at or near ""` (`SET ROLE ""` Errors)

* **Root Cause:** When objects in the source database belong to dropped, unmapped, or blank roles, parallel worker threads (`-j 4`) attempt to execute `SET ROLE ""`.
* **Impact:** **Harmless warning.** Passing `--no-owner` and `--role=$APP_ROLE` forces object creation and overrides ownership cleanly.

---

## ✅ Post-Migration Checklist & Validation

1. **Rebuild Optimizer Statistics:**
```sql
ANALYZE VERBOSE;

```


2. **Re-grant Application Permissions:**
```sql
GRANT ALL ON SCHEMA public TO app_owner_role;
GRANT ALL ON ALL TABLES IN SCHEMA public TO app_owner_role;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO app_owner_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO app_owner_role;

```


3. **Data Parity Verification:**
```sql
SELECT schemaname, relname AS table_name, n_live_tup AS estimated_row_count 
FROM pg_stat_user_tables 
ORDER BY relname;

```



```

```
