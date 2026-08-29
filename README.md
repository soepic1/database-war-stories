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
-  [scripts/rollback_reconciliation_new.py](scripts/rollback_reconciliation_new.py) — multi-stage MySQL target-delta extraction, staging, classification, and verification reconciliation tool referenced in case study #11

## About Me

Lead Database Engineer with 5+ years architecting and operating large-scale database platforms across AWS, GCP, and Oracle Cloud for high-volume fintech systems. [LinkedIn](https://linkedin.com/in/oluwaseun-oladele-a25196183)
