# Adding Columns to a 171GB Production Table With Just Over One Second of Impact

**TL;DR:** Needed to add three columns to an actively-written, 171GB production table without disrupting live transactions or lagging a downstream replica a critical analytics pipeline depends on. Native MySQL schema-change tooling either got rejected outright or would have taken over an hour with real risk. Engineered a replica-lag-aware online schema change instead, validated rigorously on a production clone first, and executed on production with just 1.06 seconds of actual query blocking across 28 million rows.

## The Problem

A 171GB, high-write production table needed three new columns added to support a new provider integration. On a table this size and this actively used, "just run an ALTER" is exactly the kind of decision that turns into an incident.

## The Investigation

**First attempt: MySQL 8.0's native `ALGORITHM=INSTANT`** — a metadata-only operation that should complete in milliseconds regardless of table size. Tested directly on a production clone first: MySQL rejected it (this table's schema history made it ineligible), forcing a fallback to `ALGORITHM=INPLACE`. Tested that too: **70 minutes**, and while `LOCK=NONE` allows concurrent reads/writes, an operation that long on a table this size generates real sustained load — a genuine risk to both live transaction latency and, critically, to a downstream read replica a real-time analytics pipeline depends on.

Duration alone wasn't the only concern — **any approach risking meaningful replica lag was unacceptable**, given what depends on that replica staying current.

## The Solution

