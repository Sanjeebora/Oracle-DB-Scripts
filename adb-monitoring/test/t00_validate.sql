--------------------------------------------------------------------------------
-- t00_validate.sql   Install sanity: objects valid, config seeded, SQL parses.
--------------------------------------------------------------------------------
SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE OFF

DECLARE
  l_n NUMBER;
BEGIN
  pkg_mon_test.require_test_mode;
  pkg_mon_test.section('t00 install sanity');

  ---------------------------------------------------------------- objects valid
  SELECT COUNT(*) INTO l_n FROM user_objects WHERE status <> 'VALID';
  pkg_mon_test.eq('no invalid objects in DBMON', l_n, 0);

  SELECT COUNT(*) INTO l_n
    FROM user_objects
   WHERE object_name IN ('PKG_MON', 'PKG_MON_OCI') AND object_type = 'PACKAGE BODY';
  pkg_mon_test.eq('both package bodies present', l_n, 2);

  ---------------------------------------------------------------- tables/views
  SELECT COUNT(*) INTO l_n
    FROM user_tables
   WHERE table_name IN ('MON_CONFIG','MON_METRIC','MON_SQL_SLOW','MON_BACKUP',
                        'MON_ALERT','MON_NOTIFY_LOG','MON_JOB_LOG','MON_ACTION_LOG');
  pkg_mon_test.eq('all 8 repository tables exist', l_n, 8);

  SELECT COUNT(*) INTO l_n FROM user_views WHERE view_name LIKE 'V!_MON!_%' ESCAPE '!';
  pkg_mon_test.ok('reporting views created (>= 9)', l_n >= 9);

  ------------------------------------------------------------------ config seed
  SELECT COUNT(*) INTO l_n FROM mon_config;
  pkg_mon_test.ok('configuration seeded (>= 30 keys)', l_n >= 30);

  pkg_mon_test.eqs('default notify provider is log (no accidental paging)',
                   pkg_mon.cfg('NOTIFY_PROVIDER'), 'log');

  pkg_mon_test.eq('numeric config reads back as a number',
                  pkg_mon.cfgn('BACKUP_MAX_AGE_HOURS'), 30);

  pkg_mon_test.eq('cfgn falls back to the default for a missing key',
                  pkg_mon.cfgn('NO_SUCH_KEY_AT_ALL', 42), 42);

  ------------------------------------------------------- identity resolution
  pkg_mon_test.note('database name : ' || NVL(pkg_mon.db_name, 'unknown'));
  pkg_mon_test.note('database ocid : ' || NVL(pkg_mon.db_ocid, 'unknown (not an ADB)'));
  pkg_mon_test.note('region        : ' || NVL(pkg_mon.db_region, 'unknown'));
  pkg_mon_test.ok('identity resolution does not raise', TRUE);

  ------------------------------------------------------------------- activity
  pkg_mon_test.eqs('pack reports itself active', pkg_mon.is_active, 'Y');
END;
/

PROMPT
PROMPT --- Collector statements
BEGIN
  pkg_mon.validate_sql;
END;
/

DECLARE
  l_bad PLS_INTEGER;
BEGIN
  -- A collector whose view is missing is fine and expected on some instances.
  -- A collector that will not parse is a defect in the pack.
  pkg_mon_test.section('t00 collector syntax');
  l_bad := pkg_mon.syntax_errors;
  pkg_mon_test.eq('no collector has a syntax error', l_bad, 0);
  IF l_bad > 0 THEN
    pkg_mon_test.note('details are in MON_JOB_LOG with proc_name like validate:%');
  END IF;
END;
/
