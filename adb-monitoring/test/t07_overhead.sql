--------------------------------------------------------------------------------
-- t07_overhead.sql   What does the monitoring itself cost?
--
-- Monitoring that costs real CPU on a busy database gets uninstalled. Measure it
-- rather than assuming. The one-minute collector should be in the tens of
-- milliseconds; if it is not, find out which collector is expensive before you
-- schedule it every minute.
--------------------------------------------------------------------------------
SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE OFF

DECLARE
  l_avg NUMBER;
  l_max NUMBER;
  l_n   NUMBER;
BEGIN
  pkg_mon_test.require_test_mode;
  pkg_mon_test.section('t07 collector overhead');

  DELETE FROM mon_job_log
   WHERE proc_name IN ('collect_resource', 'collect_slow_sql')
     AND run_at > SYSTIMESTAMP - INTERVAL '1' HOUR;
  COMMIT;

  FOR i IN 1 .. 5 LOOP
    pkg_mon.collect_resource;
  END LOOP;

  FOR i IN 1 .. 3 LOOP
    pkg_mon.collect_slow_sql;
  END LOOP;

  SELECT COUNT(*), ROUND(AVG(ms_elapsed), 1), MAX(ms_elapsed)
    INTO l_n, l_avg, l_max
    FROM mon_job_log
   WHERE proc_name = 'collect_resource'
     AND status = 'OK'
     AND run_at > SYSTIMESTAMP - INTERVAL '10' MINUTE;

  pkg_mon_test.eq('five resource collections completed', l_n, 5);
  pkg_mon_test.note('collect_resource  avg ' || l_avg || ' ms, max ' || l_max || ' ms');
  pkg_mon_test.ok('resource collection stays under 2000 ms', NVL(l_max, 0) < 2000);

  SELECT COUNT(*), ROUND(AVG(ms_elapsed), 1), MAX(ms_elapsed)
    INTO l_n, l_avg, l_max
    FROM mon_job_log
   WHERE proc_name = 'collect_slow_sql'
     AND status = 'OK'
     AND run_at > SYSTIMESTAMP - INTERVAL '10' MINUTE;

  pkg_mon_test.eq('three slow SQL collections completed', l_n, 3);
  pkg_mon_test.note('collect_slow_sql  avg ' || l_avg || ' ms, max ' || l_max || ' ms');
  pkg_mon_test.ok('slow SQL collection stays under 5000 ms', NVL(l_max, 0) < 5000);

  --------------------------------------------------------------- growth per day
  -- Rows per collection multiplied out to a daily rate, so retention settings
  -- can be sized honestly rather than guessed.
  SELECT COUNT(*) INTO l_n
    FROM mon_metric WHERE collected_at > SYSTIMESTAMP - INTERVAL '10' MINUTE;
  pkg_mon_test.note('metric rows from this run: ' || l_n ||
                    '  (about ' || ROUND(l_n / 5 * 60 * 24) || ' per day at 1/min)');

  ------------------------------------------------------------- purge behaviour
  INSERT INTO mon_metric (collected_at, metric_group, metric_name, metric_value)
  VALUES (SYSTIMESTAMP - NUMTODSINTERVAL(400, 'DAY'), 'TEST', 'ancient', 1);
  COMMIT;

  pkg_mon.purge;

  SELECT COUNT(*) INTO l_n FROM mon_metric WHERE metric_name = 'ancient';
  pkg_mon_test.eq('purge removes rows past the retention window', l_n, 0);

  SELECT COUNT(*) INTO l_n
    FROM mon_metric WHERE collected_at > SYSTIMESTAMP - INTERVAL '10' MINUTE;
  pkg_mon_test.ok('purge leaves recent rows alone', l_n > 0);
END;
/

PROMPT
PROMPT --- Per-collector health
COLUMN proc_name  FORMAT A32
COLUMN last_error FORMAT A60
SELECT proc_name, runs_24h, ok_runs, warn_runs, error_runs, skipped_runs,
       avg_ms, max_ms
FROM   v_mon_health
ORDER  BY proc_name;
