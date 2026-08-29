#!/usr/bin/env python3
"""
Account Pool Auto-Replenishment Orchestrator

Description:
    Monitors virtual account inventory watermarks against a Read Replica.
    When inventory drops below threshold, it executes a lookback ladder search 
    to find the safest historical deallocated accounts and calls a micro-batched 
    stored procedure on the Master DB to safely restore inventory.

Safety Features:
    - Read Replica pre-flight check with replication lag circuit breaker.
    - Advisory locking (GET_LOCK) to prevent multi-instance race conditions.
    - Non-blocking batched stored procedure invocation.
"""

import os
import sys
import time
import logging
import argparse
import pymysql
import requests

# --- Configuration (Loaded via Environment Variables) -------------------------
READ_REPLICA_HOST = os.getenv("MONNIFY_REPLICA_HOST", "135.246.74.141")
WRITE_MASTER_HOST = os.getenv("MONNIFY_MASTER_HOST", "18.228.63.88")
DB_USER = os.getenv("MONNIFY_DB_USER", "pool_replenisher")
DB_PASS = os.getenv("MONNIFY_DB_PASS")
DB_NAME = os.getenv("MONNIFY_DB_NAME", "database_name")
PROVIDER_CODE = os.getenv("PROVIDER_CODE", "23283")

# Thresholds & Limits
LOW_WATERMARK_THRESHOLD = 25_000     # Minimum healthy pool watermark
TARGET_REPLENISH_YIELD  = 100_000    # Target yield per lookback probe
LOOKBACK_LADDER         = [15, 14, 13, 12, 11, 10, 7, 5, 3, 1]  # Days lookback
MAX_ROWS_PER_RUN        = 100_000    # Max rows processed per run
MAX_REPLICA_LAG_SECONDS = 30         # Max tolerable replica lag
PROC_READ_TIMEOUT       = 1800       # 30-minute socket timeout ceiling
ADVISORY_LOCK_NAME      = "monnify_pool_replenish_lock"

SLACK_WEBHOOK_URL  = os.getenv("MONNIFY_SLACK_WEBHOOK")

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s",
)
log = logging.getLogger("pool_replenish")

# --- Helpers -----------------------------------------------------------------
def send_slack_alert(message: str) -> None:
    """Send operational telemetry alerts to Slack webhook."""
    if not SLACK_WEBHOOK_URL:
        log.info("No Slack webhook configured; skipping alert.")
        return
    try:
        requests.post(SLACK_WEBHOOK_URL, json={"text": message}, timeout=5)
    except Exception as e:
        log.error(f"Failed to send Slack alert: {e}")

def connect(host: str, autocommit: bool = False, read_timeout: int = 30):
    """Create database socket connection with DictCursor."""
    return pymysql.connect(
        host=host,
        user=DB_USER,
        password=DB_PASS,
        database=DB_NAME,
        connect_timeout=10,
        read_timeout=read_timeout,
        write_timeout=30,
        autocommit=autocommit,
        cursorclass=pymysql.cursors.DictCursor,
    )

def check_replica_lag(cursor) -> bool:
    """Circuit breaker: Abort if replica lag is high to prevent stale reads."""
    for stmt in ("SHOW REPLICA STATUS", "SHOW SLAVE STATUS"):
        try:
            cursor.execute(stmt)
            row = cursor.fetchone()
            if not row:
                log.warning(f"{stmt} returned no rows; cannot verify lag.")
                return True
            lag = row.get("Seconds_Behind_Source", row.get("Seconds_Behind_Master"))
            if lag is None:
                log.warning("Replica lag is NULL - replication status unverified.")
                return True
            if lag > MAX_REPLICA_LAG_SECONDS:
                log.error(f"Replica lag {lag}s > {MAX_REPLICA_LAG_SECONDS}s. Aborting execution.")
                return False
            log.info(f"Replica lag OK: {lag}s")
            return True
        except (pymysql.err.OperationalError, pymysql.err.InternalError):
            log.warning("Bypassing replica lag check: Managed DB privileges restrict status query.")
            return True
        except pymysql.err.ProgrammingError:
            continue
    return True

def get_available_count(cursor) -> int:
    """Query current available account inventory count."""
    cursor.execute(
        """
        SELECT COUNT(*) AS available_count
        FROM accounts_for_allocation
        WHERE provider_code = %s
          AND status = 'AVAILABLE'
        """,
        (PROVIDER_CODE,),
    )
    return cursor.fetchone()["available_count"]

def probe_rung(cursor, days: int, ceiling: int) -> int:
    """Bounded existence check: Are there at least `ceiling` eligible rows?"""
    cursor.execute(
        """
        SELECT COUNT(*) AS eligible FROM (
            SELECT 1
            FROM deallocated_accounts
            WHERE provider_code = %s
              AND account_deallocated_at < NOW() - INTERVAL %s DAY
              AND merchant_id IS NOT NULL
            LIMIT %s
        ) probe
        """,
        (PROVIDER_CODE, days, ceiling),
    )
    return cursor.fetchone()["eligible"]

