## Filling a 159M-Row Gap in a 1.37B-Row Archive Table on RDS SQL Server
## TL;DR

The Outpost copy of `Transfers_Archive` had stopped receiving data on **3 Oct 2026 at 22:15:39**. By 26 Oct the Cloud copy was about 22.6 days ahead of it. We filled the gap like this:

1. **Exported** only the missing rows from the Cloud **read replica** with `bcp queryout` in native format. That was **159,463,286 rows in 15m 45s** (about 168.8k rows/s).
2. **Disabled 11 non-clustered indexes** on the target. We couldn't switch to minimally logged loading, because the database is on RDS and has to stay in FULL recovery.
3. **Imported** the file with `bcp in` using `TABLOCK` and 500k-row batches. That was **159,463,286 rows in 8h 20m** (about 5.3k rows/s), with **zero errors**.
4. **Rebuilt** the primary key first, which took **2h 55m**. The rebuild succeeding proved there were **no duplicate `(Id, Created)` rows**. The other 10 indexes are being rebuilt one at a time.

On the way we hit wrong ports, Named Pipes errors, a sanity check that wrongly reported failure, a "heap" that turned out to have a clustered index, a `COUNT(*)` that stalled the whole pipeline, and a DMS replication instance that couldn't reach the database.

---

## At a Glance

| Metric | Value |
| :--- | :--- |
| Outpost `MAX(Created)` (the cutoff) | `2026-10-03 22:15:39.8920704` |
| Gap duration | ~22.6 days |
| Outpost rows before import | 1,368,074,964 |
| Rows exported / imported | 159,463,286 / 159,463,286 |
| Expected rows after import | **1,527,538,250** |
| Export time (Cloud read replica → file) | 944,828 ms (**15m 45s**), ~168,775 rows/s |
| Import time (file → Outpost RDS) | 30,016,938 ms (**8h 20m 17s**), ~5,312 rows/s |
| Import errors | 0 |
| PK rebuild (`PK_Transfers_Archive1`) | **2h 55m** |
| Average gap volume | ~7M rows/day |

---

## 1. Context

### The table

`dbo.Transfers_Archive` holds archived interbank transfer records. It has 33 columns, mostly `varchar`. Several are wide: `Id`, `DestinationInstitutionId`, `InstitutionId` and `Beneficiary` are all `varchar(450)`. Other columns include `decimal(19,2)` amounts, two `int` status columns and two `datetime2(7)` timestamps.

- **Partitioned** on `Created` using the partition scheme `PS_Transfers_CreatedDay` (one partition per day).
- **`LOCK_ESCALATION = DISABLE`**.
- **Primary key:** `PK_Transfers_Archive1` on `(Id, Created)`. It is **NONCLUSTERED**.

### The indexes (from `sys.indexes`, not the DDL script)

| Index | Type |
| :--- | :--- |
| `CIX_Transfers_Archive_Created_Id` | **CLUSTERED** |
| `PK_Transfers_Archive1` | NONCLUSTERED |
| `IX_UniqueReference_Created` | NONCLUSTERED |
| `IX_Status` | NONCLUSTERED |
| `IX_SenderAccountNumber` | NONCLUSTERED |
| `IX_DestinationInstitutionId` | NONCLUSTERED |
| `IX_InstitutionId` | NONCLUSTERED |
| `IX_PaymentReference` | NONCLUSTERED |
| `IX_BeneficiaryAccountNumber` | NONCLUSTERED |
| `IX_TsqStatus` | NONCLUSTERED |
| `IX_Created_INCL_Amount` | NONCLUSTERED |
| `IX_Created_ResponseCode_INCL_Amount` | NONCLUSTERED |

### The constraints

- **RDS:** no OS access, no `sysadmin`, and automated backups with point-in-time recovery (PITR) depend on an unbroken log chain in **FULL** recovery.
- **Source:** the Cloud **read replica**, reached through an AWS PrivateLink VPC endpoint on a **non-default port (1434)**.
- **Target:** the Outpost RDS instance on port 1433.
- **Production data:** financial records, so nothing could be lost and nothing could be duplicated.

---

## 2. Finding the Gap

The Outpost's latest record set the cutoff:

```sql
SELECT MAX(Created) FROM dbo.Transfers_Archive;   -- run on Outpost
-- 2026-10-03 22:15:39.8920704
```

Everything on the Cloud side with `Created > '2026-10-03 22:15:39.8920704'` was missing from the Outpost.

**Why use `>` and not `>=`?** The row at exactly the cutoff already existed on the Outpost. Using `>=` would have re-sent it, and with the PK disabled during the load, nothing would have stopped the duplicate.

---

## 3. Strategy: Why BCP Native Format from the Read Replica

| Decision | Reason |
| :--- | :--- |
| **Read from the read replica, not the primary** | A 159M-row scan shouldn't compete with production writes. |
| **`bcp queryout` with only the gap rows** | Moves just the delta, not the 1.37B rows that already matched. |
| **Native format (`-n`)** | Keeps `decimal`, `int` and `datetime2(7)` in binary form. No string conversion, no delimiter or escaping problems, no lost precision on the 7-digit fractional seconds. |
| **File-based hop (export → file → import)** | Two separate steps, each restartable on its own. The file is also a point-in-time artifact we can audit. |

