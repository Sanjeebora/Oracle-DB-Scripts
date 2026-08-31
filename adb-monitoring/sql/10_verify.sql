--------------------------------------------------------------------------------
-- 10_verify.sql
--
-- Run as DBMON immediately after deployment.
--
-- Does four things:
--   1. Arms the clone guard with this database's OCID.
--   2. Parses every collector statement against the live dictionary.
--   3. Runs one collection cycle by hand and shows what it produced.
--   4. Reports anything invalid.
--------------------------------------------------------------------------------
SET SERVEROUTPUT ON SIZE UNLIMITED
SET LINESIZE 200
SET DEFINE OFF

PROMPT
PROMPT ================================================================
PROMPT  1. Arm the clone guard
PROMPT ================================================================
DECLARE
  l_ocid VARCHAR2(255) := pkg_mon.db_ocid;
BEGIN
  IF l_ocid IS NULL THEN
    DBMS_OUTPUT.PUT_LINE('  Database OCID could not be determined.');
    DBMS_OUTPUT.PUT_LINE('  The clone guard stays off. On a real ADB, check that');
    DBMS_OUTPUT.PUT_LINE('  DBMON has SELECT on V$PDBS, or set DB_OCID in MON_CONFIG.');
  ELSE
    pkg_mon.set_cfg('EXPECTED_DB_OCID', l_ocid);
    DBMS_OUTPUT.PUT_LINE('  Clone guard armed for ' || l_ocid);
    DBMS_OUTPUT.PUT_LINE('  A clone of this database will now stay silent instead of');
    DBMS_OUTPUT.PUT_LINE('  paging the on-call for production.');
  END IF;
END;
/

PROMPT
PROMPT ================================================================
PROMPT  2. Parse every collector against this dictionary
PROMPT ================================================================
BEGIN
  pkg_mon.validate_sql;
END;
/

PROMPT
PROMPT ================================================================
PROMPT  3. One collection cycle, run by hand
PROMPT ================================================================
BEGIN
  pkg_mon.collect_resource;
  pkg_mon.collect_slow_sql;
END;
/

PROMPT
PROMPT --- Metrics captured
COLUMN metric_group FORMAT A12
COLUMN metric_name  FORMAT A36
COLUMN dim1         FORMAT A16
-- Latest sample per metric. The scheduler is already running by this point, so
-- showing every raw row would bury the answer.
SELECT metric_group, metric_name, dim1,
       ROUND(MAX(metric_value) KEEP (DENSE_RANK LAST ORDER BY collected_at), 3) AS value,
       MAX(metric_unit) AS metric_unit,
       COUNT(*) AS samples
FROM   mon_metric
WHERE  collected_at > SYSTIMESTAMP - INTERVAL '5' MINUTE
GROUP  BY metric_group, metric_name, dim1
ORDER  BY metric_group, metric_name, dim1;

PROMPT
PROMPT --- Collector outcomes
COLUMN proc_name FORMAT A32
COLUMN err       FORMAT A70
SELECT proc_name, status, ms_elapsed, SUBSTR(err, 1, 70) AS err
FROM   mon_job_log
WHERE  run_at > SYSTIMESTAMP - INTERVAL '5' MINUTE
ORDER  BY run_at;

PROMPT
PROMPT ================================================================
PROMPT  4. Installation state
PROMPT ================================================================
BEGIN
  pkg_mon.self_test;
END;
/

PROMPT
PROMPT --- Invalid objects (should be none)
SELECT object_type, object_name, status
FROM   user_objects
WHERE  status <> 'VALID'
ORDER  BY object_type, object_name;

PROMPT
PROMPT --- Reminder
PROMPT   NOTIFY_PROVIDER is 'log' until you change it, so nothing is delivered
PROMPT   anywhere yet. Alerts are recorded in MON_ALERT and MON_NOTIFY_LOG.
PROMPT
PROMPT   To start delivering, pick one:
PROMPT     EXEC pkg_mon.set_cfg('NOTIFY_TOPIC_OCID','ocid1.onstopic....');;
PROMPT     EXEC pkg_mon.set_cfg('NOTIFY_PROVIDER','oci');;
PROMPT   or
PROMPT     EXEC pkg_mon.set_cfg('NOTIFY_CHANNEL','C01234567');;
PROMPT     EXEC pkg_mon.set_cfg('NOTIFY_CREDENTIAL','SLACK_CRED');;
PROMPT     EXEC pkg_mon.set_cfg('NOTIFY_PROVIDER','slack');;
PROMPT
PROMPT   Then run test/t01_notify.sql to prove delivery end to end.
