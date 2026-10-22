# Database War Stories

Real production database engineering — the kind of problems that don't have a clean answer in the manual.

I'm Seun, a Lead Database Engineer working across AWS, GCP, and Oracle Cloud, operating large-scale database systems for a high-volume fintech platform processing 150,000+ transactions per minute. This repo is a collection of real production engineering problems I've solved — investigated, root-caused, and fixed — written up in detail for anyone who wants to see the actual thinking behind the fix, not just the headline.

## Case Studies

- [Eliminating a 150M-Row Database Backlog Using Pure Metadata Operations](case-studies/01-partition-switch-migration.md) — how a silent, compounding archival failure grew to 159M unarchived rows on a production payment-switch database, and how I engineered a novel technique to clear the entire backlog in minutes instead of hours, with zero downtime.
- [Building a Self-Healing AWS DMS Replication Pipeline](case-studies/02-dms-self-healing-pipeline.md) — how I eliminated 95% of manual intervention on cross-cloud replication failures with a serverless, stability-aware self-healing system.
- [Building Production Database Observability From Scratch](case-studies/03-production-database-observability.md) — how I turned a database with almost no structured visibility into one with real lock-contention detection and per-query performance baselines, using nothing but MySQL's own Performance Schema.
- [Standardized Infrastructure Importation of Core Aurora MySQL and Amazon DocumentDB Estates](case-studies/04-unified-modular-database-imports.md) — how I codified existing unmanaged database clusters into highly abstracted corporate modules with zero diff and zero live disruption.
- [A Traffic-Light Dashboard for "Is the Database OK Right Now?"](case-studies/05-traffic-light-dashboard.md) - how I implemented a simple dashboard for the SRE to know if the database is fine at the moment.
- [Adding Columns to a 171GB Production Table With Just Over One Second of Impact](case-studies/06-large-table-schema-change-zero-impact.md) — how I replaced a risky 70-minute native schema change with a replica-lag-aware online migration, moving 28 million rows on a live production system with just 1.06 seconds of actual query blocking.
- [Orchestrating Safe Sequential Migrations Across Multiple Production Tables](case-studies/07-orchestrating-sequential-multi-table-migrations.md) — a reusable pattern for safely sequencing multiple production schema changes without doubling risk exposure.
- [The Missing Privilege AWS's Own Documentation Didn't Mention](case-studies/09-postgresql-logical-replication-permission-gap.md)
- [Isolate First, Fix Root Cause Second: Correcting a Month-Long Incident Theory With Evidence](case-studies/10-isolate-first-fix-root-cause-second.md) — how rigorous, evidence-based investigation corrected a plausible-but-wrong incident theory and led to a pragmatic architectural fix.
-  [The 25TB Ghost: Rescuing Live Traffic from a "0s Lag" GCP DMS Pipeline Failure](case-studies/11-The%2025TB%20Ghost%3A%20Rescuing%20Live%20Traffic%20from%20a%20%220s%20Lag%22%20GCP%20DMS%20Pipeline%20Failure.md) — how a crashed GCP DMS worker masked itself behind a frozen "0s lag" UI metric during a database downsizing cutover, and how I engineered a custom multi-stage Python delta reconciliation tool to backfill 100k+ live transactions back to the primary database with zero data loss.
-  [The 100k Depleted Pool: Rescuing Live Checkout Traffic from Account Starvation](case-studies/12-The-100k-Depleted-Pool-Rescuing-Live-Checkout-Traffic-from-Account-Starvation.md) — how depleted virtual bank account allocation pools threatened live payment checkout operations, and how I engineered a replica-aware, non-blocking Python worker backed by an iterative micro-batched MySQL stored procedure to safely recycle 135k+ historical accounts with zero lock contention.
- [The Silent Lock Spikes: Non-Invasive MySQL Observability Without Downtime or Alert Fatigue](case-studies/13-non-invasive-mysql-watchdog.md) — how uncommitted application transaction leaks (`idle_in_trx`) silently locked rows without executing active queries, and how I engineered a zero-overhead metadata watchdog with lock-tree dependency filtering to eliminate alert spam and auto-generate post-mortems.
- [How I migrated 144 million UUID-keyed payment records with a 1-second cut-over while navigating replica lag, throttling traps, and misleading migration metrics](case-studies/15-zero-downtime-390gb-ghost-migration.md) — how I engineered a zero-downtime schema migration for a 390GB production MySQL payment table using gh-ost, keeping replication lag below 0.05 seconds and application downtime at zero while diagnosing UUID keyspace anomalies, an 8-hour throttling timeout trap, and migration progress exceeding 100%.
- [Downsizing a 25TB Cloud SQL Instance to 700GB: Zero-Downtime FinOps & User Grant Trap**](/case-studies/17-downsizing-cloud-sql-dms-user-grants.md) | 25 TB ➔ 700 GB<br>(97% Reduction) | GCP DMS (CDC)<br>MySQL 8 Default Roles | Bypassed 4-hour downtime window; | resolved cutover privilege traps with zero secret rotation.
- [The Missing Quote Mark That Threatened to Melt Our Production Database**](/case-studies/16-missing-quote-mark-implicit-type-conversion.md) | 7M+ Rows<br>Core Customer DB | MySQL InnoDB MVCC<br>Sargability & Locking | Prevented full-table scan outage; implemented 2-phase non-locking PK mutation pattern.
- [Adding Secondary Indexes to a 96M-Row Table With Parent-Side Foreign Keys](/case-studies/18-Adding%20Secondary%20Indexes%20to%20a%2096M-Row%20Table%20With%20Parent-Side%20Foreign%20Keys.md) — how a critical 96M-row card transaction migration was blocked by parent-side foreign keys from a 61M-row child table, and how I bypassed rename-based online schema change limits to execute a safe native `ALGORITHM=INPLACE` index build in 35 minutes under live payment traffic with zero DML locking.
-  [Multi-Terabyte Migration: AWS Aurora MySQL 8.0 to MySQL 8.4 on AWS Outposts](case-studies/19-Multi-Terabyte%20Migration%20from%20AWS%20Aurora%20MySQL%208.0%20to%20Outposts%20RDS%20(MySQL%208.4).md) — how we migrated 2.55 billion rows from AWS Aurora MySQL 8.0 to MySQL 8.4 on AWS Outposts using MySQL Shell and S3-based staging, excluded 63 historical archive tables, recovered from a mid-load network interruption, and validated row counts, database objects, and application transactions.
- [Cross-Engine Migration from MySQL 8.4 to PostgreSQL 17 on AWS Outposts](case-studies/20-cross-engine-migration-from-mysql-8.4-to-postgresql-17-on-outposts.md) — how we executed a cross-engine schema and data transformation from MySQL 8.4 to PostgreSQL 17 on AWS Outposts using AWS SCT and AWS DMS, resolved sequence defaults and identifier casing mismatches, and validated data parity across cross-database paradigms.
- [Multi-Database Migration: AWS Aurora PostgreSQL to AWS Outposts RDS via S3 Staging](case-studies/21-AWS%20Aurora%20PostgreSQL%20to%20AWS%20Outposts%20RDS%20Migration.md) — how we decoupled cross-network PostgreSQL dumps across hybrid cloud boundaries using `pg_dump` directory format (`-Fd`), staged archives through Amazon S3, resolved PostgreSQL 17 binary header incompatibilities (`1.16`), and fixed role reassignment traps (`SET ROLE ""`) with zero data loss.