---

## 4. Phase 1: The Export

### Hurdle 1: How big is the gap? (Our guess was wrong)

Before the export, we estimated **35–55M rows, 6.5–10 GB and about 10 minutes**. The real figure was **159.46M rows**, roughly 3–4× more, because daily volume was about 7M rows and not the 1.5–2.5M we assumed.

> **Lesson:** Don't guess the size of a gap. Run a range `COUNT_BIG(*)` on the replica, or better, read per-partition row counts from `sys.partitions` (instant on a table partitioned by day). We had a pre-flight count in the first script and dropped it when we refactored. Keep it.

### Hurdle 2: `Named Pipes Provider: Could not open a connection to SQL Server [64]`

```
SQLState = 08001, NativeError = 64
Error = [Microsoft][ODBC Driver 17 for SQL Server]Named Pipes Provider: Could not open a connection to SQL Server [64].
SQLState = S1T00, NativeError = 0
Error = [Microsoft][ODBC Driver 17 for SQL Server]Login timeout expired
```

**Root cause:** two problems together:
1. The script still had a **placeholder endpoint**. The real source is a **PrivateLink VPC endpoint on port 1434**, not a standard RDS hostname on 1433.
2. With no protocol prefix, the client falls back across protocols, so the error mentions Named Pipes even though the real problem is that the server is unreachable.

**Fix:** use the real endpoint, force TCP and add the port **with a comma, not a colon**:

```bat
set "CLOUD_READER=<cloud-reader-vpce-endpoint>.eu-west-2.vpce.amazonaws.com,1434"
...
-S tcp:%CLOUD_READER%
```

Before running again, we checked we could reach it:

```powershell
Test-NetConnection -ComputerName '<cloud-reader-vpce-endpoint>' -Port 1434
```

### Hurdle 3: Quoting the password in a batch file

`set CLOUD_PASS='secret'` and `set CLOUD_PASS="secret"` both store the quotes **as part of the password**, so the login fails.

What actually works:
- Use `set "CLOUD_PASS=secret"`. Quotes **around the whole assignment** aren't stored, and they protect `&`, `|`, `<` and `>`.
- **Watch out for `setlocal enabledelayedexpansion`:** it silently removes any `!` from the value. A password like `Passw0rd!` gets mangled. If you don't need delayed expansion, leave it off.
- Pass the value as `-P "%CLOUD_PASS%"`.

> Hardcoded passwords in `.bat` files and `-P` on the command line (visible in process listings) are acceptable for a one-off run at best. Pull the password from a secret store or prompt for it, and delete the files afterwards.

### Hurdle 4: A wrong fix that was suggested along the way (escaping `>` inside quotes)

One draft of the script "escaped" the comparison operator inside the BCP query string:

```bat
bcp "SELECT * FROM dbo.Transfers_Archive WHERE Created ^> '%CUTOFF_DATE%' ..." queryout ...
```

**That is wrong.** Inside double quotes, `cmd` doesn't treat `>` as redirection, so the caret gets passed through literally and SQL Server receives `Created ^> '...'`, which is a syntax error. The version that ran used a plain `>` inside the quotes, and it worked. You only need `^>` **outside** quotes, for example when `echo`ing SQL into a file.

### Hurdle 5: "Smarter and cooler": putting the SQL in its own file

The idea was to keep the query in `export_gap_query.sql` and have the batch file run it. That's a good idea, but **`bcp` can't read a query from a file**. `queryout` needs the query inline (`-i` is for answering format prompts, not for SQL). We kept the file for documentation and kept the query inline in `bcp`.

`sqlcmd -i file.sql` *can* run a file, which works for the pre-flight count.

### Hurdle 6: The export worked, but the script reported "Export file was not created"

```
Network packet size (bytes): 4096
Clock Time (ms.) Total     : 944828 Average : (168774.94 rows per sec.)
[2/3] Performing Sanity Checks...
Output path: C:\DBA\Transfers_Archive_GAP_export.bcp
Γ¥î FAILED: Export file was not created.
```

BCP had worked: 168,774.94 rows/s × 944.8 s ≈ 159.46M rows. **The sanity-check block was the problem:**

