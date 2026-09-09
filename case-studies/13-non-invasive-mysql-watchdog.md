## The Silent Lock Spikes and the $0.00 Observability Fix

### The Incident: Death by 1,000 Uncommitted Transactions

It’s 10:18 PM. The on-call phone stays quiet, but Cloud SQL metrics tell a different story: CPU utilization spikes past capacity. Query Insights shows a wall of `COMMIT` statements flooding the database engine.

Standard MySQL slow-query logs show nothing out of the ordinary. CPU usage isn't spiking because of heavy mathematical computations, and disk I/O is normal. Yet downstream services are slowing down.

When we dug into the InnoDB engine metadata, we found the culprit: **Application Connection Pool Leaks (`idle_in_trx`)**.

Microservices like `settlement` and `disbursement_sb` were opening database transactions, updating a row or two, and then sitting completely idle in a `Sleep` state for **up to 3,600 seconds (1 hour)** before issuing a `COMMIT`. They held row locks quietly in memory, completely evading standard slow-query logs because no active SQL statement was executing during that hour.

### Why We Couldn't Just Run Auto-Kill Scripts

The naive fix for `idle_in_trx` sessions is writing a script that issues `KILL <processlist_id>` on any session sleeping longer than 5 minutes.

In a high-volume financial system, **automatically killing database threads is playing Russian roulette with data integrity**. Terminating a payment or settlement thread mid-flight can leave application state machines out of sync, trigger unhandled retry loops, or cause partial state corruption.

We needed a non-invasive solution that provided **100% visibility with 0% risk of breaking production transactions**.

---

### The Solution: Building a Non-Invasive Metadata Watchdog

Instead of terminating connections or relying on heavy third-party agents, we built a lightweight, isolated Python watchdog daemon that polls MySQL metadata tables directly:

1. **`information_schema.innodb_trx`**: To track transaction start times, current state (`RUNNING` vs `Sleep`), and rows locked.
2. **`performance_schema.data_lock_waits`**: To map out active dependency trees and identify which specific thread is blocking downstream queries.

Because these in-memory metadata tables are indexed and extremely small, polling them every 30 to 60 seconds incurs **$<0.1\%$ CPU overhead**—completely imperceptible to database performance.

---

### The Hard Lesson: Taming Alert Fatigue

Our first deployment was technically successful—it caught every long-running transaction. But it created a new problem: **Slack alert spam**.

Because services frequently left harmless, unblocked read transactions open, our monitoring channel was flooded with dozens of alerts for transactions that weren't actually harming system throughput.

We refactored our classification engine to evaluate **lock dependency chains**:

```text
               ┌──────────────────────────────────────────┐
               │  Is the session holding active locks     │
               │  that are blocking downstream threads?   │
               └────────────────────┬─────────────────────┘
                                    │
                     ┌──────────────┴──────────────┐
                     ▼                             ▼
                  [ YES ]                       [ NO ]
                     │                             │
                     ▼                             ▼
        Trigger High/Critical Alert     Log silently to DB audit table
         & Dispatch Slack RCA           (No Slack notification sent)

```

By gating notifications strictly on `blocking_thread_count > 0`, we instantly cut channel noise by over **90%** while ensuring true lock contention was flagged within seconds.

---

### Closing the Loop: Automated Post-Mortems & Safe Cleanup

To make the system self-sustaining, we added two database-native features:

1. **Automated RCA Generation:** When a `CRITICAL` blocking incident resolves, the watchdog automatically parses the incident metrics and posts a formatted Markdown Root Cause Analysis (RCA) directly into Slack. Engineering teams get the exact process ID, offending query snippet, and host IP without manual investigation.
2. **Chunked Database Maintenance:** Rather than letting telemetry tables bloat, we offloaded log pruning to native MySQL Scheduled Events running batched deletes (`DELETE ... LIMIT 1000`) paired with explicit micro-sleeps (`DO SLEEP(0.05)`). This prevents undo log inflation and replica lag.

---

### Key Takeaways for Database Engineers

1. **Slow-query logs only record completed statements.** They are blind to uncommitted transactions sitting idle inside connection pools.
2. **Transaction duration is a misleading alert trigger.** Alert severity should be measured by active lock contention (`blocking_thread_count > 0`), not runtime alone.
3. **Observability doesn't require expensive third-party tools.** Native metadata tables (`innodb_trx` and `data_lock_waits`) provide deep visibility when paired with clean filtering logic.

---

## Technical Quick Start & Deployment Guide

### Associated Scripts & Configs
* [`scripts/pool-replenish/watchdog/slow_query_watchdog.py`](scripts/pool-replenish/watchdog/slow_query_watchdog.py) — Main polling daemon & lock dependency chain evaluator.
* [`scripts/pool-replenish/watchdog/incident_postmortem.py`](scripts/pool-replenish/watchdog/incident_postmortem.py) — Automated Markdown RCA generator.
* [`scripts/pool-replenish/watchdog/watchdog.env.example`](scripts/pool-replenish/watchdog/watchdog.env.example) — Sanitized configuration template.

### Execution
1. Create environment file: `cp watchdog.env.example watchdog.env` and populate DB credentials.
2. Install dependencies: `pip install pymysql requests`
3. Run daemon: `python3 slow_query_watchdog.py`

---

