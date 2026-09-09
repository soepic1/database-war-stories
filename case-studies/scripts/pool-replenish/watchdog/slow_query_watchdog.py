
#!/usr/bin/env python3
"""
slow_query_watchdog.py

Continuously polls Cloud SQL / MySQL for long-running / blocking transactions,
logs each "incident" into monitoring.slow_query_incidents, and notifies Slack.

Includes automated resolution post-mortems using incident_postmortem.py,
strictly gated to fire ONLY when active downstream blocking occurred.
This tool NEVER issues KILL. Detection + logging + alerting only.
"""

import os
import time
import signal
import logging
import hashlib
from datetime import datetime, timezone

import pymysql
import pymysql.cursors
import requests

# Import the automated RCA post-mortem generator
from incident_postmortem import generate_rca_report

# ---------------------------------------------------------------------------
# Config (Environment Variables -> Safe Defaults)
# ---------------------------------------------------------------------------
DB_HOST = os.getenv("WATCHDOG_DB_HOST", "127.0.0.1")
DB_PORT = int(os.getenv("WATCHDOG_DB_PORT", "3306"))
DB_USER = os.getenv("WATCHDOG_DB_USER", "slow_query_finder")
DB_PASSWORD = os.getenv("WATCHDOG_DB_PASSWORD", "your_secure_password_here")
DB_SCHEMA = os.getenv("WATCHDOG_DB_SCHEMA", "monitoring")

POLL_INTERVAL_SEC = int(os.getenv("WATCHDOG_POLL_INTERVAL_SEC", "30"))
WARN_TIME_SEC = int(os.getenv("WATCHDOG_WARN_TIME_SEC", "300"))
HIGH_TIME_SEC = int(os.getenv("WATCHDOG_HIGH_TIME_SEC", "600"))
CRITICAL_BLOCK_COUNT = int(os.getenv("WATCHDOG_CRITICAL_BLOCK_COUNT", "2"))
ROWS_LOCKED_WATERMARK = int(os.getenv("WATCHDOG_ROWS_LOCKED_WATERMARK", "50000"))

IGNORE_USERS = {u.strip() for u in os.getenv("WATCHDOG_IGNORE_USERS", "event_scheduler,system user").split(",") if u.strip()}
IGNORE_TAGS = [t.strip() for t in os.getenv("WATCHDOG_IGNORE_TAGS", "job:archival_v2").split(",") if t.strip()]

SLACK_WEBHOOK_URL = os.getenv("WATCHDOG_SLACK_WEBHOOK", "")

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger("slow_query_watchdog")

_shutdown = False

def _handle_signal(signum, frame):
    global _shutdown
    log.info("Received signal %s, shutting down gracefully...", signum)
    _shutdown = True

signal.signal(signal.SIGTERM, _handle_signal)
signal.signal(signal.SIGINT, _handle_signal)

_SEVERITY_RANK = {"LOW": 0, "MEDIUM": 1, "HIGH": 2, "CRITICAL": 3}


# ---------------------------------------------------------------------------
# DB connection
# ---------------------------------------------------------------------------
def get_connection():
    return pymysql.connect(
        host=DB_HOST, port=DB_PORT, user=DB_USER, password=DB_PASSWORD,
        database=DB_SCHEMA, cursorclass=pymysql.cursors.DictCursor,
        connect_timeout=5, read_timeout=10, write_timeout=10, autocommit=True,
    )


# ---------------------------------------------------------------------------
# Detection Queries
# ---------------------------------------------------------------------------
LONG_RUNNING_TRX_SQL = """
    SELECT
        trx.trx_id,
        trx.trx_mysql_thread_id AS processlist_id,
        t.PROCESSLIST_USER      AS db_user,
        t.PROCESSLIST_HOST      AS host,
        t.PROCESSLIST_DB        AS db_name,
        t.PROCESSLIST_COMMAND   AS command,
        trx.trx_state,
        TIMESTAMPDIFF(SECOND, trx.trx_started, NOW()) AS time_sec,
        trx.trx_query           AS query_text,
        trx.trx_rows_locked,
        trx.trx_rows_modified
    FROM information_schema.innodb_trx trx
    LEFT JOIN performance_schema.threads t
           ON t.PROCESSLIST_ID = trx.trx_mysql_thread_id
    WHERE TIMESTAMPDIFF(SECOND, trx.trx_started, NOW()) >= %s
"""