1. **Paths had drifted.** Over the session the paths moved between `C:\BCP_Staging\`, `C:\DBA\` and `C:\Users\...\Documents\DBA\`, so the check didn't always look where BCP had written the file.
2. **The file size was read the wrong way.** `for /f "usebackq" %%A in ("file") do set FILE_SIZE=%%~zA` reads the file's **contents** line by line (here a multi-GB binary file) instead of its metadata. The correct form is a plain `for`: `for %%A in ("file") do set "FILE_SIZE=%%~zA"`.
3. **Garbled output (`Γ¥î`).** That's the UTF-8 ❌ emoji displayed in the console's OEM code page 437. Use ASCII markers (`[OK]` / `[FAIL]`) or run `chcp 65001` first.

**Fix:** use one `WORK_DIR` variable for all paths, a plain `for` to get the size, and a string comparison (`if "%FILE_SIZE%"=="0"`) so large file sizes don't hit `cmd`'s 32-bit number limits. We confirmed the file with `dir`.

### Export result ✅

**159,463,286 rows in 15m 45s**, about 168.8k rows/s over PrivateLink.

---

## 5. Phase 2: Getting the Target Ready

### Hurdle 7: "Just switch to BULK_LOGGED", which you can't do on RDS

The standard advice for a big bulk load is to switch to `BULK_LOGGED` or `SIMPLE` so the load is minimally logged. **On RDS that isn't an option.** Automated backups, PITR and Multi-AZ all depend on an unbroken log chain in FULL recovery. RDS will push the database back to FULL, and breaking the chain undermines PITR for a production financial database.

**Decision:** stay in FULL and get the speed elsewhere, mainly by cutting index maintenance.

> **Correction:** at one point we thought `TABLOCK` would give "minimal logging even in FULL recovery". **It doesn't.** Minimal logging needs SIMPLE or BULK_LOGGED. In FULL recovery, **every one of the 159M rows was fully logged**. `TABLOCK` cut locking overhead, not log volume.

### Hurdle 8: The DDL script hid the clustered index

The generated `CREATE TABLE` script showed only a **nonclustered** PK. We concluded the table was a partitioned **heap** and planned a heap-optimised load.

Running `sys.indexes` on the live table showed otherwise:

```
CIX_Transfers_Archive_Created_Id   CLUSTERED     0
PK_Transfers_Archive1              NONCLUSTERED  0
... 10 more NONCLUSTERED indexes
```

The table had a **clustered index on (Created, Id)** plus **11 nonclustered indexes**. Inserting 159M rows with all of them active would have meant 12 B-tree updates per row, all fully logged.

> **Lesson:** a scripted `CREATE TABLE` isn't the full picture. Indexes created separately don't always appear in it. **Check `sys.indexes` on the live table.**

### Hurdle 9: The generic playbook would have taken the table offline

A generic tuning playbook we were looking at said:

```sql
ALTER INDEX ALL ON dbo.Transfers_Archive DISABLE;
ALTER INDEX PK_Transfers_Archive1 REBUILD;   -- "re-enable the clustered index"
```

It **assumed the PK was the clustered index**. Here it isn't. Running it would have:
1. Disabled `CIX_Transfers_Archive_Created_Id`, which **makes the whole table unreadable and unwritable**.
2. Then rebuilt the *nonclustered* PK, which can't be done while the clustered index is disabled. The table would have stayed offline and the BCP load would have failed.

The same playbook also suggested growing the log to 500 GB and shrinking it afterwards. On RDS, where log backups run every 5 minutes or so, that's unnecessary and the shrink just creates churn.

**What we did instead:** disabled the 11 nonclustered indexes **by name** and left the clustered index alone.

```sql
ALTER INDEX PK_Transfers_Archive1                ON dbo.Transfers_Archive DISABLE;
ALTER INDEX IX_UniqueReference_Created           ON dbo.Transfers_Archive DISABLE;
ALTER INDEX IX_Status                            ON dbo.Transfers_Archive DISABLE;
ALTER INDEX IX_SenderAccountNumber               ON dbo.Transfers_Archive DISABLE;
ALTER INDEX IX_DestinationInstitutionId          ON dbo.Transfers_Archive DISABLE;
ALTER INDEX IX_InstitutionId                     ON dbo.Transfers_Archive DISABLE;
ALTER INDEX IX_PaymentReference                  ON dbo.Transfers_Archive DISABLE;
ALTER INDEX IX_BeneficiaryAccountNumber          ON dbo.Transfers_Archive DISABLE;
ALTER INDEX IX_TsqStatus                         ON dbo.Transfers_Archive DISABLE;
ALTER INDEX IX_Created_INCL_Amount               ON dbo.Transfers_Archive DISABLE;
ALTER INDEX IX_Created_ResponseCode_INCL_Amount  ON dbo.Transfers_Archive DISABLE;
```

**Trade-offs we accepted:**
- **No uniqueness check during the load.** With the PK disabled, nothing would reject a duplicate `(Id, Created)`. We relied on the `>` cutoff and planned to let the PK rebuild catch any problems.
- **Foreign keys referencing the PK are disabled along with it.** They need re-enabling afterwards with `WITH CHECK`.
- **Queries on the Outpost lose their indexes.** Any lookup on this table falls back to scanning the clustered index until its index is rebuilt.
- **Triggers:** we checked `sys.triggers` and there were none.

---

## 6. Phase 3: The Import

### Hurdle 10: The pre-flight `COUNT(*)` stalled everything

The import script started with a "quick" baseline count:

```bat
sqlcmd ... -Q "SELECT COUNT(*) AS OutpostRowCountBefore FROM dbo.Transfers_Archive;"
```

It hung at `Checking current Outpost row count...`. A `Test-NetConnection` on port 1433 returned `TcpTestSucceeded : True`, so the network wasn't the problem. The session DMVs showed what was going on:

```
session 64 | 00:05:57 | (357253ms) CXCONSUMER | blocking_session_id NULL | status suspended | SQLCMD
```

**Root cause:** a parallel scan of **1.37 billion rows**, not blocking. There was also a twist we'd caused ourselves: **we had just disabled every nonclustered index.** Normally the optimizer answers `COUNT(*)` from the narrowest index available (an `int` index like `IX_Status` would do). With those disabled, its only option was to scan the **full clustered index**, every wide row of it.

**Fix:**
1. `KILL 64;` As soon as it died, the batch file moved on and the bulk insert started.
2. Got the baseline from metadata instead, which returned instantly with no locks:

```sql
SELECT SUM(p.rows) AS OutpostRowCountBefore
FROM sys.partitions p
WHERE p.object_id = OBJECT_ID('dbo.Transfers_Archive')
  AND p.index_id IN (0, 1);
