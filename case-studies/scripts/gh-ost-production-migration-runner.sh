#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Production-Safe gh-ost Migration Runner
# Case Study: Zero-Downtime Schema Change on 170GB+ Table (28M+ Records)
#
# Key Safety & Architecture Features:
# 1. Secret Masking: Credentials stored in secured config file (chmod 600).
# 2. Concurrency Guard: Prevents duplicate execution if process is active.
# 3. Emergency Intercepts: Pre-configured panic file for instant abortion.
# 4. Cron Throttling: Managed execution window via throttle flag file.
# 5. Dynamic Replication Guard: Directly monitors downstream read replicas.
# ==============================================================================

# --- Configuration & Paths ---
TABLE_NAME="table_name"
DATABASE_NAME="database_name"

# Secrets file (chmod 600) containing DB user and password
CONF_FILE="/etc/gh-ost/${TABLE_NAME}.conf"

LOG_FILE="/var/log/gh-ost_${TABLE_NAME}.log"
PANIC_FILE="/tmp/ghost_${TABLE_NAME}.panic"
THROTTLE_FILE="/tmp/ghost_${TABLE_NAME}.throttle"

PRIMARY_HOST="<production_primary_host>"
REPLICA_HOSTS="<replica_1_host>:3306,<replica_2_host>:3306"

# --- 1. Prevent Duplicate Execution ---
if pgrep -f "gh-ost.*${TABLE_NAME}" > /dev/null; then
    echo "[!] ERROR: A gh-ost process for '${TABLE_NAME}' is already running. Exiting."
    exit 1
fi

echo "========================================================================="
echo " Initiating gh-ost Migration for ${DATABASE_NAME}.${TABLE_NAME}"
echo " Time: $(date)"
echo " Log Location: ${LOG_FILE}"
echo " Panic File (Emergency Abort): touch ${PANIC_FILE}"
echo " Throttle File (Pause/Resume): touch/rm ${THROTTLE_FILE}"
echo "========================================================================="

# --- 2. Execute gh-ost Background Process ---
gh-ost \
  --host="${PRIMARY_HOST}" \
  --port=3306 \
  --conf="${CONF_FILE}" \
  --database="${DATABASE_NAME}" \
  --table="${TABLE_NAME}" \
  --alter="ADD COLUMN provider_transaction_reference VARCHAR(255), ADD COLUMN provider_response_code VARCHAR(255), ADD COLUMN provider_response_message TEXT" \
  --allow-on-master \
  --assume-rbr \
  --chunk-size=3000 \
  --dml-batch-size=30 \
  --max-load=Threads_running=60 \
  --critical-load=Threads_running=100 \
  --max-lag-millis=3000 \
  --throttle-control-replicas="${REPLICA_HOSTS}" \
  --throttle-additional-flag-file="${THROTTLE_FILE}" \
  --panic-flag-file="${PANIC_FILE}" \
  --verbose \
  --execute >> "${LOG_FILE}" 2>&1 &

GHOST_PID=$!

echo "[+] Migration initiated successfully in background with PID: ${GHOST_PID}"
echo "========================================================================="
