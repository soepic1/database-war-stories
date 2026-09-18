


# Downsizing a 25TB Cloud SQL Instance to 700GB: Zero-Downtime Migration via GCP DMS and the Live Cutover User Grant Trap

> **Scale:** 25 TB ➔ 700 GB (~97% Storage Reduction) | **Platform:** Google Cloud SQL (MySQL 8.0) | **Tooling:** GCP Database Migration Service (DMS), ProxySQL | **Focus:** FinOps, Zero-Downtime Migration, User Privileges

---

## 📌 Executive Summary
A mission-critical MySQL instance in Google Cloud SQL had accumulated a massive storage footprint of **25 TB** over years of operations, temporary index builds, and transaction log growth, while actual live operational data sat at just **~700 GB**. 

While native storage shrinking options existed, executing an in-place shrink would have required a **3 to 4-hour hard maintenance downtime window**—an unacceptable SLA breach for an active payment gateway processing live transactions 24/7.

To achieve zero downtime and realize massive FinOps cloud cost savings, we architected an online migration to a freshly provisioned 700 GB instance using **GCP Database Migration Service (DMS)** for continuous Change Data Capture (CDC). However, during the cutover window, application microservices encountered sudden `Access Denied` connection failures despite pre-migrated credentials. 

This post-mortem details the migration architecture, the FinOps economics of shedding 24+ TB of unneeded provisioned storage, the root cause of the MySQL 8 privilege failure, and the emergency script automation used to re-create user hashes on the fly without secret rotation.

---

## 💰 The FinOps Context: Why Shrink 25 TB?

In cloud infrastructure, over-provisioned enterprise block storage (such as Google Cloud Persistent Disk SSD) incurs continuous monthly costs for provisioned capacity, snapshot storage, and baseline IOPS.

```
+-------------------------------------------------------------------------------+
| STORAGE PROFILE COMPARISON                                                    |
+-------------------------------------------------------------------------------+
| Old Provisioned Footprint:  25,000 GB (25 TB)                                 |
| Actual Active Data Footprint:  ~700 GB                                        |
| Unused / Ghost Storage:     24,300 GB (~97.2% Over-Provisioned)               |
| Target Downtime Tolerance:  5-10 minutes (Continuous 24/7 Payment Processing)    |
+-------------------------------------------------------------------------------+
```

### The In-Place Shrink Dilemma
Performing an in-place storage reduction on cloud-managed database instances typically involves an offline volume reconfiguration, filesystem repacking, and block-level data copying:
* **Estimated In-Place Downtime:** **3 to 4 hours** of total database unavailability.
* **Fintech SLA Requirement:** < 60 seconds (sub-second query disruption during traffic switch).

---

## 🏗️ The Migration Architecture: Zero-Downtime GCP DMS Pipeline

To bypass the 4-hour downtime penalty entirely, we provisioned a brand-new, right-sized **700 GB Cloud SQL instance** and established an asynchronous replication stream using **GCP Database Migration Service (DMS)**.

```
┌─────────────────────────────────────────┐          ┌─────────────────────────────────────────┐
│     Source Cloud SQL (MySQL 8.0)        │          │     Target Cloud SQL (MySQL 8.0)        │
│          Storage: 25 TB                 │          │          Storage: 700 GB                │
└────────────────────┬────────────────────┘          └────────────────────▲────────────────────┘
                     │                                                    │
                     │  1. Initial Full Dump & Load                       │  3. Real-Time Write Apply
                     │  2. Continuous Binlog Stream (CDC)                 │
                     ▼                                                    │
              ┌──────────────────────────────────────────────────────────────────┐
              │               GCP Database Migration Service (DMS)               │
              │             - Change Data Capture Engine                         │
              │             - Monitored Lag: 0.00s at Cutover                    │
              └──────────────────────────────────────────────────────────────────┘
```

### Migration Execution Phases
1. **Initial Provisioning:** Deployed the target Cloud SQL instance configured at 700 GB with optimized CPU, memory, and buffer pool ratios.
2. **Initial Load & CDC Sync:** GCP DMS completed the historical data dump and seamlessly attached to the source binary log stream.
3. **Replication Stabilization:** Allowed the CDC stream to run until `Replication Lag = 0s`.

---

## 🚨 The Cutover Incident: The `Access Denied` Trap

With replication in complete sync, we initiated the cutover by promoting the target instance and updating connection routes. Immediately, core payment microservices threw connection exceptions:

```text
java.sql.SQLException: Access denied for user 'app_user_name'@'%' (using password: YES)
```