-- 1,368,074,964
```

3. Removed the `sqlcmd` count from the script entirely.

### The load running

```
insert bulk dbo.Transfers_Archive (...) with (TABLOCK, ROWS_PER_BATCH=500000)
wait_info: ASYNC_NETWORK_IO | open_tran_count: 2 | status: suspended
```

```
Starting copy...
500000 rows sent to SQL Server. Total sent: 500000
...
500000 rows sent to SQL Server. Total sent: 119500000
...
159463286 rows copied.
Network packet size (bytes): 4096
Clock Time (ms.) Total     : 30016938 Average : (5312.44 rows per sec.)
```

### Hurdle 11: The import was 32× slower than the export

We had predicted **15–20 minutes**. It took **8h 20m**, about 5.3k rows/s compared with about 168.8k rows/s for the export. We didn't diagnose the cause during the run. These are the likely contributors, roughly in order:

| Suspected factor | Why it matters |
| :--- | :--- |
| **Full logging in FULL recovery** | Every row went into the log. No minimal logging was possible. |
| **Inserting into an existing clustered B-tree** | Each row has to land in the right place in `(Created, Id)` order across daily partitions, unlike appending to a heap. |
| **Export wasn't ordered on the full clustering key** | We exported `ORDER BY Created` only, not `Created, Id`, and gave no `ORDER(...)` hint, so SQL Server couldn't treat the stream as presorted. |
| **Default 4 KB network packets** | `Network packet size: 4096`. Around 159M rows of wide `varchar` data went in small packets over one connection. `ASYNC_NETWORK_IO` waits suggest the client side was part of the bottleneck. |
| **One single stream** | One `bcp` process, one connection, one file. |

**Still, it worked:** 159,463,286 rows in, matching the export exactly, with zero errors.

---

## 7. Phase 4: Rebuilding the Indexes

### Hurdle 12: You can't just "re-enable" an index

We asked whether there was a cheaper way than rebuilding. **There isn't.** Disabling a nonclustered index **deallocates its data** and keeps only the definition.

| Method | Re-enables? | Notes |
| :--- | :--- | :--- |
| `ALTER INDEX ... REBUILD` | ✅ | The standard approach |
| `CREATE INDEX ... WITH (DROP_EXISTING = ON)` | ✅ | Same cost. Only useful if you're also changing the definition |
| `ALTER INDEX ... REORGANIZE` | ❌ | Fails on a disabled index |
| `ENABLE` | ❌ | Exists for triggers and constraints, not indexes |

### Hurdle 13: `ALTER INDEX ALL ... REBUILD` would have rewritten 1.53B rows for nothing

The first rebuild script used `ALTER INDEX ALL ... REBUILD WITH (MAXDOP = 0)`. That **also rebuilds the clustered index**, which was never disabled, so it would have rewritten all ~1.53B rows, every byte fully logged, using every core on the instance.

**Revised plan:**
1. Rebuild **only the 11 disabled indexes, one at a time.** If one fails, only that one rolls back.
2. **PK first.** It restores data integrity, and DMS needs it before writing anything.
3. `ONLINE = ON` so the table stays usable, `SORT_IN_TEMPDB = ON` so the data files grow less, and `MAXDOP = 4` to leave CPU for production.
4. Check log usage between rebuilds and let RDS's ~5-minute log backups clear it.

### The PK rebuild: 2h 55m ✅

```sql
ALTER INDEX PK_Transfers_Archive1 ON dbo.Transfers_Archive
REBUILD WITH (ONLINE = ON, SORT_IN_TEMPDB = ON, MAXDOP = 4);
```

**Why this mattered:** a unique index rebuild **fails if it finds a duplicate key**. It succeeded, which proves that **no duplicate `(Id, Created)` rows entered during the 159M-row load**, even though nothing enforced uniqueness while it ran. It also tells us the instance supports online index operations.

### Hurdle 14: Will a higher MAXDOP make it faster?

**Only if CPU is the bottleneck.** For a build over 1.5B rows on RDS, the limit is usually storage I/O, tempdb or the log. Our plan: watch the next rebuild's waits and CloudWatch, then:
- **CPU under ~50% and I/O not maxed out:** raise MAXDOP to 8 (not 0). Expect maybe 10–30% faster.
- **`PAGEIOLATCH_*`, `WRITELOG` or `IO_COMPLETION` waits, or IOPS at the limit:** keep MAXDOP at 4.
- A higher DOP also raises memory grants, tempdb use and the risk of slow logins. That matters because DMS was already having connection trouble.

### Remaining rebuilds (in progress)

Most-queried indexes first. Low-selectivity indexes (`IX_Status`, `IX_TsqStatus`) go last, and we'll check with the app team whether they're needed at all.

| # | Index | Status | Duration |
| :--- | :--- | :--- | :--- |
| 1 | `PK_Transfers_Archive1` | ✅ Done | 2h 55m |
| 2 | `IX_UniqueReference_Created` | ⏳ | |
| 3 | `IX_PaymentReference` | ⏳ | |
| 4 | `IX_SenderAccountNumber` | ⏳ | |
| 5 | `IX_BeneficiaryAccountNumber` | ⏳ | |
| 6 | `IX_Created_INCL_Amount` | ⏳ | |
| 7 | `IX_Created_ResponseCode_INCL_Amount` | ⏳ | |
| 8 | `IX_InstitutionId` | ⏳ | |
| 9 | `IX_DestinationInstitutionId` | ⏳ | |
| 10 | `IX_Status` | ⏳ / maybe skip | |
| 11 | `IX_TsqStatus` | ⏳ / maybe skip | |

---

## 8. Phase 5: Ongoing Replication with DMS (Open)

### Hurdle 15: DMS endpoint test: `dial tcp <outpost-ip>:1433: i/o timeout`

```
Test Endpoint failed: ... Login timeout expired
Code: [DMS-00002], Message: [dial tcp 10.x.x.x:1433: i/o timeout]
```

My laptop could reach the same IP and port over the VPN, so the database was fine. The **DMS replication instance has no network path to it.** An `i/o timeout` means packets are being dropped silently, which points to security groups, NACLs, routing or being in a different VPC.

**Diagnosis plan:**
1. **VPC Reachability Analyzer**, from the replication instance's network interface to the RDS network interface on TCP 1433. It names the exact component that blocks the traffic.
2. **RDS security group:** allow inbound 1433 from the replication instance's security group (same VPC) or its CIDR (peered VPC or Transit Gateway).
3. **Same VPC?** If not, the VPC peering or Transit Gateway routes must go **both ways**. The alternative is to recreate the replication instance in the RDS VPC.
4. **NACLs** (they're stateless): allow 1433 inbound and ephemeral ports 1024–65535 for return traffic, on both subnets.
5. The **source** endpoint is the PrivateLink endpoint on **1434**. The replication instance needs a path to that as well.

**Before starting any DMS task:**
- **PK must be rebuilt first** ✅ (done).
- **CDC only, no full load.** The gap is already filled. Start CDC slightly before the export started, and let the PK plus DMS's apply-error handling deal with any overlapping rows.

---

## 9. Timeline (26 Oct 2026)

| Time | Event |
| :--- | :--- |
| Earlier that day | Gap identified (cutoff `2026-10-03 22:15:39.8920704`). Export script drafted and reviewed. |
| — | First export attempt fails: Named Pipes / login timeout (placeholder host, wrong port). |
| — | Fixed with `tcp:<vpce-endpoint>,1434` and the password quoting sorted out. |
| — | **Export completes: 159,463,286 rows in 15m 45s.** Sanity check wrongly reports failure. File confirmed with `dir`. |
| 13:59 | Table DDL scripted. It shows only a nonclustered PK. |
| ~14:00 | Recovery-model change ruled out (RDS/PITR). `sys.indexes` reveals the clustered index and 11 NC indexes. 11 NC indexes disabled by name. |
| 14:09:10 | Import script starts. Pre-flight `COUNT(*)` begins. |
| ~14:15 | Count stuck for ~6 min on `CXCONSUMER`. `KILL 64`. Metadata count: **1,368,074,964**. |
| 14:17:23 | `insert bulk ... with (TABLOCK, ROWS_PER_BATCH=500000)` begins. |
| ~22:37 | **Import completes: 159,463,286 rows in 8h 20m, 0 errors.** |
| After import | DMS endpoint test fails with `i/o timeout` (open). |
| After import | **PK rebuild completes in 2h 55m.** No duplicates. |
| Ongoing | Remaining 10 indexes being rebuilt one at a time. |

---

## 10. Hurdles and Fixes

| # | Hurdle | Root cause | Fix |
| :--- | :--- | :--- | :--- |
| 1 | Gap size badly underestimated | Guessed daily volume | Measure it: range count or `sys.partitions` |
| 2 | Named Pipes error 64 / login timeout | Placeholder host, no `tcp:`, wrong port | `tcp:<host>,1434` (comma, not colon) |
| 3 | Password quoting | Quotes become part of the value; `!` lost under delayed expansion | `set "VAR=value"`, avoid `enabledelayedexpansion` |
| 4 | `^>` inside a quoted query | Caret is passed literally inside quotes | Plain `>` inside quotes |
| 5 | "Query in a separate .sql file" | `bcp` can't read queries from files | Query inline in `bcp`; `sqlcmd -i` for counts |
| 6 | False "export file not created" + `Γ¥î` | Path drift, `for /f` reading contents, UTF-8 emoji in OEM console | One `WORK_DIR`, plain `for` with `%%~z`, ASCII markers |
| 7 | Can't switch to BULK_LOGGED | RDS + PITR need FULL recovery | Stay in FULL, cut index maintenance instead |
| 8 | "Heap" was actually clustered | Scripted DDL didn't show `CIX_...` | Trust `sys.indexes` |
| 9 | Generic `ALTER INDEX ALL DISABLE` | Playbook assumed a clustered PK | Disable the 11 NC indexes by name |
| 10 | Pre-flight `COUNT(*)` hung | Parallel scan of 1.37B rows, made worse by the disabled NC indexes | `KILL`, use `sys.partitions` |
| 11 | Import 32× slower than export | Full logging, clustered inserts, 4 KB packets, one stream | Accepted for this run (see lessons) |
| 12 | No "enable" for indexes | Disable deallocates the index | `REBUILD` |
| 13 | `ALTER INDEX ALL REBUILD` | Would rewrite the clustered index too | Rebuild the 11 one at a time, PK first |
| 14 | MAXDOP | Bottleneck usually I/O or log, not CPU | Measure waits, then max 8, never 0 |
| 15 | DMS `i/o timeout` | No network path from the replication instance | Reachability Analyzer, SG/NACL/routes (**open**) |

---

## 11. Assumptions That Turned Out Wrong

| We assumed | Reality |
| :--- | :--- |
| Gap of ~35–55M rows, ~10-minute export | **159.46M rows**, 15m 45s export |
| Import in ~15–20 minutes | **8h 20m** |
| The table is a heap | It has a **clustered index** on `(Created, Id)` |
| `TABLOCK` gives minimal logging in FULL | **No.** Minimal logging needs SIMPLE or BULK_LOGGED. Every row was fully logged. |
| The PK is the clustered index (generic playbook) | The PK is **nonclustered** |
| `COUNT(*)` is a quick pre-flight check | A parallel scan of **1.37B rows** that stalled the pipeline |
| Indexes can be re-enabled cheaply | **Full rebuild.** The PK alone took 2h 55m. |
| Default port 1433 everywhere | Source on **1434** via PrivateLink |
| `>` needs escaping inside quoted strings | Not inside double quotes. Escaping breaks the SQL. |

---

## 12. Lessons and What I'd Do Differently

**Discovery**
1. **Look at the live catalog** (`sys.indexes`, `sys.index_columns`, `sys.foreign_keys`, `sys.triggers`) before planning. Don't rely on scripted DDL.
2. **Measure the gap** before moving it. On a table partitioned by day, `sys.partitions` gives per-day counts instantly on both sides.
3. **Never `COUNT(*)` a billion-row table as a pre-flight check**, and especially not right after disabling its narrow indexes.

**Export**
4. **Export in clustered-key order** (`ORDER BY Created, Id`). Then import with `-h "TABLOCK, ORDER(Created ASC, Id ASC)"` so SQL Server can treat the stream as presorted. Confirm the key order in `sys.index_columns` first.
5. **Use an explicit column list instead of `SELECT *`.** Native format depends on the source and target having the same column order.
6. **Request larger packets** (`-a 16384` or `-a 32768`) and measure the difference.

**Import**
7. **Split by date range and run in parallel.** For example, one file per few days, imported over 2–4 connections. The daily partitions make this a natural fit.
8. **Treat the import window as a maintenance window** for this table. With `TABLOCK` and 500k-row batches, each batch holds a table-level lock.
9. **Plan around FULL recovery from the start.** On RDS the levers are fewer indexes during the load, parallel streams and log headroom, not the recovery model.

**Indexes**
10. **Disable nonclustered indexes by name. Never use `ALTER INDEX ALL ... DISABLE`** on a table with a clustered index you want to keep online.
11. **Rebuild only what you disabled, one at a time, PK first.** A successful unique rebuild is your duplicate check.
12. **Ask whether every index is worth rebuilding.** One left disabled costs nothing until someone needs it.

**Scripting**
13. One `WORK_DIR`, ASCII-only output, `set "VAR=value"`, no delayed expansion unless needed, and a plain `for` with `%%~z` for file sizes.
14. Run long jobs from `sqlcmd` or a SQL Agent job, not an SSMS window that dies when the VPN drops.
15. Keep secrets out of scripts. Prompt for them or pull them from a secret store.

**Replication**
16. **Test DMS connectivity before the load starts**, not after. Reachability Analyzer gives the answer in minutes.

---

## 13. Final Verification Checklist

- [x] Export row count = import row count (159,463,286)
- [x] `import_gap_errors.log` empty / 0 errors
- [x] `PK_Transfers_Archive1` rebuilt (no duplicates)
- [ ] Remaining 10 indexes rebuilt (or deliberately left disabled and documented)
- [ ] All indexes `is_disabled = 0`
- [ ] Metadata row count = **1,527,538,250**
- [ ] Per-day partition counts match the Cloud side for days before and after the cutoff
- [ ] Foreign keys referencing the PK re-enabled `WITH CHECK` (if any)
- [ ] Staging `.bcp` file and scripts with credentials deleted
- [ ] DMS connectivity fixed; CDC-only task started from before the export

> **Why check per-day counts before the cutoff?** If the Cloud archive is filled by a job that moves *older* rows in from a live table, rows with `Created` **earlier** than the cutoff could have arrived on the Cloud side after the Outpost stopped. A `Created > cutoff` export would miss them. Comparing per-partition counts on both sides catches this.

---

## Appendix A: Export Script (post-mortem fixes applied)

```bat
@echo off
REM export_gap_transfers_archive.bat
REM Exports only rows created after the Outpost's MAX(Created), from the Cloud read replica.
setlocal