BLOCKING_CHAIN_SQL = """
    SELECT
        r.trx_mysql_thread_id AS blocked_thread,
        b.trx_mysql_thread_id AS blocking_thread
    FROM performance_schema.data_lock_waits w
    JOIN information_schema.innodb_trx b ON b.trx_id = w.BLOCKING_ENGINE_TRANSACTION_ID
    JOIN information_schema.innodb_trx r ON r.trx_id = w.REQUESTING_ENGINE_TRANSACTION_ID
"""

FIND_ACTIVE_SQL = """
    SELECT id, max_time_sec, severity
    FROM slow_query_incidents
    WHERE processlist_id = %s AND status = 'ACTIVE'
    LIMIT 1
"""

INSERT_SQL = """
    INSERT INTO slow_query_incidents
        (processlist_id, trx_id, db_user, host, db_name, command,
         first_detected_at, last_seen_at, max_time_sec, trx_state,
         is_idle_in_trx, rows_locked, rows_modified,
         query_text, query_fingerprint, blocking_thread_count, is_blocking,
         status, severity)
    VALUES
        (%s, %s, %s, %s, %s, %s,
         %s, %s, %s, %s,
         %s, %s, %s,
         %s, %s, %s, %s,
         'ACTIVE', %s)
"""

UPDATE_SQL = """
    UPDATE slow_query_incidents
    SET last_seen_at = %s,
        max_time_sec = GREATEST(max_time_sec, %s),
        trx_state = %s,
        is_idle_in_trx = %s,
        rows_locked = %s,
        rows_modified = %s,
        query_text = %s,
        query_fingerprint = %s,
        blocking_thread_count = %s,
        is_blocking = %s,
        severity = %s
    WHERE id = %s
"""

ACTIVE_IDS_SQL = "SELECT id, processlist_id, severity FROM slow_query_incidents WHERE status = 'ACTIVE'"
RESOLVE_SQL = "UPDATE slow_query_incidents SET status = 'RESOLVED', resolved_at = %s WHERE id = %s"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def classify_severity(time_sec, blocking_count, is_idle_in_trx, rows_locked):
    if blocking_count >= CRITICAL_BLOCK_COUNT:
        return "CRITICAL"
    if blocking_count > 0:
        return "HIGH"
    if is_idle_in_trx and time_sec >= WARN_TIME_SEC and (rows_locked or 0) > 0:
        return "HIGH"
    if time_sec >= HIGH_TIME_SEC:
        return "MEDIUM"
    if rows_locked and rows_locked >= ROWS_LOCKED_WATERMARK:
        return "MEDIUM"
    return "LOW"


def is_ignored(row):
    if row["db_user"] in IGNORE_USERS:
        return True
    text = row.get("query_text") or ""
    return any(tag in text for tag in IGNORE_TAGS)


def fingerprint(text):
    if not text:
        return None
    return hashlib.md5(text.strip()[:500].encode("utf-8")).hexdigest()


def notify_slack(message):
    if not SLACK_WEBHOOK_URL:
        return
    try:
        requests.post(SLACK_WEBHOOK_URL, json={"text": message}, timeout=5)
    except Exception as exc:
        log.warning("Slack notification failed: %s", exc)


