# Cross-Engine Migration: MySQL 8.4 to PostgreSQL 17 on AWS Outposts

## Executive Summary

A small production service (**17 tables, ~350 MB**) had to move from **MySQL 8.4 on AWS Outposts** to **PostgreSQL 17 on the same Outposts**. The application was already down, the move was a one-off, and the request landed the same evening it had to be done. On paper this was the easy kind of migration: a small database, no CDC, no cutover choreography.

In practice, **every obvious tool hit a different wall**:

- **AWS DMS** was ruled out by topology: with both databases on the Outpost, every row would cross the service link twice.
- **pgloader** failed on both ends: its MySQL driver could not complete a login against MySQL 8.4, and PostgreSQL refused its unencrypted connection.
- **MySQL Shell's dump utility** failed against 8.4 on a removed statement (`SHOW MASTER STATUS`).
- **DBeaver Data Transfer** worked, but only after we turned off its bulk (`COPY`) loader.

We finished by **hand-converting the schema** in two phases (tables first, indexes and foreign keys after the load), moving the data with DBeaver using batched `INSERT`s, and running a post-load script to rebuild indexes, foreign keys and identity sequences. Results:

- **17 tables migrated**, **1 dated snapshot table (~349 MB) excluded**, halving the payload.
- **Row counts validated** per table with exact `COUNT(*)`.
- **Identity sequences reset**, planner statistics refreshed, and an application owner role created with its default schema set.

This case study documents the tooling dead ends, the 8.4-specific friction points, the schema conversion decisions and the validation approach for a small but awkward cross-engine move.

---

## 1. The Challenge: A Small Database With No Easy Path

### Environment Profile

| Attribute                   | Value                                                          |
| --------------------------- | -------------------------------------------------------------- |
| **Source Engine**           | MySQL 8.4.11 on AWS Outposts                                   |
| **Destination Engine**      | PostgreSQL 17.11 on AWS Outposts                               |
| **Source Size (all tables)**| ~698 MB (data + indexes)                                       |
| **Tables Migrated**         | 17                                                             |
| **Tables Excluded**         | 1 (dated snapshot copy of the largest table)                   |
| **Largest Table**           | ~202K rows, ~349 MB including indexes                          |
| **Window**                  | Application stopped, no concurrent writes                      |
| **Replication Needed?**     | No, full load only                                             |
| **Admin Access (MySQL)**    | Not a full admin: no `SYSTEM_VARIABLES_ADMIN`                  |

The source also runs Liquibase, so the schema carried `DATABASECHANGELOG` and `DATABASECHANGELOGLOCK` tables that the application expects to find on the new engine.

### Why Not DMS

We already had a working DMS replication instance in the Region. The problem was topology:

```
[MySQL on Outposts] ──► service link ──► [DMS in Region] ──► service link ──► [PostgreSQL on Outposts]
```

Both endpoints sit on the same Outpost, so DMS would read every row up to the Region and write it straight back, **crossing the service link twice** and adding latency to every batch. DMS also does not carry secondary indexes, foreign keys or sequences across engines, so we would have had to hand-build the target schema regardless. For a one-off, application-down move, a local path was the better fit.

---

## 2. Data Scope: Exclude Before You Migrate

A size query on the source showed that one table accounted for half the database, and that a second table had **identical statistics** to it:

```sql
SELECT table_name,
       table_rows AS approx_rows,
       ROUND(data_length / 1024 / 1024, 2)  AS data_mb,
       ROUND(index_length / 1024 / 1024, 2) AS index_mb,
       ROUND((data_length + index_length) / 1024 / 1024, 2) AS total_mb
FROM information_schema.tables
WHERE table_schema = 'dispute_db' AND table_type = 'BASE TABLE'
ORDER BY (data_length + index_length) DESC;
```

| Table                          | Approx. Rows | Data      | Index     | Total         |
| ------------------------------ | ------------ | --------- | --------- | ------------- |
| `transaction_records`          | ~202K        | 247.91 MB | 100.86 MB | **348.77 MB** |
| `transaction_records_<date>`   | ~201K        | 247.91 MB | 100.86 MB | **348.77 MB** |
| 16 other tables                | 0 to 102 each| < 0.1 MB each | < 0.1 MB each | negligible |

The second table was a **dated snapshot copy** of the first. Before excluding it we checked the `SHOW CREATE TABLE` output for all 17 remaining tables: none had a foreign key pointing at it.

> **Key Insight:** `information_schema.TABLES.TABLE_ROWS` is an **estimate** for InnoDB. It is good enough for scoping and sizing, but it is not a validation tool. We used exact `COUNT(*)` for reconciliation (Section 7).