- More coming soon.

## Reusable Scripts

Practical, battle-tested scripts referenced in the case studies above, generalized for reuse.

- [scripts/partition-switch-proc.sql](scripts/partition-switch-proc.sql) — the partition-switch archiving procedure referenced in case study #1
- [scripts/dms-self-healing-lambda.py](scripts/dms-self-healing-lambda.py) — the self-healing Lambda referenced in case study #2
- [scripts/mysql-lock-wait-capture.sql](scripts/mysql-lock-wait-capture.sql) — lock-wait/blocking-chain capture, referenced in case study #3
- [scripts/mysql-query-digest-baseline.sql](scripts/mysql-query-digest-baseline.sql) — query-digest baseline snapshotting, referenced in case study #3
- [scripts/docdb-environment-template.yaml](scripts/docdb-environment-template.yaml) — decoupled YAML configuration template for modular DocumentDB imports, referenced in case study #4
- [scripts/aurora-environment-template.yaml](scripts/aurora-environment-template.yaml) — decoupled YAML configuration template for modular Aurora MySQL imports, referenced in case study #4
- [scripts/traffic-light-dashboard.sql](scripts/traffic-light-dashboard.sql) -traffic light query, refernced in case #5
- [`scripts/gh-ost-production-migration-runner.sh`](case-studies/scripts/gh-ost-production-migration-runner.sh) — the production-safe gh-ost wrapper referenced in case study #6, with duplicate-run protection, secure credential handling, and replica-lag-aware throttling builtin.
- [`scripts/gh-ost-multi-table-sequential-orchestrator.sh`](case-studies/scripts/gh-ost-multi-table-sequential-orchestrator.sh) — reusable sequential multi-table gh-ost orchestration with stale-socket cleanup and dependency-ordered execution
-  [`scripts/dms-postgres-task-config-example.yaml`](case-studies/scripts/ms-postgres-task-config-example.yaml) — complete, redacted reference DMS configuration for PostgreSQL logical replication, referenced in case study #9
-  [scripts/rollback_reconciliation_new.py](case-studies/scripts/rollback-reconciliation.py) — multi-stage MySQL target-delta extraction, staging, classification, and verification reconciliation tool referenced in case study #11
- [case-studies/scripts/pool-replenish/](case-studies/scripts/pool-replenish) — replica-aware pool monitoring Python orchestrator and micro-batched MySQL stored procedure for safe account recycling, referenced in case study #12
- [case-studies/scripts/pool-replenish/watchdog/](case-studies/scripts/pool-replenish/watchdog) — non-invasive Python watchdog daemon and automated Markdown RCA report generator, referenced in case study #13

## About Me

Lead Database Engineer with 5+ years architecting and operating large-scale database platforms across AWS, GCP, and Oracle Cloud for high-volume fintech systems. [LinkedIn](https://linkedin.com/in/oluwaseun-oladele-a25196183)
