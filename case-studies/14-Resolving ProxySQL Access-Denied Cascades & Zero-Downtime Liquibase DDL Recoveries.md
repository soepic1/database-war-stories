
# Case Study 14: Resolving ProxySQL Access-Denied Cascades & Zero-Downtime Liquibase DDL Recoveries

## Executive Summary
In multi-tier MySQL architectures utilizing ProxySQL for connection pooling and query routing, stale or desynchronized credentials in ProxySQL's memory layer (`runtime_mysql_users`) can completely isolate application microservices. This case study details a severe production incident where a credential sync error at the ProxySQL proxy layer caused cascading HikariCP pool initialisation failures (`Access denied for user 'proxy-user-name'`), followed by Liquibase deployment locks on high-velocity tables. It outlines the end-to-end remediation path: safely purging/rebuilding ProxySQL runtime user tables, bypassing ProxySQL to perform non-blocking `ALGORITHM=INPLACE` online DDL updates, and manually reconciling Liquibase tracking states to restore service availability.

---

## 1. Initial Failure: ProxySQL Connection Handshake Rejection

Immediately following a deployment rollout of the `proxy-user-name` authentication microservice, application pods entered a crash-loop state. HikariCP connection pools failed to initialize during Spring Boot's context startup:

```text
2026-09-10 14:54:49.259 "Caused by: org.springframework.beans.BeanInstantiationException: 
Failed to instantiate [javax.sql.DataSource]: Factory method 'dataSource' threw exception with message: 
Failed to initialize pool: ProxySQL Error: Access denied for user 'proxy-user-name'@'10.0.0.1' (using password: YES)"
```


### Root Cause Analysis (Phase 1)

While the user account existed and had correct grants on the underlying MySQL primary instance, 
**ProxySQL's memory layer (`runtime_mysql_users`) contained duplicate/stale hashes** that differed from the active application password. 
Because ProxySQL authenticates incoming client connections *at the proxy layer* before multiplexing them to backend hostgroups, the handshake failed instantly at ProxySQL (`10.0.0.1`).

---

## 2. Phase 1 Remediation: Rebuilding ProxySQL Runtime Users

To resolve the access-denied error safely without interrupting other service accounts managed by ProxySQL:

### Step 1: Backup Database State & SQLite Disk File

Before modifying in-memory proxy state, both table-level backups and SQLite disk-file snapshots were created on the ProxySQL node:

```sql
-- Create database-level backup table in ProxySQL admin interface (Port 6032)
CREATE TABLE mysql_users_backup_20260910 AS SELECT * FROM mysql_users;

-- Verify backup payload
SELECT username, password, active, default_hostgroup 
FROM mysql_users_backup_20260910 
WHERE username = 'proxy-user-name';

```

```bash
# Backup physical SQLite DB file on ProxySQL host
sudo cp /var/lib/proxysql/proxysql.db /var/lib/proxysql/proxysql.db.bak_20260910

```

### Step 2: Purge, Re-insert, and Load to Runtime

Stale/conflicting user records were purged from `mysql_users`, clean credentials inserted, and changes pushed atomically to active runtime memory and disk:

```sql
-- 1. Purge duplicate/conflicting entries
DELETE FROM mysql_users WHERE username = 'proxy-user-name';
LOAD MYSQL USERS TO RUNTIME;

-- 2. Insert clean user entry mapped to Writer Hostgroup (HG 0)
INSERT INTO mysql_users (username, password, default_hostgroup, active, transaction_persistent) 
VALUES ('proxy-user-name', 'YOUR_EXACT_DATABASE_PASSWORD', 0, 1, 1);

-- 3. Atomic push to runtime memory and persistent disk
LOAD MYSQL USERS TO RUNTIME;
SAVE MYSQL USERS TO DISK;

-- 4. Verify runtime state
SELECT username, password, active, default_hostgroup 
FROM runtime_mysql_users 
WHERE username = 'proxy-user-name';

```

*(Note: Rollback plan was prepared using `INSERT INTO mysql_users SELECT * FROM mysql_users_backup_20260910...` if needed).*

---

## 3. Phase 2 Remediation: Online DDL & Liquibase State Reconcile

Once ProxySQL authentication was restored, 
application pods proceeded further in the boot sequence, where Liquibase migration attempts failed due to DDL execution blocks on `authentication_requests` (1,188 rows) and left a stale deployment lock in `DATABASECHANGELOGLOCK`.

To prevent blocking production traffic, manual DDL and changelog reconciliation was executed directly on the **MySQL Primary Writer**:

### Step 1: Non-Blocking `ALTER TABLE`

```sql
ALTER TABLE table_name 
ADD INDEX idx_authentication_requests_created_at (created_at), 
ALGORITHM=INPLACE, LOCK=NONE;

```


### Step 2: Clear Stale Lock & Restart Pods

```sql
UPDATE authentication_db.DATABASECHANGELOGLOCK 
SET LOCKED = 0, LOCKEDBY = NULL, LOCKGRANTED = NULL 
WHERE ID = 1;

```

Executing `kubectl rollout restart deployment/servicename` fully unblocked application boot sequences, successfully bringing the service back online.

---

## 4. Key Takeaways

1. **ProxySQL Has Its Own Independent Auth Memory:** Updating MySQL `mysql.user` on the database engine does **not** automatically update ProxySQL. Any credential rotation must explicitly execute `LOAD MYSQL USERS TO RUNTIME` and `SAVE MYSQL USERS TO DISK` on all ProxySQL nodes.
2. **Back Up ProxySQL State Before Modifying `mysql_users`:** Always create an in-memory backup table (`mysql_users_backup_YYYYMMDD`) and copy `/var/lib/proxysql/proxysql.db` before purging runtime users under incident pressure.
3. **Decouple App Boot from Schema Mutations:** Running automated DDL inside Spring Boot/Liquibase context causes compounding incident cascades when connection/proxy layers experience transient failures.

```

---
