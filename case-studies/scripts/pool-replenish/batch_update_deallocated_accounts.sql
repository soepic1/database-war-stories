USE `database_name`;

-- =============================================================================
-- Procedure: batch_update_deallocated_accounts
-- Description: Iteratively updates deallocated accounts back to AVAILABLE status
--              in non-blocking 1,000-row micro-transactions to eliminate lock
--              contention and replication lag spikes on live production DBs.
-- Parameters:
--   p_provider_code   - Target provider (e.g., '23283')
--   p_cutoff_datetime - Datetime threshold for deallocation age
--   p_max_rows        - Hard ceiling for total rows to process in one run (default: 100000)
-- =============================================================================

DROP PROCEDURE IF EXISTS `batch_update_deallocated_accounts`;

DELIMITER $$

CREATE DEFINER=`definername`@`%` PROCEDURE `batch_update_deallocated_accounts`(
    IN  p_provider_code   VARCHAR(10),
    IN  p_cutoff_datetime DATETIME,
    IN  p_max_rows        INT,
    OUT p_total_updated   INT,
    OUT p_iterations      INT,
    OUT p_targeted        INT,
    OUT p_status          VARCHAR(255)
)
proc_body: BEGIN
    DECLARE v_rows_updated  INT DEFAULT 0;
    DECLARE v_total_updated INT DEFAULT 0;
    DECLARE v_iteration     INT DEFAULT 0;
    DECLARE v_remaining     INT DEFAULT 0;
    DECLARE v_target_count  INT DEFAULT 0;
    DECLARE v_run_ts        DATETIME;

    -- Error Handling: Roll back current micro-transaction on failure
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SET p_total_updated = v_total_updated;
        SET p_iterations    = v_iteration;
        SET p_targeted      = v_target_count;
        SET p_status        = CONCAT('FAILED at iteration ', v_iteration,
                                     '; committed before failure: ', v_total_updated);
        DROP TEMPORARY TABLE IF EXISTS tmp_target_dealloc_accounts;
        RESIGNAL;
    END;

    SET p_total_updated = 0;
    SET p_iterations    = 0;
    SET p_targeted      = 0;
    SET p_status        = 'NOT_STARTED';

    -- Lock safety configurations
    SET SESSION innodb_lock_wait_timeout = 5;
    SET SESSION autocommit = 1;

    -- Input Validation
    IF p_provider_code IS NULL OR p_cutoff_datetime IS NULL THEN
        SET p_status = 'ABORTED: p_provider_code and p_cutoff_datetime are required';
        LEAVE proc_body;
    END IF;

    IF p_cutoff_datetime > NOW() THEN
        SET p_status = 'ABORTED: cutoff is in the future';
        LEAVE proc_body;
    END IF;

    -- Default fallback ceiling
    IF p_max_rows IS NULL OR p_max_rows <= 0 THEN
        SET p_max_rows = 100000;
    END IF;

    SET v_run_ts = NOW();

    -- 1. Snapshot target records into an indexed temporary table
    DROP TEMPORARY TABLE IF EXISTS tmp_target_dealloc_accounts;
    CREATE TEMPORARY TABLE tmp_target_dealloc_accounts (
        account_number VARCHAR(10) NOT NULL,
        provider_code  VARCHAR(10) NOT NULL,
        PRIMARY KEY (account_number, provider_code)
    ) ENGINE=InnoDB;

    INSERT INTO tmp_target_dealloc_accounts (account_number, provider_code)
    SELECT account_number, provider_code
    FROM monnify_account_provider.deallocated_accounts
    WHERE provider_code = p_provider_code
      AND account_deallocated_at < p_cutoff_datetime
      AND merchant_id IS NOT NULL
    ORDER BY account_deallocated_at ASC
    LIMIT p_max_rows;

    SET v_target_count = ROW_COUNT();
    SET p_targeted      = v_target_count;

    IF v_target_count = 0 THEN
        DROP TEMPORARY TABLE IF EXISTS tmp_target_dealloc_accounts;
        SET p_status = 'COMPLETED: 0 eligible rows for this cutoff';
        LEAVE proc_body;
    END IF;

    -- 2. Micro-commit iteration loop
    update_loop: LOOP
        SELECT COUNT(*) INTO v_remaining FROM tmp_target_dealloc_accounts;
        IF v_remaining = 0 THEN
            LEAVE update_loop;
        END IF;

        SET v_iteration = v_iteration + 1;

        START TRANSACTION;

            UPDATE monnify_account_provider.deallocated_accounts main
            JOIN (
                SELECT account_number, provider_code
                FROM tmp_target_dealloc_accounts
                ORDER BY account_number, provider_code
                LIMIT 1000
            ) batch
              ON main.account_number = batch.account_number
             AND main.provider_code  = batch.provider_code
            SET main.account_ready_for_allocation_at = v_run_ts,
                main.merchant_id      = NULL,
                main.status           = 'AVAILABLE',
                main.last_modified_on = v_run_ts;

            SET v_rows_updated  = ROW_COUNT();
            SET v_total_updated = v_total_updated + v_rows_updated;

            DELETE FROM tmp_target_dealloc_accounts
            ORDER BY account_number, provider_code
            LIMIT 1000;

        COMMIT;

        -- Micro-sleep to yield CPU and DB thread locks back to live API queries
        DO SLEEP(0.05);
    END LOOP update_loop;

    DROP TEMPORARY TABLE IF EXISTS tmp_target_dealloc_accounts;

    SET p_total_updated = v_total_updated;
    SET p_iterations    = v_iteration;
    SET p_status        = CONCAT('COMPLETED: ', v_total_updated,
                                 ' rows updated in ', v_iteration,
                                 ' batches (targeted ', v_target_count, ')');
END$$

DELIMITER ;




