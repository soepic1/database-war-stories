#!/usr/bin/env python3
"""
incident_postmortem.py

Pulls resolved CRITICAL/HIGH incidents from monitoring.slow_query_incidents
and generates formatted markdown RCA reports.
"""

import os
import sys
import pymysql
import pymysql.cursors

# Load environment configuration from watchdog.env if present
ENV_PATH = os.getenv("WATCHDOG_ENV_PATH", "watchdog.env")
if os.path.exists(ENV_PATH):
    with open(ENV_PATH) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, val = line.split("=", 1)
                os.environ.setdefault(key.strip(), val.strip())

DB_HOST = os.getenv("WATCHDOG_DB_HOST", "127.0.0.1")
DB_PORT = int(os.getenv("WATCHDOG_DB_PORT", "3306"))
DB_USER = os.getenv("WATCHDOG_DB_USER", "slow_query_finder")
DB_PASSWORD = os.getenv("WATCHDOG_DB_PASSWORD", "your_secure_password")
DB_SCHEMA = os.getenv("WATCHDOG_DB_SCHEMA", "monitoring")

def generate_rca_report(incident_id):
    conn = pymysql.connect(
        host=DB_HOST, port=DB_PORT, user=DB_USER, password=DB_PASSWORD,
        database=DB_SCHEMA, cursorclass=pymysql.cursors.DictCursor
    )
    
    with conn.cursor() as cur:
        cur.execute("SELECT * FROM slow_query_incidents WHERE id = %s", (incident_id,))
        row = cur.fetchone()

    conn.close()

    if not row:
        return f"Incident #{incident_id} not found in database."

    query_snippet = row['query_text'] or '-- No active statement running (Session was idle inside an uncommitted transaction)'

    report = []
    report.append(f"# 🚨 Root Cause Analysis (RCA) - Incident #{row['id']}\n")
    report.append("## Executive Summary")
    report.append(f"* **Severity:** `{row['severity']}`")
    report.append(f"* **Database User:** `{row['db_user']}`")
    report.append(f"* **Client Host:** `{row['host']}`")
    report.append(f"* **Database Name:** `{row['db_name']}`")
    report.append(f"* **First Detected:** `{row['first_detected_at']}`")
    report.append(f"* **Resolved At:** `{row['resolved_at']}`")
    report.append(f"* **Max Active Duration:** `{row['max_time_sec']} seconds`")
    report.append("\n---\n")
    report.append("## Technical Impact & Lock Metrics")
    report.append(f"* **Total Blocked Threads:** `{row['blocking_thread_count']}`")
    report.append(f"* **Idle-in-Transaction State:** `{bool(row['is_idle_in_trx'])}`")
    report.append(f"* **InnoDB Rows Locked:** `{row['rows_locked']}`")
    report.append(f"* **InnoDB Rows Modified:** `{row['rows_modified']}`")
    report.append("\n---\n")
    report.append("## Offending Query Statement")
    report.append("```sql")
    report.append(query_snippet)
    report.append("```")
    report.append("\n---\n")
    report.append("## Action Items & Next Steps")
    report.append(f"- [ ] Review connection pool timeouts for `{row['db_user']}` on host `{row['host']}`.")
    report.append("- [ ] Check application transaction boundaries to prevent uncommitted idle states.")
    report.append("- [ ] Verify query execution plan (`EXPLAIN`) if `rows_locked` > 10000.")

    return "\n".join(report)

if __name__ == "__main__":
    target_id = sys.argv[1] if len(sys.argv) > 1 else 1
    print(generate_rca_report(target_id))