Used `gh-ost` (GitHub's online schema change tool) instead of a direct `ALTER`: it builds a shadow table, copies data in small throttled batches while tailing the binlog to capture live concurrent changes, then performs the actual schema swap via a near-instant atomic rename at the very end.

The critical detail: configured `--throttle-control-replicas` to explicitly monitor the **exact** production replica the analytics pipeline reads from — not a generic internal proxy metric — so the migration would automatically pause the instant that specific replica fell behind, rather than trusting an indirect signal.

bash
gh-ost \
  --host=<production_primary> --port=3306 \
  --database=<database> --table=mandate_request \
  --alter="ADD COLUMN provider_transaction_reference VARCHAR(255), ADD COLUMN provider_response_code VARCHAR(255), ADD COLUMN provider_response_message TEXT" \
  --allow-on-master --assume-rbr \
  --chunk-size=4000 --max-load=Threads_running=35 --critical-load=Threads_running=60 \
  --max-lag-millis=3000 \
  --throttle-control-replicas=<replica_1>:3306,<replica_2>:3306 \
  --panic-flag-file=<path> --throttle-additional-flag-file=<path> \
  --execute

  Every part of this — timing, the replica-lag-flag's actual connectivity, and the final cutover behavior — was validated against a full production clone before this ever touched real production.

The Outcome
28,004,916 rows migrated in 1 hour 1 minute
324,449 live concurrent changes correctly captured and applied via binlog tailing during the migration
Final cutover: 1.06 seconds of actual query blocking
Replica lag stayed under 50 milliseconds throughout
Zero customer-facing impact, zero incidents
Broader Takeaways
Never assume a "fast" native schema-change algorithm applies — test it directly first, eligibility rules are more particular than they appear.
For any schema change on a large, actively-written table, "will this affect a downstream replica" deserves the same seriousness as "will this lock the table."
Testing against a genuine production clone isn't optional at this scale — it's the difference between a real answer and a guess.



🔄 Phase 2: Automated Sequential Multi-Table Orchestration
Following the initial column additions on mandate_request, a second phase was required to add missing secondary composite indexes to mandate_request (~171GB) and apply schema alterations to the related mandate table (~2.2GB).

To execute both table migrations in a single maintenance window without requiring manual intervention or running concurrent jobs that could overload database threads, we engineered an automated sequential runner: scripts/run-phase2-orchestration.sh.

Implementation Note:

The orchestration script intentionally runs gh-ost in the foreground for Table 1 and blocks until the atomic table swap is completely finished before invoking Table 2. It also includes pre-flight checks (pgrep execution guards and stale /tmp/*.sock file cleanups) to ensure reliable background execution via automated crontab schedulers.

Orchestration Script (scripts/run-phase2-orchestration.sh)

Bash
#!/usr/bin/env bash
set -euo pipefail

# --- Global Database Connection Configs ---
PRIMARY_HOST="<production_primary_host>"
PRIMARY_PORT="3306"
DB_USER="<gh_ost_db_user>"
DB_PASS="<gh_ost_db_password>"
DATABASE="<production_database>"
REPLICAS="<replica_1_host>:3306,<replica_2_host>:3306"

run_migration() {
    local table=$1
    local alter_stmt=$2
    local log=$3
    local panic=$4
    local throttle=$5

    # Guard against duplicate active executions for the same table
    if pgrep -f "gh-ost.*--table=${table} " > /dev/null; then
        echo "[!] gh-ost for '${table}' is already running - skipping duplicate start."
        return 0
    fi

    echo "========================================================================="
    echo " Starting gh-ost migration for table: ${DATABASE}.${table}"
    echo " Time: $(date)"
    echo " Log File: ${log}"
    echo " Emergency Panic File: touch ${panic}"
    echo " Manual Pause Flag: touch ${throttle}"
    echo "========================================================================="

    # Pre-flight cleanup of stale Unix sockets for this table
    rm -f "/tmp/gh-ost.${DATABASE}.${table}.sock"

    # Execute gh-ost in foreground (blocks until table swap completes)
    gh-ost \
      --host="${PRIMARY_HOST}" \
      --port="${PRIMARY_PORT}" \
      --user="${DB_USER}" \
      --password="${DB_PASS}" \
      --database="${DATABASE}" \
      --table="${table}" \
      --alter="${alter_stmt}" \
      --allow-on-master \
      --assume-rbr \
      --chunk-size=3000 \
      --dml-batch-size=30 \
      --max-load=Threads_running=70 \
      --critical-load=Threads_running=150 \
      --cut-over-lock-timeout-seconds=10 \
      --max-lag-millis=3000 \
      --throttle-control-replicas="${REPLICAS}" \
      --throttle-additional-flag-file="${throttle}" \
      --panic-flag-file="${panic}" \
      --verbose \
      --execute >> "${log}" 2>&1

    echo "========================================================================="
    echo " Successfully completed gh-ost migration for table: ${DATABASE}.${table}"
    echo " Finished Time: $(date)"
    echo "========================================================================="
}

# ==============================================================================
# MAIN EXECUTION SEQUENCE
# ==============================================================================

# --- STEP 1: mandate_request Indexes (~171 GB / 28M+ Records) ---
run_migration "mandate_request" \
  "ADD INDEX idx_mandate_request_provider_txn_ref (provider_transaction_reference), ADD INDEX IDX_mandate_request_type_status_created_on (mandate_request_type, mandate_request_status, created_on)" \
  "/var/log/gh-ost_mandate_request_idx.log" \
  "/tmp/ghost_mandate_request_idx.panic" \
  "/tmp/ghost_migration.throttle"

# --- STEP 2: mandate Columns + Indexes (~2.2 GB / Multi-Column Alter) ---
# Executed ONLY after Step 1 finishes completely
run_migration "mandate" \
  "ADD COLUMN customer_account_number VARCHAR(10), ADD COLUMN provider_id BIGINT, ADD COLUMN provider_mandate_reference VARCHAR(255), ADD COLUMN customer_bank_code VARCHAR(50), ADD COLUMN customer_email VARCHAR(255), ADD INDEX idx_mandate_customer_account_number (customer_account_number), ADD INDEX idx_mandate_provider_id (provider_id), ADD INDEX idx_mandate_provider_mandate_reference (provider_mandate_reference), ADD INDEX idx_mandate_customer_email (customer_email)" \
  "/var/log/gh-ost_mandate.log" \
  "/tmp/ghost_mandate.panic" \
  "/tmp/ghost_migration.throttle"

echo "========================================================================="
echo " 🎉 ALL PHASE MIGRATIONS FINISHED SUCCESSFULLY AT $(date)"
echo "========================================================================="


Broader Takeaways
Never assume a "fast" native schema-change algorithm applies — test it directly first, eligibility rules are more particular than they appear.

For any schema change on a large, actively-written table, "will this affect a downstream replica" deserves the same seriousness as "will this lock the table."

Testing against a genuine production clone isn't optional at this scale — it's the difference between a real answer and a guess.
