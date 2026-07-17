# Building Production Database Observability From Scratch

*TL;DR:* A heavily-loaded production MySQL database had almost no structured visibility beyond simple snapshots of long-running queries — meaning genuine lock contention and performance regressions were invisible until they became full incidents. I built a lightweight observability layer using MySQL's own Performance Schema, requiring no new infrastructure, that turned reactive firefighting into proactive detection.

## The Problem

The existing homegrown monitoring simply polled the process list periodically looking for queries running longer than 10 seconds. That's useful for catching one class of problem — individually slow queries — but completely blind to two others that matter just as much:

1. *Genuine lock contention* — a snapshot of "slow queries" tells you nothing about who is blocking whom, which is exactly the information you need during an active incident.
2. *Concurrency surges* — a flood of individually fast queries can degrade the whole system just as badly as one slow query, but none of them individually cross a "slow" threshold, so they were invisible to the existing monitoring entirely.

## Design Approach

Rather than build something bespoke from scratch, I leaned on MySQL's own Performance Schema — engine-native, low-overhead, and already tracking far more than the homegrown snapshot approach ever could:

- *Explicit lock-wait capture*, joining information_schema.INNODB_TRX with performance_schema.data_lock_waits/data_locks to surface actual blocking relationships — not just "this is slow," but "this specific session is blocking that one, and has been for N seconds."
- *A durable query-digest baseline, periodically snapshotting performance_schema.events_statements_summary_by_digest into persistent history. Performance Schema's own live view is a rolling window — this snapshot mechanism turns it into a real, evolving baseline *per query pattern, so a regression (a normally-200ms query suddenly taking 5s) is detectable against its own history, not against one arbitrary flat threshold that conflates a genuinely slow report query with an actual regression.
- *Retention and pruning built in from day one* — an explicit lesson learned elsewhere this same week: unbounded monitoring tables just become the next capacity problem if nobody plans for their own cleanup.

sql
-- Captures real blocking relationships, not just "this query is slow"
INSERT INTO monitoring.MONIT_LOCK_WAITS (waiting_pid, waiting_query, blocking_pid, blocking_query, wait_age_seconds, ...)
SELECT ...
FROM information_schema.INNODB_TRX r
JOIN performance_schema.data_lock_waits w ON r.trx_id = w.REQUESTING_ENGINE_TRANSACTION_ID
JOIN information_schema.INNODB_TRX b ON w.BLOCKING_ENGINE_TRANSACTION_ID = b.trx_id
WHERE r.trx_state = 'LOCK WAIT';


(Full scripts in scripts/mysql-lock-wait-capture.sql and scripts/mysql-query-digest-baseline.sql)
The Outcome

Went from "we can only see individually slow queries" to being able to answer, in real time, who is blocking whom and is this query pattern behaving normally or regressing against its own history.
This same system directly enabled root-causing a live production incident within days of deployment — see the incident case study.
Feeds real-time Grafana dashboards alongside native cloud metrics, giving the team one place to look during an incident instead of piecing together evidence from scratch under pressure.

Broader Takeaways

Point-in-time snapshots are necessary but not sufficient. They miss both lock-relationship visibility and aggregate baseline behavior entirely — you need explicit mechanisms for each.
A per-query-pattern baseline beats a flat global threshold. "Slower than usual for this specific query" is a fundamentally more useful signal than "slower than 10 seconds," which conflates legitimately long-running queries with genuine regressions.
Build retention into monitoring infrastructure on day one. It's much cheaper to design it in from the start than to retrofit it after the table's already grown into its own incident.


Connect with me on LinkedIn if you're building observability for systems at scale.