def find_viable_cutoff(cursor):
    """Iterate through lookback ladder to select optimal historical cutoff."""
    last_days, last_eligible = None, 0
    for days in LOOKBACK_LADDER:
        eligible = probe_rung(cursor, days, TARGET_REPLENISH_YIELD)
        capped = "+" if eligible >= TARGET_REPLENISH_YIELD else ""
        log.info(f"Lookback {days:>2}d -> {eligible:,}{capped} eligible accounts.")
        last_days, last_eligible = days, eligible
        if eligible >= TARGET_REPLENISH_YIELD:
            log.info(f"Rung {days}d meets target ({TARGET_REPLENISH_YIELD:,}). Selected.")
            return days, eligible
    if last_eligible > 0:
        log.warning(
            f"No rung met target {TARGET_REPLENISH_YIELD:,}. "
            f"Falling back to most aggressive rung {last_days}d ({last_eligible:,} rows)."
        )
        return last_days, last_eligible
    return None, 0

def run_procedure(master_conn, cutoff_days: int):
    """Invoke stored procedure on Primary DB."""
    with master_conn.cursor() as cursor:
        cursor.execute("SELECT NOW() - INTERVAL %s DAY AS cutoff", (cutoff_days,))
        cutoff_dt = cursor.fetchone()["cutoff"]
        log.info(
            f"Calling proc: cutoff={cutoff_dt} (lookback {cutoff_days}d), "
            f"cap={MAX_ROWS_PER_RUN:,}"
        )
        cursor.execute(
            "CALL batch_update_deallocated_accounts("
            "  %s, %s, %s, @total, @iters, @targeted, @status)",
            (PROVIDER_CODE, cutoff_dt, MAX_ROWS_PER_RUN),
        )
        while cursor.nextset():
            pass
        cursor.execute(
            "SELECT @total AS total, @iters AS iters, "
            "       @targeted AS targeted, @status AS status"
        )
        out = cursor.fetchone()
    return (
        int(out["total"] or 0),
        int(out["iters"] or 0),
        int(out["targeted"] or 0),
        out["status"] or "UNKNOWN",
    )

# --- Main Engine -------------------------------------------------------------
def check_and_replenish(dry_run: bool = False, force: bool = False) -> int:
    if not DB_PASS:
        log.error("MONNIFY_DB_PASS not set in environment.")
        return 2

    # Phase 1: REPLICA Inventory Audit
    try:
        replica_conn = connect(READ_REPLICA_HOST, autocommit=True, read_timeout=120)
    except Exception as e:
        log.error(f"Cannot connect to read replica: {e}")
        send_slack_alert(f"🚨 *Pool Replenish* - replica connect failed: `{e}`")
        return 2

    try:
        with replica_conn.cursor() as cursor:
            if not check_replica_lag(cursor):
                return 1
            available = get_available_count(cursor)
            log.info(f"Provider {PROVIDER_CODE}: {available:,} accounts available.")
            
            if available >= LOW_WATERMARK_THRESHOLD and not force:
                log.info(
                    f"Inventory healthy ({available:,} >= {LOW_WATERMARK_THRESHOLD:,}). No action."
                )
                return 0

            cutoff_days, eligible = find_viable_cutoff(cursor)
    finally:
        replica_conn.close()

    if cutoff_days is None:
        msg = f"⚠️ *Monnify Pool LOW - no eligible accounts found for replenishment.*"
        log.error(msg)
        send_slack_alert(msg)
        return 1

    if dry_run:
        log.info(f"[DRY RUN] Would call proc for cutoff {cutoff_days}d (eligible: {eligible:,}).")
        return 0

    # Phase 2: MASTER Execution with Advisory Lock
    master_conn = None
    lock_acquired = False
    started = time.time()
    try:
        master_conn = connect(
            WRITE_MASTER_HOST, autocommit=True, read_timeout=PROC_READ_TIMEOUT
        )
        with master_conn.cursor() as cursor:
            cursor.execute("SELECT GET_LOCK(%s, 0) AS acquired", (ADVISORY_LOCK_NAME,))
            lock_acquired = bool(cursor.fetchone()["acquired"])

        if not lock_acquired:
            log.warning("Another replenishment run holds the advisory lock. Skipping.")
            return 0

        total_updated, iterations, targeted, status = run_procedure(
            master_conn, cutoff_days
        )
        elapsed = time.time() - started

        with master_conn.cursor() as cursor:
            post_available = get_available_count(cursor)
        delta = post_available - available

        msg = (
            f"✅ *Monnify Pool Auto-Replenished*\n"
            f"• Provider: `{PROVIDER_CODE}`\n"
            f"• Pool: `{available:,}` → `{post_available:,}` (Δ `{delta:+,}`)\n"
            f"• Rows updated: `{total_updated:,}` in `{iterations}` batches\n"
            f"• Duration: `{elapsed:.1f}s` | Status: `{status}`"
        )
        log.info(msg)
        send_slack_alert(msg)
        return 0

    except Exception as e:
        msg = f"🚨 *Monnify Pool Replenish FAILED:* `{type(e).__name__}: {e}`"
        log.exception("Replenishment failed.")
        send_slack_alert(msg)
        return 2

    finally:
        if master_conn is not None:
            try:
                if lock_acquired:
                    with master_conn.cursor() as c:
                        c.execute("SELECT RELEASE_LOCK(%s)", (ADVISORY_LOCK_NAME,))
                        log.info("Advisory lock released.")
            except Exception as e:
                log.error(f"Failed to release lock: {e}")
            finally:
                master_conn.close()

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Monnify pool replenisher")
    parser.add_argument("--dry-run", action="store_true", help="Probe without modifying DB.")
    parser.add_argument("--force", action="store_true", help="Force run regardless of watermark.")
    args = parser.parse_args()
    sys.exit(check_and_replenish(dry_run=args.dry_run, force=args.force))
