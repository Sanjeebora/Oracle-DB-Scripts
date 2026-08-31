--------------------------------------------------------------------------------
-- t06_clone_guard.sql   The pack must go silent on a clone.
--
-- Why this matters: clone a production ADB for a test refresh and the clone
-- inherits DBMON, the jobs, and the notification configuration. Without a guard
-- it starts paging the production on-call about a database nobody is using, and
-- the on-call learns to ignore the channel.
--------------------------------------------------------------------------------
SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE OFF

DECLARE
  l_n         NUMBER;
  l_saved     VARCHAR2(4000) := pkg_mon.cfg('EXPECTED_DB_OCID');
  l_saved_db  VARCHAR2(4000) := pkg_mon.cfg('DB_OCID');
  l_enabled   VARCHAR2(10)   := pkg_mon.cfg('ENABLED');
  l_live      VARCHAR2(255)  := pkg_mon.db_ocid;
BEGIN
  pkg_mon_test.require_test_mode;
  pkg_mon_test.section('t06 clone guard and kill switch');

  DELETE FROM mon_job_log WHERE proc_name IN ('collect_resource', 'collect_slow_sql');
  COMMIT;

  --------------------------------------------------------- guard matches: active
  -- On a non-ADB test database there is no OCID to read, so supply one. The
  -- guard logic under test is identical either way.
  IF l_live IS NULL THEN
    pkg_mon_test.note('no OCID available here, simulating one for the guard test');
    pkg_mon.set_cfg('DB_OCID', 'ocid1.autonomousdatabase.oc1..simulated');
    pkg_mon.reset_identity;
    l_live := pkg_mon.db_ocid;
  END IF;

  pkg_mon_test.ok('an OCID is available for the guard', l_live IS NOT NULL);
  pkg_mon.set_cfg('EXPECTED_DB_OCID', l_live);
  pkg_mon_test.eqs('matching OCID means active', pkg_mon.is_active, 'Y');
  pkg_mon_test.ok('no inactive reason when active', pkg_mon.inactive_reason IS NULL);

  ------------------------------------------------------ guard mismatch: silent
  pkg_mon.set_cfg('EXPECTED_DB_OCID', 'ocid1.autonomousdatabase.oc1..adifferentdb');

  pkg_mon_test.eqs('mismatched OCID means inactive', pkg_mon.is_active, 'N');
  pkg_mon_test.ok('the reason says clone',
                  INSTR(LOWER(pkg_mon.inactive_reason), 'clone') > 0);

  -- The collectors must not merely skip alerting, they must not run at all.
  pkg_mon.collect_resource;

  SELECT COUNT(*) INTO l_n
    FROM mon_job_log
   WHERE proc_name = 'collect_resource' AND status = 'SKIP'
     AND run_at > SYSTIMESTAMP - INTERVAL '2' MINUTE;
  pkg_mon_test.eq('collect_resource records a SKIP on a clone', l_n, 1);

  SELECT COUNT(*) INTO l_n
    FROM mon_job_log
   WHERE proc_name = 'collect_resource' AND status = 'OK'
     AND run_at > SYSTIMESTAMP - INTERVAL '2' MINUTE;
  pkg_mon_test.eq('and does no collection work', l_n, 0);

  pkg_mon.collect_slow_sql;
  SELECT COUNT(*) INTO l_n
    FROM mon_job_log
   WHERE proc_name = 'collect_slow_sql' AND status = 'SKIP'
     AND run_at > SYSTIMESTAMP - INTERVAL '2' MINUTE;
  pkg_mon_test.eq('collect_slow_sql also skips', l_n, 1);

  ------------------------------------------------------------- global kill switch
  pkg_mon.set_cfg('EXPECTED_DB_OCID', l_live);
  pkg_mon.set_cfg('ENABLED', 'N');

  pkg_mon_test.eqs('ENABLED=N stops the pack', pkg_mon.is_active, 'N');
  pkg_mon_test.ok('the reason says disabled',
                  INSTR(LOWER(pkg_mon.inactive_reason), 'disabled') > 0);

  ------------------------------------------------------------------- restore
  pkg_mon.set_cfg('ENABLED', NVL(l_enabled, 'Y'));
  pkg_mon.set_cfg('DB_OCID', l_saved_db);
  pkg_mon.set_cfg('EXPECTED_DB_OCID', l_saved);
  pkg_mon.reset_identity;

  pkg_mon_test.eqs('pack is active again after restore', pkg_mon.is_active, 'Y');
END;
/
