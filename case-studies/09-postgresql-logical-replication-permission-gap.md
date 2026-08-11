# The Missing Privilege AWS's Own Documentation Didn't Mention

**TL;DR:** Setting up cross-cloud PostgreSQL logical replication (Aurora → on-premises Outpost via AWS DMS) failed repeatedly at the exact same point — establishing a consistent CDC starting point — despite methodically fixing every documented prerequisite. The actual root cause, found with AWS Support: the replication user needed schema *ownership*, not just the standard recommended privilege grants.

## The Problem
Migrating a PostgreSQL database from AWS Aurora to on-premises infrastructure via AWS DMS kept failing during CDC startup with a generic, unhelpful error: "Failure in starting (with TXN consistency...)". No specific root cause, just a wall.

## The Investigation — a genuine, methodical elimination process
Over several days, each of these was checked, found wanting, and fixed in turn:
- `wal_level` not set to `logical` — fixed via the `rds.logical_replication` parameter and a cluster restart
- The `pglogical` extension not installed — fixed via `shared_preload_libraries` and `CREATE EXTENSION`
- An orphaned replication slot from an earlier failed attempt — found and dropped
- A duplicate rule ID in the DMS task's table mapping — fixed
- A plugin name mismatch between the endpoint config and what was actually set up on the database — corrected
- `TransactionConsistencyTimeout` set to an unintended value — reverted

Every one of these was a real, legitimate issue. None of them were *the* issue.

## The Actual Fix
With AWS Support, the true root cause emerged: the dedicated replication user — created following AWS's own documented best practice, granted the `rds_replication` role and standard schema usage — still wasn't sufficient for `pglogical`'s specific internal operations. The fix required explicit schema ownership:

```sql
ALTER SCHEMA public OWNER TO dms_user;
GRANT ALL ON SCHEMA public TO dms_user;
GRANT ALL ON DATABASE ptsp_postgres_db TO dms_user;
```

This turned out to be a known issue reported by others on AWS's own community forums — not something obviously covered in the primary setup documentation.

## The Outcome
Full load completed successfully across 129 tables, CDC replication running cleanly, confirmed via AWS DMS's own task monitoring.

## Broader Takeaways
- **Methodical elimination has real value even when it doesn't immediately find the answer** — every ruled-out cause narrowed the search and produced genuine, necessary fixes along the way.
- **"Least privilege" sometimes needs iteration, not just careful upfront design** — especially for less common replication mechanisms where the documented privilege list may not cover every internal operation.
- **Vendor support escalation is a legitimate tool, not a failure** — after exhausting self-service diagnosis, getting AWS's own visibility into internal behavior was what actually resolved this.

---
*[Connect with me on LinkedIn](https://linkedin.com/in/oluwaseun-oladele-a25196183) if you've hit similar AWS DMS/PostgreSQL replication gotchas.*
```
