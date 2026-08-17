# Isolate First, Fix Root Cause Second: Correcting a Month-Long Incident Theory With Evidence

**TL;DR:** A senior stakeholder attributed weeks of recurring database instability to "still recovering from a failover." Rigorous, evidence-based investigation proved that theory wrong, traced the real cause to a specific application-level deadlock, and led to a pragmatic architectural decision — isolate the problematic workload first, hold the application team accountable for the actual fix second — that immediately and measurably stabilized the platform.

## The Problem

Following a production failover on July 7th (itself triggered by a slow, unindexed query), a senior engineering leader raised a working theory: ongoing instability in the weeks since was the database "still recovering" from that event. The instinct was reasonable — but reasonable isn't the same as correct, and correcting it required real evidence, not just disagreement.

## The Investigation

**Step 1 — check the plausible theory against real data.** Reviewed the actual GCP HA failover mechanics (a genuinely relevant, non-obvious detail about how synchronous storage replication differs from a typical always-on replica), then checked the specific cache metrics the theory depended on — hit rate, overflow counters. They came back healthy. That specific mechanism wasn't the cause.

**Step 2 — go back to the raw data with more precision.** Plotting memory usage across a full two-month window revealed something the initial glance missed: **two distinct episodes**, not one continuous problem. The first matched the failover timing exactly and fully resolved within two weeks. A second, separate episode started weeks later — with no failover event anywhere near it.

**Step 3 — cross-reference against documented incidents.** The second episode's exact timestamps matched real, already-documented RCA reports for unrelated slow-query incidents — not a lingering infrastructure issue at all.

**Step 4 — find the smoking gun.** Live diagnostics (`SHOW ENGINE INNODB STATUS`) caught an actual, timestamped deadlock — two application operations (claiming vs. releasing resources) fighting over the same rows on the exact table already under suspicion.

**Step 5 — take the follow-up hypothesis seriously too.** When further, more sophisticated diagnostics were requested (checking for a specific deadlock-detection mutex contention pattern), the right response wasn't defensiveness — it was building genuinely better tooling: log-based crash detection (which revealed the existing monitoring was missing 10 of 11 real crashes), and a new early-warning detector for a subtle "global stall" signature.

## The Decision

Rather than waiting for the application team's fix (already in progress, but not yet shipped) or continuing to debate root cause theoretically, the pragmatic move was architectural: **migrate the specific problematic schema onto its own, dedicated instance** — protecting the core platform immediately, while keeping pressure on the actual application-level bug fix as a separate, ongoing workstream.

## The Outcome

The before/after is unambiguous: the main instance's CPU/memory pattern — spiky and erratic through weeks of investigation — flattens completely from the moment of migration onward. The new dedicated instance, running on a quarter of the compute, handles the exact same workload at near-zero load. The workload was never "too heavy" — it was fighting for shared resources with everything else.


**Before decoupling — main instance (128 vCPU):**
<img width="2792" height="1454" alt="providerpool" src="https://github.com/user-attachments/assets/bbfbc97e-ae92-4f23-98db-de068861a247" />

**After decoupling — dedicated instance (32 vCPU), same workload:**
[Dedicated instance CPU load after decoupling, showing near-zero utilization]
<img width="2880" height="1738" alt="maindb" src="https://github.com/user-attachments/assets/0eab591c-a34f-44a3-a10b-7251256bf04e" />



## Broader Takeaways

- **A senior stakeholder's plausible theory still needs evidence, not just deference or argument.** Being right required data, not authority on either side.
- **"Isolate first, fix root cause second" is a legitimate architectural response to sustained instability** — it's not avoiding the real fix, it's bounding the blast radius while the real fix is still in flight.
- **Building monitoring in response to one incident pays off structurally, not just tactically** — the crash-detection gap found along the way (missing 10 of 11 real incidents) will matter for every future incident, not just this one.

---
*[Connect with me on LinkedIn](https://linkedin.com/in/oluwaseun-oladele-a25196183) if you're navigating similar incident-response and stakeholder-alignment challenges.*
