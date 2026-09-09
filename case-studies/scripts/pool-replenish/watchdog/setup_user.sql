-- setup_user.sql
-- Creates a restricted database user for non-invasive observability polling.

CREATE USER 'slow_query_finder'@'%' IDENTIFIED BY 'your_secure_password_here';

-- Grant read-only access to system metadata tables
GRANT PROCESS, SELECT ON information_schema.* TO 'slow_query_finder'@'%';
GRANT SELECT ON performance_schema.threads TO 'slow_query_finder'@'%';
GRANT SELECT ON performance_schema.data_lock_waits TO 'slow_query_finder'@'%';

-- Grant read/write access ONLY to the custom telemetry schema
GRANT SELECT, INSERT, UPDATE ON monitoring.slow_query_incidents TO 'slow_query_finder'@'%';

FLUSH PRIVILEGES;

Create Table:

CREATE TABLE `slow_query_incidents` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `processlist_id` bigint NOT NULL,
  `trx_id` varchar(32) DEFAULT NULL,
  `db_user` varchar(128) DEFAULT NULL,
  `host` varchar(128) DEFAULT NULL,
  `db_name` varchar(128) DEFAULT NULL,
  `command` varchar(32) DEFAULT NULL,
  `first_detected_at` datetime(3) NOT NULL,
  `last_seen_at` datetime(3) NOT NULL,
  `resolved_at` datetime(3) DEFAULT NULL,
  `max_time_sec` int DEFAULT NULL,
  `trx_state` varchar(32) DEFAULT NULL,
  `is_idle_in_trx` tinyint(1) DEFAULT '0',
  `rows_locked` bigint DEFAULT '0',
  `rows_modified` bigint DEFAULT '0',
  `query_text` mediumtext,
  `query_fingerprint` varchar(32) DEFAULT NULL,
  `blocking_thread_count` int DEFAULT '0',
  `is_blocking` tinyint(1) DEFAULT '0',
  `status` enum('ACTIVE','RESOLVED') DEFAULT 'ACTIVE',
  `severity` enum('LOW','MEDIUM','HIGH','CRITICAL') DEFAULT 'LOW',
  `notes` text,
  PRIMARY KEY (`id`),
  KEY `idx_status_processlist` (`status`,`processlist_id`),
  KEY `idx_severity` (`severity`,`first_detected_at`),
  KEY `idx_status_resolved_at` (`status`,`resolved_at`)
) ENGINE=InnoDB AUTO_INCREMENT=9725 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
