--------------------------------------------------------------------------------
-- t99_cleanup.sql   Remove test residue and put configuration back.
--
-- Safe to run at any time. Deletes only rows the tests create.
--------------------------------------------------------------------------------
SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE OFF

DECLARE
  l_n NUMBER;
BEGIN
  DBMS_OUTPUT.PUT_LINE(' ');
  DBMS_OUTPUT.PUT_LINE('--- cleanup -------------------------------------------------------');

  DELETE FROM mon_alert
   WHERE alert_key LIKE 'TEST!_%'      ESCAPE '!'
      OR alert_key LIKE 'RES!_TBS!_TEST!_%' ESCAPE '!'
      OR alert_key LIKE 'SQL!_LONG!_test%'  ESCAPE '!'
      OR alert_key LIKE 'SQL!_REGRESS!_test%' ESCAPE '!'
      OR alert_key LIKE 'BKP!_FAILED!_ocid1.autonomousdatabasebackup.oc1..test%' ESCAPE '!'
      OR alert_key LIKE 'BKP!_UNRESTORABLE%' ESCAPE '!'
      OR alert_key IN ('BKP_NONE','BKP_STALE','BKP_RETENTION','DB_LIFECYCLE',
                       'RES_QUEUE_TP','RES_LIMIT_sessions','RES_AAS');
  DBMS_OUTPUT.PUT_LINE('  alerts removed        : ' || SQL%ROWCOUNT);

  DELETE FROM mon_sql_slow WHERE sql_id LIKE 'test%';
  DBMS_OUTPUT.PUT_LINE('  fixture SQL removed   : ' || SQL%ROWCOUNT);

  DELETE FROM mon_metric WHERE metric_unit = 'test' OR metric_group = 'TEST';
  DBMS_OUTPUT.PUT_LINE('  fixture metrics removed: ' || SQL%ROWCOUNT);

  DELETE FROM mon_backup
   WHERE backup_id LIKE 'ocid1.autonomousdatabasebackup.oc1..test%'
      OR backup_id IN ('b1', 'b2');
  DBMS_OUTPUT.PUT_LINE('  fixture backups removed: ' || SQL%ROWCOUNT);

  DELETE FROM mon_notify_log WHERE title LIKE '%Smoke test%'
                                OR title LIKE '%Should%'
                                OR title LIKE '%Bad provider%'
                                OR title LIKE '%sighting%'
                                OR title LIKE '%RESOLVED%';
  DBMS_OUTPUT.PUT_LINE('  test notifications removed: ' || SQL%ROWCOUNT);

  COMMIT;

  -------------------------------------------------------- restore safe defaults
  pkg_mon.set_cfg('NOTIFY_MIN_SEVERITY',      'INFO');
  pkg_mon.set_cfg('ALERT_COOLDOWN_MIN',       '30');
  pkg_mon.set_cfg('ALERT_AUTOCLOSE_MIN',      '60');
  pkg_mon.set_cfg('TBS_PCT_WARN',             '85');
  pkg_mon.set_cfg('SLOW_SQL_SEC',             '300');
  pkg_mon.set_cfg('BACKUP_MAX_AGE_HOURS',     '30');
  pkg_mon.set_cfg('BACKUP_MIN_RETENTION_DAYS','30');
  pkg_mon.set_cfg('TEST_MODE',                'N');
  pkg_mon.reset_identity;

  DBMS_OUTPUT.PUT_LINE('  thresholds restored, TEST_MODE set back to N');

  SELECT COUNT(*) INTO l_n FROM mon_alert WHERE state = 'OPEN';
  DBMS_OUTPUT.PUT_LINE('  open alerts remaining : ' || l_n);
  DBMS_OUTPUT.PUT_LINE('  notify provider       : ' || pkg_mon.cfg('NOTIFY_PROVIDER'));
END;
/