| Category                    | Count | Size / Impact |
| --------------------------- | ----- | ------------- |
| **Tables Included**         | 17    | ~350 MB       |
| **Tables Excluded**         | 1     | ~349 MB       |
| **Payload Reduction**       | -     | ~50%          |

---

## 3. Choosing a Route: Four Tools, Four Different Outcomes

| Option                                  | Outcome            | Reason                                                                 |
| --------------------------------------- | ------------------ | ---------------------------------------------------------------------- |
| **AWS DMS (Region replication instance)** | Not used         | Data would cross the service link twice; target schema still manual.   |
| **pgloader**                            | Blocked            | Two independent failures (Issues #1 and #2).                           |
| **MySQL Shell `util.dump_schemas`**     | Failed             | Issued a statement MySQL 8.4 removed (Issue #3). Used `SHOW CREATE TABLE` instead. |
| **DBeaver Data Transfer**               | **Used**           | Worked after disabling bulk `COPY` loading (Issue #4).                 |

The final topology:

```
┌──────────────────────────────────────────────────────────────────┐
│                       AWS OUTPOSTS                               │
│                                                                  │
│   [MySQL 8.4]                                                    │
│       │                                                          │
│       │  mysqlsh: SHOW CREATE TABLE  ──►  hand-converted DDL     │
│       │                                   (schema_pg.sql)        │
│       │                                                          │
│       │  DBeaver Data Transfer (batched INSERTs)                 │
│       ▼                                                          │
│   [PostgreSQL 17]  ◄── post_load.sql (indexes, FKs, sequences)   │
└──────────────────────────────────────────────────────────────────┘
```

---

## 4. Schema Conversion: Tables First, Constraints After

Because the automatic route was blocked, we converted the DDL ourselves. We extracted the MySQL definitions with plain `SELECT` privilege:

```python
# mysqlsh, Python mode
tables = ["transaction_records", "dispute_transactions", "issuers"]   # ...all 17

with open("/home/<user>/schema.sql", "w") as f:
    for t in tables:
        row = session.run_sql("SHOW CREATE TABLE dispute_db.`" + t + "`").fetch_one()
        f.write(row[1] + ";\n\n")
```

### Type Mapping

| MySQL                                   | PostgreSQL                                       |
| --------------------------------------- | ------------------------------------------------ |
| `BIGINT AUTO_INCREMENT`                 | `bigint GENERATED BY DEFAULT AS IDENTITY`        |
| `DATETIME`, `TIMESTAMP`                 | `timestamp`                                      |
| `TINYINT(1)`                            | `boolean`                                        |
| `TINYINT` (other widths)                | `smallint`                                       |
| `TEXT`, `LONGTEXT`                      | `text`                                           |
| `DEFAULT '1'` / `'0'` on boolean columns | `DEFAULT true` / `false`                        |
| Upper-case Liquibase tables             | Lower-case (`databasechangelog`, `databasechangeloglock`) |

> **Why `BY DEFAULT`:** `GENERATED ALWAYS` rejects explicit `id` values on insert. `BY DEFAULT` lets the migration carry the original ids across, and the sequence is repositioned afterwards.

### Two-Phase DDL

We split the schema into two scripts so the load could run against lean tables:

| Script           | Contents                                                          | Runs            |
| ---------------- | ----------------------------------------------------------------- | --------------- |
| `schema_pg.sql`  | Tables, primary keys, unique constraints                          | Before the load |
| `post_load.sql`  | Secondary indexes, foreign keys, sequence reset, `ANALYZE`        | After the load  |

Unique constraints stay in the first script because foreign keys need something to reference. Everything else waits: loading into tables with no secondary indexes or foreign keys is faster and avoids insert-ordering problems between parent and child tables.

### Cleanup During Conversion

- **Redundant duplicate indexes were dropped**, such as extra `UNIQUE KEY id (id)` on tables that already had `id` as primary key.
- **Constraint and index names were made schema-unique.** MySQL scopes index names per table. PostgreSQL scopes them per schema, so generic names like `code` or `log_code` collided across tables.
- **Tables went into a dedicated schema**, not `public`, so the application role needs an explicit `search_path` (Section 6).

---

## 5. Friction Points: Four Failures, Four Root Causes

### Issue #1: pgloader Cannot Log In to MySQL 8.4

```
FATAL Failed to connect to #<MYSQL-CONNECTION mysql://migrator@<host>:3307/dispute_db>:
Condition QMYND:MYSQL-UNSUPPORTED-AUTHENTICATION was signalled.
```

The same credentials worked in MySQL Shell, which ruled out passwords, privileges and networking.

> **Root Cause (most likely):** pgloader's MySQL driver cannot complete the handshake against this 8.4 server, whose default policy is `authentication_policy = *:caching_sha2_password`. We changed the migration user to `mysql_native_password` and it still failed, so the problem was not the account's own plugin.

We could not change the server-wide policy either:

```
ERROR: 1227 (42000): Access denied; you need (at least one of) the SUPER or
SYSTEM_VARIABLES_ADMIN privilege(s) for this operation
```

Rather than chase a driver problem on a server we could not reconfigure, we moved to a route that did not depend on pgloader's MySQL client.

### Issue #2: PostgreSQL Rejects the Connection With "no encryption"

```
FATAL Failed to connect to #<PGSQL-CONNECTION pgsql://postgres@<host>:5432/dispute_db>:
Database error 28000: no pg_hba.conf entry for host "<client-ip>", user "postgres",
database "dispute_db", no encryption
```

> **Root Cause (most likely):** the server only admits encrypted connections from this client. The trailing words `no encryption` say the client tried a plain-text connection. A `psql` session from the same VM connected immediately because `psql` negotiates TLS by default:
>
> `SSL connection (protocol: TLSv1.3, cipher: TLS_AES_256_GCM_SHA384, compression: off)`

**Fix:** request TLS explicitly in the client. For pgloader that means `?sslmode=require` on the PostgreSQL URL. For libpq tools, `export PGSSLMODE=require`. For DBeaver, set the SSL driver property on the PostgreSQL connection.

### Issue #3: MySQL Shell Dump Utility Fails on MySQL 8.4

```python
util.dump_schemas(["dispute_db"], "/home/<user>/schema_dump",
                  {"ddlOnly": True, "consistent": False, ...})
```

```
mysqlsh.DBError: MySQL Error (1064): Util.dump_schemas: You have an error in your
SQL syntax; ... near 'MASTER STATUS' at line 1
```

> **Root Cause:** `SHOW MASTER STATUS` was **removed in MySQL 8.4** (replaced by `SHOW BINARY LOG STATUS`). The dump utility issued the legacy statement while gathering metadata, and `consistent: False` did not avoid it.

**Fix:** extract DDL with `SHOW CREATE TABLE` (Section 4). It needs only `SELECT` and no binlog access.

### Issue #4: DBeaver, Three Separate Symptoms

**(a) Unmatched tables shown in orange.** The mapping page flagged most tables as not found in the target container, even though they existed. The colour turned out to be unreliable: when the transfer failed later, the error text itself came from PostgreSQL naming an **existing** target table. Expanding a table's column mappings and checking for `existing` rather than `create` was the real test. The two Liquibase tables needed their lower-case targets chosen manually from the dropdown.

**(b) Bulk load fails on one table.**

```
ERROR: missing data for column "transaction_search_key"
Where: COPY dispute_transactions, line 1: ""
```

> **Root Cause (suspected, not proven):** the bulk loader sends rows to PostgreSQL via `COPY`, which is strict about row shape. The failing table carries several free-text columns (comments, receipt data, reasons) that can hold line breaks and quotes, which is where a `COPY` stream is most likely to go wrong.

**Fix:** turn **Use bulk load** off and use **multi-row `INSERT`** (batch size 500). Tables left partially loaded by the failed run were re-sent with **Truncate before load** enabled, so a retry could not collide with leftover rows on the primary key.

**(c) The wizard sat on "waiting for background work".** Behind the wizard was an error dialog that had to be dismissed before the buttons became active. Two settings were also making the transfer slower than it needed to be: **Select row count** (extra `COUNT` queries against the source) and a **commit interval of 10 rows**. Both are worth changing before a larger run (see lessons).

---

## 6. Post-Load: Indexes, Foreign Keys, Sequences, Ownership

After the data was in, `post_load.sql` ran in this order: secondary indexes, foreign keys, sequence reset, then `ANALYZE`.

### Identity Sequences

Loading explicit ids does not move the identity counter, so the next application insert would collide with an existing row. A single loop repositions every sequence:

```sql
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['transaction_records', 'dispute_transactions', 'issuers' /* ...all identity tables */] LOOP
    EXECUTE format(
      'SELECT setval(pg_get_serial_sequence(%L, ''id''), COALESCE(MAX(id), 1), MAX(id) IS NOT NULL) FROM %I',
      t, t);
  END LOOP;
END $$;
```

> **Design Decision:** sequences continue from `MAX(id)`, **not** from the source's `AUTO_INCREMENT` counter. On the largest table the old counter was in the hundreds of millions while the table held about 200K rows. If anything outside the database references old ids, decide this deliberately before cutover.

### Ownership and Default Schema

```sql
CREATE ROLE app_user WITH LOGIN PASSWORD '<generated-password>';

ALTER DATABASE dispute_db OWNER TO app_user;
ALTER SCHEMA   dispute_db OWNER TO app_user;
-- loop: ALTER TABLE dispute_db.<table> OWNER TO app_user;

ALTER ROLE app_user SET search_path TO dispute_db;
```

Because the tables live in a dedicated schema, the role's `search_path` (or `currentSchema=` in a JDBC URL) is what lets the application find them. Without it, the application looks in `public` and sees nothing.

---

## 7. Post-Migration Validation

| Validation Scope               | Result                    | Method                                                         |
| ------------------------------ | ------------------------- | -------------------------------------------------------------- |
| **Row counts (17 tables)**     | ✅ Matched                 | Exact `COUNT(*)` on both engines, not `TABLE_ROWS` estimates   |
| **Identity sequences**         | ✅ Reset                   | `setval` to `MAX(id)` on every identity table                  |
| **Planner statistics**         | ✅ Refreshed               | `ANALYZE` after load                                           |
| **Indexes and foreign keys**   | ✅ Applied                 | Created by `post_load.sql` after the load                      |
| **Excluded table**             | ✅ Absent from target      | Not in the schema or the transfer list                         |
| **Application smoke test**     | **[TODO]**                 | **[TODO: add result of first application start against PostgreSQL]** |

Exact per-table counts on PostgreSQL, without touching the planner's estimates:

```sql
SELECT table_name,
       (xpath('/row/c/text()',
              query_to_xml(format('select count(*) as c from %I.%I', table_schema, table_name),
                           false, true, '')))[1]::text::bigint AS row_count
FROM information_schema.tables
WHERE table_schema = 'dispute_db' AND table_type = 'BASE TABLE'
ORDER BY 1;
```

---

## 8. Measured Production Outcomes

```
SCOPE:
  Tables migrated:               17
  Tables excluded:               1 (dated snapshot copy, ~349 MB)
  Data migrated:                 ~350 MB (data + indexes, MySQL side)
  Largest table:                 ~202K rows

TOOLING:
  Routes attempted:              4 (DMS considered; pgloader, mysqlsh dump, DBeaver tried)
  Distinct blockers hit:         4
  Final route:                   Hand-converted DDL + DBeaver Data Transfer (batched INSERTs)

LOAD:
  Load duration:                 [TODO]
  Total elapsed (start to finish): [TODO]
  Data loss:                     0 rows

POST-LOAD:
  Row-count reconciliation:      17/17 tables matched
  Sequences reset:               all identity tables
  ANALYZE:                       completed
```

---

## 9. Key Engineering Lessons

1. **Read the whole error message.** `no pg_hba.conf entry ... no encryption` looks like a firewall-style rule problem. The last two words were the diagnosis: the client was not using TLS.
2. **Run the tool's connectivity check before building a plan around it.** pgloader's `--dry-run` surfaced both of its blockers in seconds and cost nothing.
3. **Major-version boundaries break tooling, not just SQL.** MySQL 8.4 removed `SHOW MASTER STATUS` and changed authentication defaults. Older client builds can fail in ways that look unrelated to the version.
4. **Own the schema conversion.** Hand-written DDL let us choose identity semantics, drop redundant indexes, fix name collisions and place objects deliberately. Two-phase DDL (structure first, constraints after) kept the load simple.
5. **Bulk paths are fast and strict.** For a ~350 MB database, `INSERT` batches cost minutes. Disabling `COPY` was a cheap trade for a load that completed.
6. **A UI colour is not evidence.** The orange mapping rows suggested a problem that did not exist. The error text and the column mapping type told the truth.
7. **Fix the slow settings before the big table, not after.** Raise the commit interval well above 10 rows, and turn off per-table row counts. Send the largest table on its own so a failure is easy to isolate.
8. **Reset identity sequences and set ownership and `search_path` before handing over.** They produce no errors during the migration and fail the application on first insert.
9. **Scope first.** Excluding one dated snapshot table halved the payload before a single row moved.

---

## Conclusion

A 350 MB database should not have needed four tools and four diagnoses. It did because both ends were newer-than-usual versions on managed infrastructure with limited admin rights, and because the topology (both databases on the same Outpost) ruled out the Region-based service we already had running.

The result: **zero data loss**, **exact row-count reconciliation across all 17 tables**, correctly positioned identity sequences, and an application role that owns its schema, all delivered the same evening the request arrived.
