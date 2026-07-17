# A Traffic-Light Dashboard: Turning Raw DMV Metrics Into an Instant Answer

*TL;DR:* Standard SQL Server monitoring dashboards show plenty of graphs — but during an actual incident at 3am, nobody wants to interpret ten charts, they want one unambiguous answer: is this system actually okay right now? I built a single-panel "traffic light" dashboard that synthesizes multiple raw system metrics into plain RED/AMBER/GREEN signals with human-readable meaning, so anyone glancing at it — not just a DBA — knows instantly whether to worry.

## The Problem

Standard monitoring surfaces raw numbers — wait stats, session counts, memory counters — that require real SQL Server expertise to correctly interpret under pressure. During an actual incident, the person looking at the dashboard first isn't always the most experienced DBA on the team, and even an experienced one loses time parsing charts instead of acting.

## Design Approach

Rather than add more graphs, I built one clean, five-row summary table where every row is a synthesized signal, not a raw metric:

Signal                 | Now              | Status | Meaning
Monitoring heartbeat    | 355 metrics/5min | GREEN  | RED = monitoring stopped
Blocking                | 0 blocked, max 0s| GREEN  | Transactions waiting on each other
Long-running queries    | 0 running, max 0s| GREEN  | A query is stuck / very slow
Active sessions         | 2                | GREEN  | Spike = app stampede / pile-up
Memory (PLE)            | 5668s            | GREEN  | Low = memory pressure / big scans


Each row has its own deliberate threshold logic reflecting real operational judgment for this specific system — not generic industry defaults:
- *Blocking* → RED if any session has waited 60+ seconds, or 5+ sessions are blocked simultaneously
- *Long-running queries* → RED at 300+ seconds
- *Active sessions* → RED at 150+, AMBER at 100+
- *Page Life Expectancy (memory pressure)* → RED under 300 seconds, AMBER under 600

The *monitoring heartbeat row is the most important one* — if the capture job itself has stopped running, every other row would falsely show GREEN simply because there's no new data to flag a problem. Making "is monitoring itself even alive" its own explicit signal closes that blind spot.

## The Implementation

A lightweight capture procedure (usp_CapturePerformanceSnapshot), run on a schedule via SQL Server Agent, pulls from the relevant DMVs — sys.dm_exec_requests, sys.dm_exec_sessions, sys.dm_os_wait_stats, sys.dm_os_performance_counters, tempdb space usage — into a single, deliberately generic EAV-style (entity-attribute-value) logging table:

sql
CREATE TABLE dbo.PerformanceLog(
    log_id BIGINT IDENTITY(1,1) PRIMARY KEY,
    snapshot_time DATETIME2(7) NOT NULL DEFAULT SYSDATETIME(),
    monitored_db VARCHAR(100) NOT NULL,
    metric_category VARCHAR(50) NOT NULL,
    metric_name VARCHAR(100) NOT NULL,
    metric_value BIGINT NULL,
    metric_value_decimal DECIMAL(18,4) NULL,
    metric_text NVARCHAR(MAX) NULL,
    session_id INT NULL,
    sql_text NVARCHAR(MAX) NULL,
    extra_json NVARCHAR(MAX) NULL
    -- full DDL in scripts/performance-log-schema.sql
);

On top of that, one single query converts the raw numbers into a plain traffic-light view:

SELECT Signal, [Now], Status, Meaning FROM (
  SELECT 0 ord, 'Monitoring heartbeat' Signal,
         CONCAT(COUNT(*),' metrics / 5 min') [Now],
         CASE WHEN COUNT(*)=0 THEN 'RED' ELSE 'GREEN' END Status,
         'RED = monitoring stopped' Meaning
  FROM dbo.PerformanceLog WHERE snapshot_time > DATEADD(MINUTE,-5,SYSDATETIME())
  UNION ALL
  SELECT 1,'Blocking',
         CONCAT(COUNT(*),' blocked, max ',ISNULL(MAX(metric_value),0),'s'),
         CASE WHEN ISNULL(MAX(metric_value),0)>=60 OR COUNT(*)>=5 THEN 'RED'
              WHEN COUNT(*)>0 THEN 'AMBER' ELSE 'GREEN' END,
         'Transactions waiting on each other'
  FROM dbo.PerformanceLog WHERE metric_category='blocking' AND snapshot_time>DATEADD(MINUTE,-2,SYSDATETIME())
  -- ... additional signals: long-running queries, active sessions, memory pressure
) v ORDER BY ord;

(Full table, capture procedure, and traffic-light query in scripts/traffic-light-dashboard.sql)

The detail that matters most: signal 0 — "Monitoring heartbeat" — isn't a real database health metric at all. It checks whether the capture job itself has produced any rows in the last 5 minutes. Without this, a dead monitoring job would silently show every other signal as a false "GREEN" — indistinguishable from genuine health. Monitoring your monitoring is not optional.

The Outcome
A single glance now answers "is this currently a problem" — no graph interpretation required, usable by technical and non-technical stakeholders alike
Thresholds tuned from real operational experience of what actually indicates a genuine problem versus normal noise
The heartbeat check has already caught the monitoring job itself failing silently, before anyone would have otherwise noticed
Broader Takeaways
A dashboard's job is to answer a specific question fast, not to display everything you technically could. Depth belongs in a drill-down, not the first thing anyone sees.
Any monitoring system needs to monitor its own aliveness. Otherwise a "healthy-looking" dashboard and a "broken monitoring" dashboard are visually identical.

Connect with me on LinkedIn if you're designing operational dashboards that actually get used during incidents.

