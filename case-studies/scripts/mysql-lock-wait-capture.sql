-- Captures real blocking relationships (who is blocking whom), not just "this query is slow"
CREATE TABLE monitoring.MONIT_LOCK_WAITS (
  id BIGINT NOT NULL AUTO_INCREMENT,
  waiting_trx_id VARCHAR(30),
  waiting_pid BIGINT,
  waiting_query TEXT,
  waiting_lock_mode VARCHAR(20),
  waiting_lock_type VARCHAR(20),
  waiting_table VARCHAR(200),
  wait_started DATETIME,
  wait_age_seconds INT,
  blocking_trx_id VARCHAR(30),
  blocking_pid BIGINT,
  blocking_query TEXT,
  blocking_lock_mode VARCHAR(20),
  CREATED_ON DATETIME DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_created_on (CREATED_ON)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

DELIMITER $$
CREATE PROCEDURE monitoring.check_lock_waits()
BEGIN
    INSERT INTO MONIT_LOCK_WAITS
      (waiting_trx_id, waiting_pid, waiting_query, waiting_lock_mode, waiting_lock_type, waiting_table,
       wait_started, wait_age_seconds, blocking_trx_id, blocking_pid, blocking_query, blocking_lock_mode)
    SELECT
      r.trx_id, r.trx_mysql_thread_id, r.trx_query,
      wl.LOCK_MODE, wl.LOCK_TYPE, wl.OBJECT_NAME,
      r.trx_wait_started, TIMESTAMPDIFF(SECOND, r.trx_wait_started, NOW()),
      b.trx_id, b.trx_mysql_thread_id, b.trx_query,
      bl.LOCK_MODE
    FROM information_schema.INNODB_TRX r
    JOIN performance_schema.data_lock_waits w ON r.trx_id = w.REQUESTING_ENGINE_TRANSACTION_ID
    JOIN performance_schema.data_locks wl ON w.REQUESTING_ENGINE_LOCK_ID = wl.ENGINE_LOCK_ID
    JOIN information_schema.INNODB_TRX b ON w.BLOCKING_ENGINE_TRANSACTION_ID = b.trx_id
    JOIN performance_schema.data_locks bl ON w.BLOCKING_ENGINE_LOCK_ID = bl.ENGINE_LOCK_ID
    WHERE r.trx_state = 'LOCK WAIT';
END$$
DELIMITER ;

-- Retention: built in from day one, not retrofitted after the table becomes its own problem
DELIMITER $$
CREATE PROCEDURE monitoring.purge_lock_wait_history()
BEGIN
    DELETE FROM MONIT_LOCK_WAITS WHERE CREATED_ON < DATE_SUB(NOW(), INTERVAL 30 DAY);
END$$
DELIMITER ;

-- Schedule check_lock_waits() every 5-10 seconds - lock waits escalate fast, tight polling matters
-- Schedule purge_lock_wait_history() daily
