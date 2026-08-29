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

[ Unbounded UPDATE Query ] ──> [ Multi-Second InnoDB Range Lock ] ──> [ Live API Blocked ]
│
└──> [ Replica Lag Spikes ] ──> [ Out of Memory / Timeout ]

1. **Exclusive Lock Contention:** A direct SQL update like `UPDATE deallocated_accounts SET status = 'AVAILABLE' WHERE ...` scans thousands of pages. InnoDB acquires exclusive row and gap locks, queuing live application write operations behind the long-running transaction.
2. **Replication Lag Cascade:** Bulk updates write massive transaction entries into the binary log all at once. Read replicas processing the stream fall minutes—or hours—behind the Primary DB, corrupting read-heavy routing logic across the platform.
3. **Undo/Redo Log Exhaustion:** Unbounded transactions inflate the InnoDB undo tablespace, causing disk IOPS spikes that starve concurrent application queries.

---

## 3. The Forensic Investigation & Safety Architecture

Before writing a single line of recovery code, we performed a deep-dive analysis of the table geometry and index access paths on `monnify_account_provider.deallocated_accounts`.

### Query Execution Plan Analysis
We identified that historical accounts were bound to specific deallocation timestamps (`account_deallocated_at`). To prevent unindexed full table scans, we leveraged the compound index `idx_provider_deallocated_at` (`provider_code`, `account_deallocated_at`).

To guarantee zero impact on active payment processing, we established **Four Absolute Engineering Guardrails**:

1. **Read-Write Topology Separation:** Inventory counts and historical lookback probes MUST run exclusively against the Read Replica (`35.246.74.141`), preserving Primary DB IOPS.
2. **Replication Safety Circuit Breaker:** The system MUST inspect `Seconds_Behind_Master` before initiating work. If replication lag exceeds 30 seconds, execution immediately aborts.
3. **Fail-Fast Distributed Locking:** The worker MUST acquire a non-blocking MySQL advisory lock (`GET_LOCK('monnify_pool_replenish_lock', 0)`) on the Master DB (`8.228.63.88`). If another job is running, it exits instantly without queueing.
4. **Decoupled Snapshotting with Micro-Commits:** The stored procedure MUST copy target primary keys into an in-memory temporary table first, then process updates in strict **1,000-row chunks**, committing each chunk independently and sleeping `50ms` between iterations.

---

## 4. The Engineering Solution

We built a two-tier automated pipeline consisting of a **Python Orchestrator** and a **Micro-Batched MySQL Stored Procedure**.

 AUTOMATION ARCHITECTURE
                       
        AUTOMATION ARCHITECTURE
                       
             +------------------------------------------+
             |       Cron Job (Every 4 Hours)           |
             +------------------------------------------+
                                  |
                                  v
+--------------------+  1. Probe Inventory & Lag   +--------------------+
|                    | --------------------------> |    Read Replica    |
|                    | <-------------------------- |   (35.246.74.141)  |
|   Python Worker    |    Available < Watermark    +--------------------+
| (pool_replenish.py)|
|                    |  2. Acquire Advisory Lock   +--------------------+
|                    |  & Execute Stored Proc      |     Master DB      |
|                    | --------------------------> |   (8.228.63.88)    |
+--------------------+ <-------------------------- +--------------------+
Completed 100k Recycles


## 5. Deployment & Production Validation
The pipeline was deployed with a 4-hour cron schedule, dynamically loading environment configurations and capturing detailed log traces:

Code snippet
0 */4 * * * export $(cat /home/oluwaseun.oladele/scripts/pool_replenish/.env | xargs); /usr/bin/python3 /home/o/scripts/pool_replenish/pool_replenish.py >> /home/o/scripts/pool_replenish/pool_replenish.log 2>&1
