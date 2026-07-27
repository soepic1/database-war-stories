# Orchestrating Safe Sequential Migrations Across Multiple Production Tables

**TL;DR:** Needed to make schema changes to two related production tables within the same maintenance window — additional indexes on an already-migrated 171GB table, plus new columns and indexes on a related table. Rather than run both migrations in parallel, I built a reusable, sequential orchestration pattern that guarantees one migration fully completes before the next begins, incorporating hardening lessons learned from an earlier production run.

## The Problem

Following [an earlier large-table schema change](03-large-table-schema-change-zero-impact.md), two more changes were queued for the same maintenance window: additional indexes on `mandate_request` (supporting new query patterns against a recently-added column), and both new columns *and* indexes on a related `mandate` table. Both needed to land safely within one window.

## The Design Question: Parallel or Sequential?

Running two `gh-ost` migrations in parallel against the same production primary is tempting — it's faster in wall-clock terms. But each `gh-ost` instance only throttles based on the replica lag *it* can observe contributing to. Run two simultaneously, and neither tool has visibility into the other's contribution to total load — a tool correctly pausing at 3 seconds of lag has no way of knowing a second, independent process is also adding load at the same moment. That makes total risk exposure much harder to reason about.

I chose sequential execution instead: one migration runs to full completion — including its cutover — before the next begins. Slower in total wall-clock time, but the system's risk profile at any given moment stays simple and bounded.

## The Solution

Built a reusable bash function wrapping the full `gh-ost` invocation (all the same safety flags as before — replica-lag throttling, panic file, throttle file), parameterized by table name, alter statement, and log paths — so adding a third or fourth table to the sequence going forward is a one-line addition, not a copy-pasted script.

Two additional hardening details, learned directly from running the earlier single-table migration in production:

- **Stale Unix socket cleanup before each run.** `gh-ost` creates a control socket file per migration; a previous interrupted run's leftover socket can otherwise block a fresh attempt from starting cleanly.
- **A tuned `--cut-over-lock-timeout-seconds` value**, giving the final cutover more room to acquire its lock cleanly on a busy table rather than failing on the first attempt.

bash
run_migration() {
    local table=$1
    local alter_stmt=$2
    # ... (full function in scripts/gh-ost-multi-table-sequential-orchestrator.sh)
    rm -f "/tmp/gh-ost.${DATABASE}.${table}.sock"
    gh-ost --host="${PRIMARY_HOST}" --table="${table}" --alter="${alter_stmt}" \
      --throttle-control-replicas="${REPLICAS}" --cut-over-lock-timeout-seconds=10 \
      --execute >> "${log}" 2>&1
}

## The Outcome

- **`mandate_request`** (indexes, ~171GB / 28.26M rows): 1h3m34s total migration time, 418,560 live concurrent changes correctly captured and applied via binlog tailing, cutover duration: **1.03 seconds**
- **`mandate`** (columns + indexes, ~2.2GB / 1.2M rows): 2m13s total migration time, 11 live concurrent changes correctly captured and applied, cutover duration: **2.03 seconds**
- Combined sequential execution: **~1h5m47s total**, comfortably within the maintenance window
- **Combined actual query-blocking impact across both production tables: ~3.06 seconds** — the entirety of the real-world customer-facing footprint for two separate schema changes on a live payment platform
- Zero customer-facing impact, zero incidents, across both migrations



## Broader Takeaways


Parallel isn't always faster in the way that matters. When multiple independent tools are each individually managing risk against a shared resource, sequential execution can be the more genuinely safe choice, even at the cost of total wall-clock time.
Production incidents (or near-misses) are the best source of hardening ideas. The stale-socket cleanup and cutover timeout tuning both came directly from friction encountered running the pattern for real, not from reading documentation in advance.
Build for reuse from the second time you do something, not the fifth. Turning a single-use script into a parameterized function the moment a second table needed the same treatment kept this maintainable.
