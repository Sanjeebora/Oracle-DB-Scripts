--------------------------------------------------------------------------------
-- 09_jobs.sql
--
-- Run as DBMON. Creates the scheduler jobs. Re-runnable: existing jobs of the
-- same name are dropped and recreated.
--
-- Intervals are a starting point. Collect two weeks of data, look at
-- V_MON_HEALTH for the real cost of each collector, then adjust.
--------------------------------------------------------------------------------
SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE OFF

DECLARE
  PROCEDURE make_job (p_name     VARCHAR2,
                      p_action   VARCHAR2,
                      p_interval VARCHAR2,
                      p_enabled  BOOLEAN,
                      p_comment  VARCHAR2) IS
  BEGIN
    BEGIN
      DBMS_SCHEDULER.DROP_JOB(job_name => p_name, force => TRUE);
    EXCEPTION WHEN OTHERS THEN
      NULL;                                     -- did not exist
    END;

    DBMS_SCHEDULER.CREATE_JOB(
      job_name        => p_name,
      job_type        => 'PLSQL_BLOCK',
      job_action      => p_action,
      start_date      => SYSTIMESTAMP,
      repeat_interval => p_interval,
      enabled         => p_enabled,
      comments        => p_comment);

    DBMS_OUTPUT.PUT_LINE('  ' || RPAD(p_name, 20) ||
                         RPAD(p_interval, 34) ||
                         CASE WHEN p_enabled THEN 'ENABLED' ELSE 'DISABLED' END);
  END;
BEGIN
  make_job('MON_J_RESOURCE',
           'BEGIN pkg_mon.collect_resource; END;',
           'FREQ=MINUTELY;INTERVAL=1',
           TRUE,
           'Resource consumption: system metrics, consumer groups, storage, limits');

  make_job('MON_J_SLOWSQL',
           'BEGIN pkg_mon.collect_slow_sql; END;',
           'FREQ=MINUTELY;INTERVAL=5',
           TRUE,
           'Slow SQL: running statements, ASH top SQL, plan regressions');

  make_job('MON_J_BACKUP',
           'BEGIN pkg_mon_oci.check_backups; END;',
           'FREQ=MINUTELY;INTERVAL=30',
           TRUE,
           'Backup status polled from the OCI Database API');

  make_job('MON_J_DIGEST',
           'BEGIN pkg_mon.daily_digest; END;',
           'FREQ=DAILY;BYHOUR=7;BYMINUTE=0;BYSECOND=0',
           TRUE,
           'Morning summary, storage forecast, alert auto-close');

  make_job('MON_J_PURGE',
           'BEGIN pkg_mon.purge; END;',
           'FREQ=DAILY;BYHOUR=2;BYMINUTE=30;BYSECOND=0',
           TRUE,
           'Repository retention');

  -- Disabled by default: needs the "use metrics" IAM policy, and without it the
  -- job would write a WARN row every five minutes. Enable once the policy is in
  -- place, then add an OCI alarm on absence of custom_adb_monitor/MonitorHeartbeat.
  -- That alarm is the only thing that can tell you the monitoring itself died.
  make_job('MON_J_HEARTBEAT',
           'BEGIN pkg_mon_oci.publish_heartbeat; END;',
           'FREQ=MINUTELY;INTERVAL=5',
           FALSE,
           'Publishes custom metrics to OCI Monitoring, including a heartbeat');
END;
/

PROMPT
PROMPT --- Scheduled jobs
COLUMN job_name        FORMAT A18
COLUMN repeat_interval FORMAT A34
COLUMN state           FORMAT A10
COLUMN next_run_date   FORMAT A34
SELECT job_name, repeat_interval, enabled, state, next_run_date
FROM   user_scheduler_jobs
WHERE  job_name LIKE 'MON!_J!_%' ESCAPE '!'
ORDER  BY job_name;

PROMPT
PROMPT To enable the heartbeat later:
PROMPT   EXEC DBMS_SCHEDULER.ENABLE('MON_J_HEARTBEAT');;