# ---------------------------------------------------------------------------
# Main Cycle
# ---------------------------------------------------------------------------
def run_cycle(conn):
    now = datetime.now(timezone.utc)

    with conn.cursor() as cur:
        cur.execute(LONG_RUNNING_TRX_SQL, (WARN_TIME_SEC,))
        rows = cur.fetchall()

        cur.execute(BLOCKING_CHAIN_SQL)
        blocking_rows = cur.fetchall()

    blocking_counts = {}
    for r in blocking_rows:
        blocking_counts[r["blocking_thread"]] = blocking_counts.get(r["blocking_thread"], 0) + 1

    seen_pids = set()

    with conn.cursor() as cur:
        for row in rows:
            pid = row["processlist_id"]
            if pid is None:
                continue
            seen_pids.add(pid)

            if is_ignored(row):
                continue

            blocking_count = blocking_counts.get(pid, 0)
            is_idle = 1 if (row["command"] == "Sleep" and row["trx_state"] == "RUNNING") else 0
            severity = classify_severity(row["time_sec"], blocking_count, is_idle, row["trx_rows_locked"])
            fp = fingerprint(row["query_text"])

            cur.execute(FIND_ACTIVE_SQL, (pid,))
            existing = cur.fetchone()

            if existing:
                cur.execute(UPDATE_SQL, (
                    now, row["time_sec"], row["trx_state"], is_idle,
                    row["trx_rows_locked"], row["trx_rows_modified"],
                    row["query_text"], fp, blocking_count, int(blocking_count > 0),
                    severity, existing["id"],
                ))
                # Alert on escalation ONLY if blocking > 0 or CRITICAL
                if _SEVERITY_RANK[severity] > _SEVERITY_RANK[existing["severity"]]:
                    if blocking_count > 0 or severity == "CRITICAL":
                        notify_slack(
                            f":rotating_light: Incident #{existing['id']} escalated to *{severity}* "
                            f"(pid={pid}, user={row['db_user']}, time={row['time_sec']}s, "
                            f"blocking={blocking_count}, idle_in_trx={bool(is_idle)})"
                        )
            else:
                cur.execute(INSERT_SQL, (
                    pid, row["trx_id"], row["db_user"], row["host"], row["db_name"], row["command"],
                    now, now, row["time_sec"], row["trx_state"],
                    is_idle, row["trx_rows_locked"], row["trx_rows_modified"],
                    row["query_text"], fp, blocking_count, int(blocking_count > 0),
                    severity,
                ))
                new_id = cur.lastrowid

                # STRICT INITIAL ALERT FILTER: Alert only if blocking > 0 or CRITICAL
                if blocking_count > 0 or severity == "CRITICAL":
                    notify_slack(
                        f":warning: New slow-transaction incident #{new_id} — *{severity}*\n"
                        f"user={row['db_user']} host={row['host']} db={row['db_name']} "
                        f"pid={pid} time={row['time_sec']}s blocking={blocking_count} "
                        f"idle_in_trx={bool(is_idle)} rows_locked={row['trx_rows_locked']}\n"
                        f"```{(row['query_text'] or '(no active statement — idle in transaction)')[:400]}```"
                    )

        # Resolution Loop + Strictly Gated RCA Post-Mortem
        cur.execute(ACTIVE_IDS_SQL)
        for a in cur.fetchall():
            if a["processlist_id"] not in seen_pids:
                cur.execute(RESOLVE_SQL, (now, a["id"]))
                
                # Check whether the incident caused active downstream blocking
                cur.execute("SELECT blocking_thread_count FROM slow_query_incidents WHERE id = %s", (a["id"],))
                inc_data = cur.fetchone()
                has_blocking = inc_data and (inc_data.get("blocking_thread_count") or 0) > 0

                # AUTOMATED RCA POST-MORTEM GUARD: Send to Slack ONLY if blocking > 0 or CRITICAL
                if has_blocking or a["severity"] == "CRITICAL":
                    try:
                        rca_md = generate_rca_report(a["id"])
                        if "RCA" in rca_md:
                            notify_slack(f"```\n{rca_md}\n```")
                    except Exception as rca_exc:
                        log.warning("Failed to dispatch RCA post-mortem for incident #%s: %s", a["id"], rca_exc)

    conn.commit()


def main():
    log.info(
        "Starting slow query watchdog (poll=%ss warn=%ss high=%ss critical_block=%s)",
        POLL_INTERVAL_SEC, WARN_TIME_SEC, HIGH_TIME_SEC, CRITICAL_BLOCK_COUNT,
    )
    while not _shutdown:
        conn = None
        try:
            conn = get_connection()
            run_cycle(conn)
        except pymysql.err.MySQLError as exc:
            log.error("MySQL error during cycle: %s", exc)
        except Exception:
            log.exception("Unexpected error during cycle")
        finally:
            if conn:
                try:
                    conn.close()
                except Exception:
                    pass

        for _ in range(POLL_INTERVAL_SEC):
            if _shutdown:
                break
            time.sleep(1)

    log.info("Watchdog stopped.")


if __name__ == "__main__":
    main()
