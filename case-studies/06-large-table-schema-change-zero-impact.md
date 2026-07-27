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