set "WORK_DIR=C:\DBA"
set "CLOUD_READER=<cloud-reader-vpce-endpoint>.eu-west-2.vpce.amazonaws.com,1434"
set "CLOUD_USER=<user>"
set "CLOUD_PASS=<password>"
set "CLOUD_DB=AccountSwitch"
set "CUTOFF_DATE=2026-10-03 22:15:39.8920704"

set "OUTPUT_FILE=%WORK_DIR%\Transfers_Archive_GAP_export.bcp"
set "ERROR_LOG=%WORK_DIR%\export_gap_errors.log"
set "LOG_FILE=%WORK_DIR%\export_gap.log"

if not exist "%WORK_DIR%" mkdir "%WORK_DIR%"
echo [%date% %time%] Export start, cutoff %CUTOFF_DATE% > "%LOG_FILE%"

REM Pre-flight: size the gap on the REPLICA (range count, not a full-table count)
sqlcmd -S tcp:%CLOUD_READER% -U %CLOUD_USER% -P "%CLOUD_PASS%" -d %CLOUD_DB% -Q "SET NOCOUNT ON; SELECT COUNT_BIG(*) AS GapRows, MIN(Created) AS GapStart, MAX(Created) AS GapEnd FROM dbo.Transfers_Archive WHERE Created > '%CUTOFF_DATE%';" >> "%LOG_FILE%" 2>&1

