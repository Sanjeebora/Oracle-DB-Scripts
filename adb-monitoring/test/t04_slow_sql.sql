--------------------------------------------------------------------------------
-- t04_slow_sql.sql   Slow SQL detection and reporting views.
--
-- Fixture driven, then an optional live section that runs a genuinely slow
-- query so you can watch the real collector catch it.
--------------------------------------------------------------------------------
SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE OFF

DECLARE
  l_n   NUMBER;
  l_txt VARCHAR2(4000);
BEGIN
  pkg_mon_test.require_test_mode;
  pkg_mon_test.section('t04 slow SQL');

  pkg_mon.set_cfg('NOTIFY_PROVIDER', 'log');

  DELETE FROM mon_sql_slow WHERE sql_id LIKE 'test%';
  DELETE FROM mon_alert    WHERE alert_key LIKE 'SQL!_%' ESCAPE '!';
  COMMIT;

  --------------------------------------------------- a statement running too long
  INSERT INTO mon_sql_slow (source, sql_id, plan_hash, username, service_name,
                            module, elapsed_sec, cpu_sec, sql_text)
  VALUES ('RTSM', 'testslow0001', 1234567890, 'APPUSER', 'myadb_tp',
          'BatchLoader', 900, 850,
          'UPDATE orders SET status = :1 WHERE created < :2');
  COMMIT;

  pkg_mon.evaluate_slow_sql;

  SELECT COUNT(*) INTO l_n
    FROM mon_alert WHERE alert_key = 'SQL_LONG_testslow0001' AND state = 'OPEN';
  pkg_mon_test.eq('a 15 minute statement raises an alert', l_n, 1);

  SELECT SUBSTR(detail, 1, 4000) INTO l_txt
    FROM mon_alert WHERE alert_key = 'SQL_LONG_testslow0001' AND state = 'OPEN';

  pkg_mon_test.ok('alert names the user',   INSTR(l_txt, 'APPUSER') > 0);
  pkg_mon_test.ok('alert names the module', INSTR(l_txt, 'BatchLoader') > 0);
  pkg_mon_test.ok('alert shows the SQL text', INSTR(l_txt, 'UPDATE orders') > 0);
  pkg_mon_test.ok('alert hands over a next step (SQL monitor report)',
                  INSTR(l_txt, 'REPORT_SQL_MONITOR') > 0);

  ---------------------------------------------------- duplicate captures dedupe
  INSERT INTO mon_sql_slow (source, sql_id, elapsed_sec, username)
  VALUES ('RTSM', 'testslow0001', 960, 'APPUSER');
  COMMIT;

  pkg_mon.evaluate_slow_sql;

  SELECT COUNT(*) INTO l_n FROM mon_alert WHERE alert_key = 'SQL_LONG_testslow0001';
  pkg_mon_test.eq('the same statement does not create a second alert', l_n, 1);

  ------------------------------------------------------- top SQL view aggregates
  INSERT INTO mon_sql_slow (source, sql_id, plan_hash, username, module,
                            elapsed_sec, top_event, sql_text)
  VALUES ('ASH', 'testash00001', 111, 'REPORTS', 'Dashboard', 240,
          'db file sequential read', 'SELECT * FROM sales_summary');
  INSERT INTO mon_sql_slow (source, sql_id, plan_hash, username, module,
                            elapsed_sec, top_event, sql_text)
  VALUES ('ASH', 'testash00001', 111, 'REPORTS', 'Dashboard', 180,
          'db file sequential read', 'SELECT * FROM sales_summary');
  COMMIT;

  SELECT ash_db_time_sec INTO l_n
    FROM v_mon_top_sql_24h WHERE sql_id = 'testash00001';
  pkg_mon_test.eq('top SQL view sums sampled database time', l_n, 420);

  ------------------------------------------------------ plan instability view
  INSERT INTO mon_sql_slow (source, sql_id, plan_hash, elapsed_sec, sql_text)
  VALUES ('ASH', 'testplan0001', 111, 2,  'SELECT * FROM t WHERE c = :1');
  INSERT INTO mon_sql_slow (source, sql_id, plan_hash, elapsed_sec, sql_text)
  VALUES ('ASH', 'testplan0001', 222, 60, 'SELECT * FROM t WHERE c = :1');
  COMMIT;

  SELECT plans_seen INTO l_n FROM v_mon_plan_instability WHERE sql_id = 'testplan0001';
  pkg_mon_test.eq('plan instability view counts distinct plans', l_n, 2);

  SELECT spread_factor INTO l_n FROM v_mon_plan_instability WHERE sql_id = 'testplan0001';
  pkg_mon_test.eq('plan instability view reports the spread', l_n, 30);

  SELECT COUNT(*) INTO l_n FROM v_mon_plan_instability WHERE sql_id = 'testash00001';
  pkg_mon_test.eq('a single-plan statement is not flagged as unstable', l_n, 0);

  ------------------------------------------------------------------- cleanup
  DELETE FROM mon_sql_slow WHERE sql_id LIKE 'test%';
  DELETE FROM mon_alert    WHERE alert_key LIKE 'SQL!_%' ESCAPE '!';
  DELETE FROM mon_notify_log;
  COMMIT;
END;
/

PROMPT
PROMPT --- Optional live test
PROMPT   Lower the threshold, run something genuinely slow in a second session,
PROMPT   then collect. In session 2:
PROMPT
PROMPT     SELECT COUNT(*) FROM dual CONNECT BY LEVEL < 100000000;;
PROMPT
PROMPT   In this session, while it runs:
PROMPT
PROMPT     EXEC pkg_mon.set_cfg('SLOW_SQL_SEC','5');;
PROMPT     EXEC pkg_mon.collect_slow_sql;;
PROMPT     SELECT sql_id, elapsed_sec, username, SUBSTR(sql_text,1,60)
PROMPT       FROM mon_sql_slow WHERE source='RTSM'
PROMPT       ORDER BY captured_at DESC FETCH FIRST 5 ROWS ONLY;;
PROMPT     EXEC pkg_mon.set_cfg('SLOW_SQL_SEC','300');;
