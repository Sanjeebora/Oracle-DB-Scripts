--------------------------------------------------------------------------------
-- t03_resource.sql   Resource consumption thresholds, driven from fixtures.
--
-- Rather than trying to create real load, this pushes known values into
-- MON_METRIC and asserts that evaluate_resource reaches the right conclusion.
-- The last section runs a real collection so you can see live values too.
--------------------------------------------------------------------------------
SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE OFF

DECLARE
  l_n NUMBER;

  PROCEDURE fixture (p_group VARCHAR2, p_name VARCHAR2,
                     p_dim VARCHAR2, p_val NUMBER) IS
  BEGIN
    INSERT INTO mon_metric (metric_group, metric_name, dim1, metric_value, metric_unit)
    VALUES (p_group, p_name, p_dim, p_val, 'test');
  END;

  PROCEDURE clean_window IS
  BEGIN
    DELETE FROM mon_metric WHERE collected_at > SYSTIMESTAMP - INTERVAL '20' MINUTE;
    DELETE FROM mon_alert  WHERE alert_key LIKE 'RES!_%' ESCAPE '!';
    COMMIT;
  END;
BEGIN
  pkg_mon_test.require_test_mode;
  pkg_mon_test.section('t03 resource thresholds');

  pkg_mon.set_cfg('NOTIFY_PROVIDER', 'log');

  ------------------------------------------------------------------ CPU bound
  clean_window;
  fixture('SYS',  'Average Active Sessions', NULL,     12);
  fixture('SYS',  'cpu_count',               NULL,      4);
  fixture('RSRC', 'active_sessions',         'HIGH',    8);
  fixture('RSRC', 'active_sessions',         'MEDIUM',  4);
  COMMIT;

  pkg_mon.evaluate_resource;

  SELECT COUNT(*) INTO l_n FROM mon_alert WHERE alert_key = 'RES_AAS' AND state = 'OPEN';
  pkg_mon_test.eq('12 active sessions on 4 CPUs raises RES_AAS', l_n, 1);

  SELECT COUNT(*) INTO l_n
    FROM mon_alert
   WHERE alert_key = 'RES_AAS' AND state = 'OPEN'
     AND DBMS_LOB.INSTR(detail, 'HIGH=8') > 0;
  pkg_mon_test.eq('the alert names the busiest consumer group', l_n, 1);

  ------------------------------------------------- healthy load clears it again
  clean_window;
  fixture('SYS', 'Average Active Sessions', NULL, 1);
  fixture('SYS', 'cpu_count',               NULL, 4);
  COMMIT;

  pkg_mon.evaluate_resource;

  SELECT COUNT(*) INTO l_n FROM mon_alert WHERE alert_key = 'RES_AAS' AND state = 'OPEN';
  pkg_mon_test.eq('healthy load closes RES_AAS', l_n, 0);

  ------------------------------------------- high CPU with no queueing is fine
  -- The point of the design: a database pinned at high CPU with nothing waiting
  -- is well used, not broken. It must not page anyone.
  clean_window;
  fixture('SYS',  'Average Active Sessions', NULL,   3.5);
  fixture('SYS',  'cpu_count',               NULL,   4);
  fixture('SYS',  'Database CPU Time Ratio', NULL,  97);
  fixture('RSRC', 'queue_length',            'HIGH', 0);
  COMMIT;

  pkg_mon.evaluate_resource;

  SELECT COUNT(*) INTO l_n FROM mon_alert
   WHERE alert_key IN ('RES_AAS', 'RES_QUEUE_HIGH') AND state = 'OPEN';
  pkg_mon_test.eq('97% CPU with an empty queue raises nothing', l_n, 0);

  --------------------------------------------------------- statement queueing
  clean_window;
  fixture('RSRC', 'queue_length', 'TP',     9);
  fixture('RSRC', 'queue_length', 'MEDIUM', 0);
  COMMIT;

  pkg_mon.evaluate_resource;

  SELECT COUNT(*) INTO l_n FROM mon_alert
   WHERE alert_key = 'RES_QUEUE_TP' AND state = 'OPEN';
  pkg_mon_test.eq('queue depth 9 in TP raises RES_QUEUE_TP', l_n, 1);

  SELECT COUNT(*) INTO l_n FROM mon_alert
   WHERE alert_key = 'RES_QUEUE_MEDIUM' AND state = 'OPEN';
  pkg_mon_test.eq('an empty queue in MEDIUM stays quiet', l_n, 0);

  --------------------------------------------------------------- storage tiers
  clean_window;
  fixture('STORAGE', 'tablespace_used_pct', 'TEST_WARN', 88);
  fixture('STORAGE', 'tablespace_used_pct', 'TEST_CRIT', 95);
  fixture('STORAGE', 'tablespace_used_pct', 'TEST_OK',   40);
  COMMIT;

  pkg_mon.evaluate_resource;

  SELECT MAX(CASE severity WHEN 'WARNING' THEN 1 WHEN 'CRITICAL' THEN 2 ELSE 0 END)
    INTO l_n
    FROM mon_alert WHERE alert_key = 'RES_TBS_TEST_WARN' AND state = 'OPEN';
  pkg_mon_test.eq('88% used is a WARNING', l_n, 1);

  SELECT MAX(CASE severity WHEN 'WARNING' THEN 1 WHEN 'CRITICAL' THEN 2 ELSE 0 END)
    INTO l_n
    FROM mon_alert WHERE alert_key = 'RES_TBS_TEST_CRIT' AND state = 'OPEN';
  pkg_mon_test.eq('95% used escalates to CRITICAL', l_n, 2);

  SELECT COUNT(*) INTO l_n FROM mon_alert
   WHERE alert_key = 'RES_TBS_TEST_OK' AND state = 'OPEN';
  pkg_mon_test.eq('40% used raises nothing', l_n, 0);

  --------------------------------------------------------- session saturation
  clean_window;
  fixture('LIMIT', 'utilization_pct', 'sessions',  93);
  fixture('LIMIT', 'utilization_pct', 'processes', 30);
  COMMIT;

  pkg_mon.evaluate_resource;

  SELECT COUNT(*) INTO l_n FROM mon_alert
   WHERE alert_key = 'RES_LIMIT_sessions' AND state = 'OPEN';
  pkg_mon_test.eq('93% session utilisation raises an alert', l_n, 1);

  ------------------------------------------------ thresholds come from config
  clean_window;
  pkg_mon.set_cfg('TBS_PCT_WARN', '99');
  fixture('STORAGE', 'tablespace_used_pct', 'TEST_TUNE', 95);
  COMMIT;
  pkg_mon.evaluate_resource;

  SELECT COUNT(*) INTO l_n FROM mon_alert
   WHERE alert_key = 'RES_TBS_TEST_TUNE' AND state = 'OPEN';
  pkg_mon_test.eq('raising the threshold in MON_CONFIG suppresses the alert', l_n, 0);
  pkg_mon.set_cfg('TBS_PCT_WARN', '85');

  ------------------------------------------------------------------- cleanup
  clean_window;
  DELETE FROM mon_notify_log;
  COMMIT;
END;
/

PROMPT
PROMPT --- Live collection (real values from this database)
BEGIN
  pkg_mon.collect_resource;
END;
/

COLUMN metric_group FORMAT A10
COLUMN metric_name  FORMAT A36
COLUMN dim1         FORMAT A14
SELECT metric_group, metric_name, dim1, ROUND(metric_value, 3) AS value
FROM   mon_metric
WHERE  collected_at > SYSTIMESTAMP - INTERVAL '2' MINUTE
ORDER  BY metric_group, metric_name, dim1;
