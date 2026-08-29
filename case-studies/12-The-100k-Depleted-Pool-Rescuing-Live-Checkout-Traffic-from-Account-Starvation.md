# Case Study: The 100k Depleted Pool: Rescuing Live Checkout Traffic from Account Starvation

## 1. Executive Summary

In virtual-account payment processing, inventory is oxygen. Every time a consumer or business initiates a bank transfer at checkout, the system must assign a dedicated, virtual bank account within milliseconds. If the available pool runs out, payment generation fails immediately, transactions drop, and revenue halts.

Following a period of intense transaction throughput, our virtual account allocation pool for provider `23283` plummeted below safe operational thresholds. The system had burned through its active inventory, leaving over **145,000 historically deallocated accounts** stranded in an unallocated state, while available inventory edged dangerously close to zero.

Restoring this inventory wasn't as simple as running an `UPDATE` statement. Executing massive updates on live, multi-million-row transactional tables during peak business traffic risks catastrophic table locking, thread pool exhaustion, severe replication lag on read replicas, and application-wide lock-wait timeouts (`Error 1205`).

To resolve the crisis without introducing live traffic friction, we engineered a replica-aware, non-blocking automation worker backed by an iterative MySQL stored procedure. The solution safely harvested and recycled **135,995 accounts** back into `AVAILABLE` status in micro-batches of 1,000 rows, operating with zero lock contention and zero application downtime.

---

## 2. The Crisis: The Hidden Cost of Manual Babysitting

### The Operational Nightmare
Maintaining healthy account inventory had devolved into a recurring, high-friction manual operational burden. The failure loop was brutal:

* **The Ticking Clock:** SREs and DBAs had to manually monitor database counts throughout the day. If inventory dipped unexpectedly during off-hours or traffic surges, checkout attempts failed directly in front of end users.
* **The Manual Harvest Grind:** When pools depleted, engineers were forced to run manual ad-hoc SQL updates under severe time pressure to recycle old accounts. 
* **High-Stakes Production Risk:** Executing manual bulk scripts against core database tables during active payment windows felt like diffusing a bomb. One bad `WHERE` clause or an unindexed scan could lock the table, crash live checkout APIs, and trigger a massive incident call.

### The Technical Dilemma
Why is recycling historical accounts in a massive relational database so dangerous?

```text
[ Unbounded UPDATE Query ] ──> [ Multi-Second InnoDB Range Lock ] ──> [ Live API Blocked ]
                                             │
                                             └──> [ Replica Lag Spikes ] ──> [ Out of Memory / Timeout ]

```
Exclusive Lock Contention: A direct SQL update like UPDATE deallocated_accounts SET status = 'AVAILABLE' WHERE ... scans thousands of pages. InnoDB acquires exclusive row and gap locks, queuing live application write operations behind the long-running transaction.

Replication Lag Cascade: Bulk updates write massive transaction entries into the binary log all at once. Read replicas processing the stream fall minutes—or hours—behind the Primary DB, corrupting read-heavy routing logic across the platform.

Undo/Redo Log Exhaustion: Unbounded transactions inflate the InnoDB undo tablespace, causing disk IOPS spikes that starve concurrent application queries.

3. The Forensic Investigation & Safety Architecture
Before writing a single line of recovery code, we performed a deep-dive analysis of the table geometry and index access paths on monnify_account_provider.deallocated_accounts.

Query Execution Plan Analysis
We identified that historical accounts were bound to specific deallocation timestamps (account_deallocated_at). To prevent unindexed full table scans, we leveraged the compound index idx_provider_deallocated_at (provider_code, account_deallocated_at).

To guarantee zero impact on active payment processing, we established Four Absolute Engineering Guardrails:

Read-Write Topology Separation: Inventory counts and historical lookback probes MUST run exclusively against the Read Replica (10.0.1.50), preserving Primary DB IOPS.

Replication Safety Circuit Breaker: The system MUST inspect Seconds_Behind_Master before initiating work. If replication lag exceeds 30 seconds, execution immediately aborts.

Fail-Fast Distributed Locking: The worker MUST acquire a non-blocking MySQL advisory lock (GET_LOCK('monnify_pool_replenish_lock', 0)) on the Master DB (10.0.1.10). If another job is running, it exits instantly without queueing.

Decoupled Snapshotting with Micro-Commits: The stored procedure MUST copy target primary keys into an in-memory temporary table first, then process updates in strict 1,000-row chunks, committing each chunk independently and sleeping 50ms between iterations.

---

## 4. The Engineering Solution

We built a two-tier automated pipeline consisting of a **Python Orchestrator** and a **Micro-Batched MySQL Stored Procedure**.

 AUTOMATION ARCHITECTURE
                       

```text
                           AUTOMATION ARCHITECTURE
                           
                 +------------------------------------------+
                 |       Cron Job (Every 4 Hours)           |
                 +------------------------------------------+
                                      |
                                      v
   +--------------------+  1. Probe Inventory & Lag   +--------------------+
   |                    | --------------------------> |    Read Replica    |
   |                    | <-------------------------- |   (10.0.1.50)  |
   |   Python Worker    |    Available < Watermark    +--------------------+
   | (pool_replenish.py)|
   |                    |  2. Acquire Advisory Lock   +--------------------+
   |                    |  & Execute Stored Proc      |     Master DB      |
   |                    | --------------------------> |   (10.0.1.10)    |
   +--------------------+ <-------------------------- +--------------------+
                               Completed 100k Recycles
```


Stored Procedure Pattern (Micro-Batched Commit)
The full DDL deployment script is located in scripts/pool-replenish/batch_update_deallocated_accounts.sql.


-- Core micro-commit loop pattern inside the stored procedure
```
update_loop: LOOP
    SELECT COUNT(*) INTO v_remaining FROM tmp_target_dealloc_accounts;
    IF v_remaining = 0 THEN
        LEAVE update_loop;
    END IF;

    START TRANSACTION;
        UPDATE deallocated_accounts main
        JOIN (
            SELECT account_number, provider_code
            FROM tmp_target_dealloc_accounts
            ORDER BY account_number, provider_code
            LIMIT 1000
        ) batch ON main.account_number = batch.account_number
        SET main.status = 'AVAILABLE', main.merchant_id = NULL;

        DELETE FROM tmp_target_dealloc_accounts LIMIT 1000;
    COMMIT;

    DO SLEEP(0.05); -- Yield lock time back to live checkout traffic
END LOOP update_loop;
```

The Results
135,995 Accounts Recycled: Harvested almost the entire historical backlog of deallocated accounts for provider 23283, building a massive operational safety cushion.

0 Lock-Wait Timeouts: Live checkout traffic experienced zero latency spikes or table lock contention during the entire execution.

100% Operational Relief: Completely eliminated manual SRE/DBA intervention for account pool maintenance. The SRE team officially decommissioned manual pool tracking.

## 6. Key Takeaways & Architectural Lessons
Never UPDATE at Scale in Single Transactions: When operating on tables with millions of rows, unbounded UPDATE statements are ticking time bombs. Always isolate target primary keys into temporary structures and chunk executions in micro-transactions.

Protect the Master with Replica Pre-Flight Probes: Heavy count aggregation queries belong on Read Replicas. Master DB connections should only be established when actionable write work is confirmed.

Respect Operational Human Capital: Engineering time shouldn't be spent babysitting database counts. Building resilient, self-healing background automation restores peace of mind and frees teams to focus on core platform engineering.
