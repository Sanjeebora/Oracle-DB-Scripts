--------------------------------------------------------------------------------
-- 02_tables.sql
--
-- Run as DBMON. Creates all repository objects.
-- Re-runnable: existing objects are left in place.
--------------------------------------------------------------------------------
SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE OFF

DECLARE
  PROCEDURE ddl (p_name VARCHAR2, p_stmt VARCHAR2) IS
  BEGIN
    EXECUTE IMMEDIATE p_stmt;
    DBMS_OUTPUT.PUT_LINE('  created  ' || p_name);
  EXCEPTION WHEN OTHERS THEN
    IF SQLCODE IN (-955, -1408, -2260, -1442) THEN            -- already exists
      DBMS_OUTPUT.PUT_LINE('  exists   ' || p_name);
    ELSE
      DBMS_OUTPUT.PUT_LINE('  FAILED   ' || p_name || ' -- ' || SQLERRM);
      RAISE;
    END IF;
  END;
BEGIN
  ------------------------------------------------------------------ config ---
  ddl('MON_CONFIG', q'[
    CREATE TABLE mon_config (
      cfg_key    VARCHAR2(64)   NOT NULL,
      cfg_value  VARCHAR2(4000),
      descr      VARCHAR2(400),
      updated_at TIMESTAMP DEFAULT SYSTIMESTAMP,
      CONSTRAINT mon_config_pk PRIMARY KEY (cfg_key)
    )]');

  ----------------------------------------------------------------- metrics ---
  ddl('MON_METRIC', q'[
    CREATE TABLE mon_metric (
      collected_at TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
      metric_group VARCHAR2(30)  NOT NULL,
      metric_name  VARCHAR2(128) NOT NULL,
      dim1         VARCHAR2(128),
      metric_value NUMBER,
      metric_unit  VARCHAR2(30)
    )]');
  ddl('MON_METRIC_IX1', 'CREATE INDEX mon_metric_ix1 ON mon_metric (collected_at)');
  ddl('MON_METRIC_IX2', 'CREATE INDEX mon_metric_ix2 ON mon_metric (metric_name, collected_at)');

  --------------------------------------------------------------- slow SQL ---
  ddl('MON_SQL_SLOW', q'[
    CREATE TABLE mon_sql_slow (
      captured_at  TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
      source       VARCHAR2(20)  NOT NULL,          -- RTSM | ASH | AWR
      sql_id       VARCHAR2(13),
      plan_hash    NUMBER,
      username     VARCHAR2(128),
      service_name VARCHAR2(128),
      module       VARCHAR2(128),
      elapsed_sec  NUMBER,
      cpu_sec      NUMBER,
      buffer_gets  NUMBER,
      rows_proc    NUMBER,
      execs        NUMBER,
      top_event    VARCHAR2(128),
      sql_text     VARCHAR2(4000)
    )]');
  ddl('MON_SQL_SLOW_IX1', 'CREATE INDEX mon_sql_slow_ix1 ON mon_sql_slow (captured_at)');
  ddl('MON_SQL_SLOW_IX2', 'CREATE INDEX mon_sql_slow_ix2 ON mon_sql_slow (sql_id, captured_at)');

  ----------------------------------------------------------------- backups ---
  ddl('MON_BACKUP', q'[
    CREATE TABLE mon_backup (
      backup_id         VARCHAR2(255) NOT NULL,
      display_name      VARCHAR2(255),
      backup_type       VARCHAR2(30),
      is_automatic      VARCHAR2(10),
      lifecycle_state   VARCHAR2(30),
      lifecycle_details VARCHAR2(2000),
      time_started      TIMESTAMP WITH TIME ZONE,
      time_ended        TIMESTAMP WITH TIME ZONE,
      is_restorable     VARCHAR2(10),
      retention_days    NUMBER,
      first_seen_at     TIMESTAMP DEFAULT SYSTIMESTAMP,
      last_seen_at      TIMESTAMP DEFAULT SYSTIMESTAMP,
      CONSTRAINT mon_backup_pk PRIMARY KEY (backup_id)
    )]');
  ddl('MON_BACKUP_IX1', 'CREATE INDEX mon_backup_ix1 ON mon_backup (lifecycle_state, time_ended)');

  ------------------------------------------------------------------ alerts ---
  ddl('MON_ALERT', q'[
    CREATE TABLE mon_alert (
      alert_id      NUMBER GENERATED ALWAYS AS IDENTITY,
      alert_key     VARCHAR2(200) NOT NULL,
      severity      VARCHAR2(10)  NOT NULL,
      title         VARCHAR2(400),
      detail        CLOB,
      state         VARCHAR2(10) DEFAULT 'OPEN' NOT NULL,
      occurrences   NUMBER       DEFAULT 1,
      first_seen_at TIMESTAMP    DEFAULT SYSTIMESTAMP,
      last_seen_at  TIMESTAMP    DEFAULT SYSTIMESTAMP,
      notified_at   TIMESTAMP,
      closed_at     TIMESTAMP,
      notify_error  VARCHAR2(4000),
      CONSTRAINT mon_alert_pk  PRIMARY KEY (alert_id),
      CONSTRAINT mon_alert_ck1 CHECK (severity IN ('CRITICAL','WARNING','INFO')),
      CONSTRAINT mon_alert_ck2 CHECK (state    IN ('OPEN','CLOSED'))
    )]');

  -- At most one OPEN alert per key, while keeping the full closed history.
  -- The expression must be a single column that is NULL for closed rows: a row
  -- whose entire index key is NULL is not indexed, so closed rows never collide.
  -- A two-column version such as (alert_key, DECODE(state,'OPEN','OPEN',NULL))
  -- looks equivalent but is not; partially null keys are still indexed, and the
  -- second time an alert closes it raises ORA-00001.
  ddl('MON_ALERT_UX1', q'[
    CREATE UNIQUE INDEX mon_alert_ux1
        ON mon_alert (CASE WHEN state = 'OPEN' THEN alert_key END)]');
  ddl('MON_ALERT_IX2', 'CREATE INDEX mon_alert_ix2 ON mon_alert (last_seen_at)');

  ------------------------------------------------------------ notify audit ---
  ddl('MON_NOTIFY_LOG', q'[
    CREATE TABLE mon_notify_log (
      sent_at   TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
      provider  VARCHAR2(30),
      severity  VARCHAR2(10),
      title     VARCHAR2(400),
      body      CLOB,
      status    VARCHAR2(10),
      err       VARCHAR2(4000)
    )]');
  ddl('MON_NOTIFY_LOG_IX1', 'CREATE INDEX mon_notify_log_ix1 ON mon_notify_log (sent_at)');

  ----------------------------------------------------------------- job log ---
  ddl('MON_JOB_LOG', q'[
    CREATE TABLE mon_job_log (
      run_at     TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
      proc_name  VARCHAR2(60),
      status     VARCHAR2(10),                      -- OK | WARN | ERROR | SKIP
      ms_elapsed NUMBER,
      err        VARCHAR2(4000)
    )]');
  ddl('MON_JOB_LOG_IX1', 'CREATE INDEX mon_job_log_ix1 ON mon_job_log (run_at)');

  ------------------------------------------------------ remediation audit ---
  ddl('MON_ACTION_LOG', q'[
    CREATE TABLE mon_action_log (
      acted_at    TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
      action_type VARCHAR2(40),
      target      VARCHAR2(400),
      reason      VARCHAR2(1000),
      performed   VARCHAR2(10),                     -- YES | DRYRUN | BLOCKED
      err         VARCHAR2(4000)
    )]');
END;
/

PROMPT
PROMPT --- Objects in DBMON
SELECT object_type, object_name, status
FROM   user_objects
WHERE  object_name LIKE 'MON!_%' ESCAPE '!'
ORDER  BY object_type, object_name;