### 🔍 Root Cause Analysis
Although user accounts had been pre-migrated to the target instance prior to promotion:

1. **GCP DMS System Catalog Isolation:** GCP DMS intentionally replicates schema objects and application tables, but skips the underlying `mysql.user`, `mysql.db`, and `mysql.tables_priv` system catalog tables to protect target instance administration.
2. **MySQL 8.0 Default Role & Plugin State Desync:** 
   * On Cloud SQL MySQL 8.0, administrative and service accounts rely on specific roles (like `cloudsqlsuperuser`).
   * When accounts were imported, permissions failed to activate on connection because `DEFAULT ROLE` was not bound to the active authentication session, or the authentication plugin state was desynchronized during the instance promotion transition.
   * As a result, even though the password was accepted, MySQL rejected the authorization handshake upon database entry.

---

## 🛠️ The Emergency Resolution: Drop, Recreate, and Role Binding

To resolve the outage within minutes without requiring application restarts or rotating Kubernetes secrets across dozens of services, we executed a live repair script:

### Step 1: Extract Existing Password Hashes from Source
We extracted the exact encrypted hash and authentication plugin from the source server:

```sql
SHOW CREATE USER `app_user_name`@`%`;
SHOW GRANTS FOR `app_user_name`@`%`;
```

### Step 2: Live Drop and Clean Re-Creation on Target
On the newly promoted target instance, we dropped the desynchronized user and recreated it with the exact `mysql_native_password` hash, granted `cloudsqlsuperuser`, and explicitly bound `DEFAULT ROLE`:

```sql
-- 1. Drop the desynchronized account
DROP USER IF EXISTS `app_user_name`@`%`;

-- 2. Re-create user with exact encrypted hash
CREATE USER `app_user_name`@`%` 
IDENTIFIED WITH 'mysql_native_password' AS '*02CC997B05A9EEAECF93E2CF679AB77F06F7456C';

-- 3. Grant the Cloud SQL Superuser role
GRANT `cloudsqlsuperuser`@`%` TO `app_user_name`@`%`;

-- 4. Explicitly set DEFAULT ROLE (CRITICAL: Activates permissions on login)
SET DEFAULT ROLE `cloudsqlsuperuser`@`%` TO `app_user_name`@`%`;

-- 5. Force privilege cache reload
FLUSH PRIVILEGES;
```

Within **5 seconds** of executing `FLUSH PRIVILEGES;`, application connection pools re-authenticated successfully, health checks turned green, and payment processing resumed with zero dropped transactions.

---

## 📊 Post-Migration Outcomes & Business Impact

| Metric | Pre-Migration (Old Instance) | Post-Migration (New Instance) | Variance / Impact |
|---|---|---|---|
| **Storage Allocated** | **25,000 GB (25 TB)** | **700 GB** | **-97.2% reduction** |
| **Downtime Incurred** | 3–4 Hours (Projected In-Place) | **< 5 minutes (Traffic Switch)** | **100% SLA compliance** |
| **Infrastructure Cost** | Massive Over-Provisioned Monthly Bill | Optimized Right-Sized Tier | **Significant monthly savings** |
| **Replication Health** | Historical Lag Spikes | 0.00s Real-Time Lag | Restored clean I/O headroom |

---

## 📋 Standardized Cloud SQL Cutover Runbook

To prevent user grant desynchronization during future cloud migrations:

- [ ] **Pre-Generate User Creation Scripts:** Script out all non-system users using `SHOW CREATE USER` with exact hashes (`AS '*HASH'`).
- [ ] **Verify `DEFAULT ROLE` Syntax:** Ensure every user script includes `SET DEFAULT ROLE ALL TO \`user\`@\`%\`;`.
- [ ] **Live Pre-Cutover Test Connection:** Execute an active authentication handshake using the application credential from a test pod against the target instance *before* switching traffic.
- [ ] **Keep Drop-and-Recreate Scripts on Hand:** Have ready-to-run DDL scripts prepared in the cutover terminal for instantaneous resolution.

---

## 🎯 Key Engineering Takeaways
1. **Never Take Downtime for Storage Rightsizing:** When in-place cloud disk shrinking demands multi-hour maintenance windows, CDC replication via tools like GCP DMS enables seamless zero-downtime downsizing.
2. **DMS Migrates Tables, Not Privileges:** Database migration tools intentionally isolate system tables. User management must always be treated as a dedicated operational workstream.
3. **Role Binding in MySQL 8 is Mandatory:** Granting a role is insufficient; you must execute `SET DEFAULT ROLE` to ensure connections inherit permissions automatically.
