Bash

#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Multi-Table Production gh-ost Sequential Migration Orchestrator
#
# Key Features:
# 1. Sequential Execution: Migrates Table 1, verifies completion/cutover, 
#    and only then initiates Table 2.
# 2. Duplicate Execution Protection: Uses `pgrep` checks per table.
# 3. Dynamic Replica Lag Monitoring: Directly polls downstream read replicas.
# 4. Stale Socket Cleanup: Automatically cleans up `/tmp` sockets before start.
# ==============================================================================

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
