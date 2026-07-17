-- Persists Performance Schema's rolling digest window into durable history,
-- giving a real per-query-pattern baseline instead of one flat global threshold
CREATE TABLE monitoring.MONIT_QUERY_DIGEST_SNAPSHOT (
  id BIGINT NOT NULL AUTO_INCREMENT,
  digest VARCHAR(64),
  digest_text TEXT,
  schema_name VARCHAR(64),
  count_star BIGINT,
  avg_timer_wait_ms DECIMAL(12,2),
  max_timer_wait_ms DECIMAL(12,2),
  sum_rows_examined BIGINT,
  sum_rows_sent BIGINT,
  first_seen DATETIME,
  last_seen DATETIME,
  CREATED_ON DATETIME DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_digest (digest),
  KEY idx_created_on (CREATED_ON)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

DELIMITER $$
CREATE PROCEDURE monitoring.check_query_digest()
BEGIN
    INSERT INTO MONIT_QUERY_DIGEST_SNAPSHOT
      (digest, digest_text, schema_name, count_star, avg_timer_wait_ms, max_timer_wait_ms,
       sum_rows_examined, sum_rows_sent, first_seen, last_seen)
    SELECT
      DIGEST, DIGEST_TEXT, SCHEMA_NAME, COUNT_STAR,
      ROUND(AVG_TIMER_WAIT/1000000000,2), ROUND(MAX_TIMER_WAIT/1000000000,2),
      SUM_ROWS_EXAMINED, SUM_ROWS_SENT, FIRST_SEEN, LAST_SEEN
    FROM performance_schema.events_statements_summary_by_digest
    WHERE LAST_SEEN > DATE_SUB(NOW(), INTERVAL 15 MINUTE);
END$$
DELIMITER ;

-- Retention: keep enough history for real baseline comparison, without growing unbounded
DELIMITER $$
CREATE PROCEDURE monitoring.purge_digest_snapshot_history()
BEGIN
    DELETE FROM MONIT_QUERY_DIGEST_SNAPSHOT WHERE CREATED_ON < DATE_SUB(NOW(), INTERVAL 90 DAY);
END$$
DELIMITER ;

-- Schedule check_query_digest() every 15 minutes
-- Schedule purge_digest_snapshot_history() daily
