-- ==============================================================================
-- Required MySQL Privileges for gh-ost Execution
-- Target Database: monnify
-- Dedicated User: gh_ost_user
-- ==============================================================================

-- 1. Database-level object rights (for creating shadow/changelog tables)
GRANT ALTER, CREATE, DELETE, DROP, INDEX, INSERT, LOCK TABLES, SELECT, UPDATE 
  ON database.* TO 'gh_ost_user'@'%';

-- 2. Global replication rights (for streaming binary logs)
GRANT REPLICATION CLIENT, REPLICATION SLAVE ON *.* TO 'gh_ost_user'@'%';

FLUSH PRIVILEGES;
