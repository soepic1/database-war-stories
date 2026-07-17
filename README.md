# Database War Stories

Real production database engineering — the kind of problems that don't have a clean answer in the manual.

I'm Seun, a Lead Database Engineer working across AWS, GCP, and Oracle Cloud, operating large-scale database systems for a high-volume fintech platform processing 150,000+ transactions per minute. This repo is a collection of real production engineering problems I've solved — investigated, root-caused, and fixed — written up in detail for anyone who wants to see the actual thinking behind the fix, not just the headline.

## Case Studies

- [Eliminating a 150M-Row Database Backlog Using Pure Metadata Operations](case-studies/01-partition-switch-migration.md) — how a silent, compounding archival failure grew to 159M unarchived rows on a production payment-switch database, and how I engineered a novel technique to clear the entire backlog in minutes instead of hours, with zero downtime.
- [Building a Self-Healing AWS DMS Replication Pipeline](case-studies/02-dms-self-healing-pipeline.md) — how I eliminated 95% of manual intervention on cross-cloud replication failures with a serverless, stability-aware self-healing system.
- More coming soon.

## Reusable Scripts

Practical, battle-tested scripts referenced in the case studies above, generalized for reuse.

- [scripts/partition-switch-proc.sql](scripts/partition-switch-proc.sql) — the partition-switch archiving procedure referenced in case study #1
- [scripts/dms-self-healing-lambda.py](scripts/dms-self-healing-lambda.py) — the self-healing Lambda referenced in case study #2

## About Me

Lead Database Engineer with 5+ years architecting and operating large-scale database platforms across AWS, GCP, and Oracle Cloud for high-volume fintech systems. [LinkedIn](https://linkedin.com/in/oluwaseun-oladele-a25196183)
