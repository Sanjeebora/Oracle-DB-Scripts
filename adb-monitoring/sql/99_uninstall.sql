--------------------------------------------------------------------------------
-- 99_uninstall.sql
--
-- Run as DBMON. Removes the jobs and all pack objects from this schema.
--
-- Stops short of dropping the DBMON user itself, because the historical data in
-- MON_METRIC and MON_ALERT is often worth exporting before it goes. Drop the
-- user from ADMIN afterwards if you really want it gone:
--
--     DROP USER dbmon CASCADE;
--
-- To stop monitoring without losing anything, do not run this. Use the kill
-- switch instead, which leaves every table in place:
--
--     EXEC pkg_mon.set_cfg('ENABLED','N');
--------------------------------------------------------------------------------
SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE OFF

PROMPT
PROMPT === Dropping scheduler jobs ===
DECLARE
BEGIN
  FOR r IN (SELECT job_name FROM user_scheduler_jobs
             WHERE job_name LIKE 'MON!_J!_%' ESCAPE '!') LOOP
    BEGIN
      DBMS_SCHEDULER.DROP_JOB(job_name => r.job_name, force => TRUE);
      DBMS_OUTPUT.PUT_LINE('  dropped  ' || r.job_name);
    EXCEPTION WHEN OTHERS THEN
      DBMS_OUTPUT.PUT_LINE('  FAILED   ' || r.job_name || ' -- ' || SQLERRM);
    END;
  END LOOP;
END;
/

PROMPT
PROMPT === Row counts before the drop ===
COLUMN what FORMAT A24
SELECT 'mon_metric'     AS what, COUNT(*) AS rows_held FROM mon_metric
UNION ALL SELECT 'mon_sql_slow',   COUNT(*) FROM mon_sql_slow
UNION ALL SELECT 'mon_alert',      COUNT(*) FROM mon_alert
UNION ALL SELECT 'mon_backup',     COUNT(*) FROM mon_backup
UNION ALL SELECT 'mon_notify_log', COUNT(*) FROM mon_notify_log
UNION ALL SELECT 'mon_job_log',    COUNT(*) FROM mon_job_log;

PROMPT
PROMPT === Dropping program units and views ===
DECLARE
  PROCEDURE drop_it (p_type VARCHAR2, p_name VARCHAR2) IS
  BEGIN
    EXECUTE IMMEDIATE 'DROP ' || p_type || ' ' || p_name;
    DBMS_OUTPUT.PUT_LINE('  dropped  ' || RPAD(p_type, 8) || p_name);
  EXCEPTION WHEN OTHERS THEN
    IF SQLCODE IN (-4043, -942) THEN
      DBMS_OUTPUT.PUT_LINE('  absent   ' || RPAD(p_type, 8) || p_name);
    ELSE
      DBMS_OUTPUT.PUT_LINE('  FAILED   ' || p_name || ' -- ' || SQLERRM);
    END IF;
  END;
BEGIN
  drop_it('PACKAGE', 'pkg_mon_test');
  drop_it('PACKAGE', 'pkg_mon_oci');
  drop_it('PACKAGE', 'pkg_mon');

  FOR r IN (SELECT view_name FROM user_views
             WHERE view_name LIKE 'V!_MON!_%' ESCAPE '!') LOOP
    drop_it('VIEW', r.view_name);
  END LOOP;
END;
/

PROMPT
PROMPT === Dropping tables ===
PROMPT   Comment out this block if you want to keep the history.
DECLARE
  PROCEDURE drop_tab (p_name VARCHAR2) IS
  BEGIN
    EXECUTE IMMEDIATE 'DROP TABLE ' || p_name || ' PURGE';
    DBMS_OUTPUT.PUT_LINE('  dropped  ' || p_name);
  EXCEPTION WHEN OTHERS THEN
    IF SQLCODE = -942 THEN
      DBMS_OUTPUT.PUT_LINE('  absent   ' || p_name);
    ELSE
      DBMS_OUTPUT.PUT_LINE('  FAILED   ' || p_name || ' -- ' || SQLERRM);
    END IF;
  END;
BEGIN
  drop_tab('mon_action_log');
  drop_tab('mon_job_log');
  drop_tab('mon_notify_log');
  drop_tab('mon_alert');
  drop_tab('mon_backup');
  drop_tab('mon_sql_slow');
  drop_tab('mon_metric');
  drop_tab('mon_config');
END;
/

PROMPT
PROMPT === Anything left behind ===
SELECT object_type, object_name FROM user_objects ORDER BY object_type, object_name;