REM Export. Note: plain > inside quotes, no caret.
REM Changed from the run: ORDER BY Created, Id (full clustering key) and -a 32768.
bcp "SELECT * FROM dbo.Transfers_Archive WHERE Created > '%CUTOFF_DATE%' ORDER BY Created, Id" queryout "%OUTPUT_FILE%" -S tcp:%CLOUD_READER% -U %CLOUD_USER% -P "%CLOUD_PASS%" -d %CLOUD_DB% -n -a 32768 -e "%ERROR_LOG%"
if errorlevel 1 (
    echo [FAIL] BCP export failed. See "%ERROR_LOG%".
    exit /b 1
)

REM Sanity check: plain FOR reads metadata (%%~z); FOR /F would read file contents
if not exist "%OUTPUT_FILE%" (
    echo [FAIL] Export file not found: "%OUTPUT_FILE%"
    exit /b 1
)
for %%A in ("%OUTPUT_FILE%") do set "FILE_SIZE=%%~zA"
if "%FILE_SIZE%"=="0" (
    echo [FAIL] Export file is empty.
    exit /b 1
)

echo [OK] Export file: "%OUTPUT_FILE%" (%FILE_SIZE% bytes)
echo [%date% %time%] Export done, %FILE_SIZE% bytes >> "%LOG_FILE%"
endlocal
```

## Appendix B: Import Script (as run, plus optional improvements)

```bat
@echo off
REM import_gap_transfers_archive.bat
REM Run ONLY after the 11 nonclustered indexes are disabled.
setlocal

set "WORK_DIR=C:\DBA"
set "OUTPOST_SERVER=<outpost-rds-endpoint>.eu-west-2.rds.amazonaws.com,1433"
set "OUTPOST_USER=<user>"
set "OUTPOST_PASS=<password>"
set "OUTPOST_DB=AccountSwitch"
set "BATCH_SIZE=500000"

set "INPUT_FILE=%WORK_DIR%\Transfers_Archive_GAP_export.bcp"
set "ERROR_LOG=%WORK_DIR%\import_gap_errors.log"
set "LOG_FILE=%WORK_DIR%\import_gap.log"

echo [%date% %time%] Import start > "%LOG_FILE%"
if not exist "%INPUT_FILE%" (
    echo [FAIL] Input file not found: "%INPUT_FILE%"
    exit /b 1
)

REM NO pre-flight COUNT(*) here. Take the baseline from sys.partitions in SSMS instead.

REM As run:      -h "TABLOCK"
REM Next time:   -h "TABLOCK, ORDER(Created ASC, Id ASC)" -a 32768
REM              (ORDER only if the export was ORDER BY Created, Id)
bcp dbo.Transfers_Archive in "%INPUT_FILE%" -S tcp:%OUTPOST_SERVER% -U %OUTPOST_USER% -P "%OUTPOST_PASS%" -d %OUTPOST_DB% -n -b %BATCH_SIZE% -h "TABLOCK" -e "%ERROR_LOG%"
if errorlevel 1 (
    echo [FAIL] BCP import failed. See "%ERROR_LOG%".
    exit /b 1
)

echo [OK] Import complete. Next: rebuild the disabled indexes, PK first.
echo [%date% %time%] Import done >> "%LOG_FILE%"
endlocal
```

## Appendix C: SQL Toolkit

**Instant row count (no scan, no locks)**
```sql
SELECT SUM(p.rows) AS TotalRows
FROM sys.partitions p
WHERE p.object_id = OBJECT_ID('dbo.Transfers_Archive')
  AND p.index_id IN (0, 1);
```

**Per-partition (per-day) counts, to compare Cloud and Outpost**
```sql
-- Run on both sides; assumes identical partition functions.
-- RANGE RIGHT: boundary_id = partition_number - 1 gives the lower bound.
-- RANGE LEFT:  boundary_id = partition_number gives the upper bound.
SELECT p.partition_number, prv.value AS boundary_value, p.rows
FROM sys.partitions p
JOIN sys.indexes i            ON i.object_id = p.object_id AND i.index_id = p.index_id
JOIN sys.partition_schemes ps ON ps.data_space_id = i.data_space_id
LEFT JOIN sys.partition_range_values prv
       ON prv.function_id = ps.function_id AND prv.boundary_id = p.partition_number
WHERE p.object_id = OBJECT_ID('dbo.Transfers_Archive') AND p.index_id = 1
ORDER BY p.partition_number DESC;
```

**Index state**
```sql
SELECT name, type_desc, is_disabled
FROM sys.indexes
WHERE object_id = OBJECT_ID('dbo.Transfers_Archive')
ORDER BY is_disabled DESC, name;
```

**Duplicate check on the loaded range (optional; the PK rebuild proved it)**
```sql
SELECT Id, Created, COUNT(*) AS Cnt
FROM dbo.Transfers_Archive
WHERE Created > '2026-10-03 22:15:39.8920704'
GROUP BY Id, Created
HAVING COUNT(*) > 1;
```

**Foreign keys disabled along with the PK**
```sql
SELECT name, is_disabled, is_not_trusted
FROM sys.foreign_keys
WHERE referenced_object_id = OBJECT_ID('dbo.Transfers_Archive');
-- Re-enable: ALTER TABLE <child> WITH CHECK CHECK CONSTRAINT <fk_name>;
```

**Edition and log headroom**
```sql
SELECT SERVERPROPERTY('Edition') AS Edition;
SELECT used_log_space_in_percent, total_log_size_in_bytes / 1048576 AS total_log_mb
FROM sys.dm_db_log_space_usage;
```

**Watching a long operation**
```sql
SELECT r.session_id, r.command, r.status, r.wait_type, r.wait_time,
       r.cpu_time, r.total_elapsed_time / 1000 AS elapsed_s, r.dop, r.percent_complete
FROM sys.dm_exec_requests r
WHERE r.command LIKE '%INDEX%' OR r.command LIKE '%BULK%' OR r.command LIKE '%STATISTICS%';
```

**Rebuild loop for the remaining indexes (one at a time, timestamped)**
```sql
USE AccountSwitch;
SET NOCOUNT ON;

DECLARE @maxdop INT = 4;   -- raise to 8 only if CPU < ~50% and I/O isn't saturated
DECLARE @idx TABLE (seq INT IDENTITY, name SYSNAME);
INSERT @idx (name) VALUES
 ('IX_UniqueReference_Created'), ('IX_PaymentReference'),
 ('IX_SenderAccountNumber'), ('IX_BeneficiaryAccountNumber'),
 ('IX_Created_INCL_Amount'), ('IX_Created_ResponseCode_INCL_Amount'),
 ('IX_InstitutionId'), ('IX_DestinationInstitutionId'),
 ('IX_Status'), ('IX_TsqStatus');

DECLARE @i INT = 1, @n INT = (SELECT COUNT(*) FROM @idx), @name SYSNAME, @sql NVARCHAR(600);
WHILE @i <= @n
BEGIN
    SELECT @name = name FROM @idx WHERE seq = @i;
    RAISERROR('%s START %s', 0, 1, @name, '') WITH NOWAIT;
    PRINT CONVERT(varchar(19), GETDATE(), 120);

    SET @sql = N'ALTER INDEX ' + QUOTENAME(@name) + N' ON dbo.Transfers_Archive '
             + N'REBUILD WITH (ONLINE = ON, SORT_IN_TEMPDB = ON, MAXDOP = '
             + CAST(@maxdop AS NVARCHAR(4)) + N');';
    EXEC sp_executesql @sql;

    PRINT CONCAT(CONVERT(varchar(19), GETDATE(), 120), ' DONE  ', @name);
    WAITFOR DELAY '00:05:00';   -- let RDS log backups clear the log
    SET @i += 1;
END
```
