--------------------------------------------------------------------------------
-- run_all_tests.sql
--
-- Runs the whole suite as DBMON and exits non-zero if anything failed, so it can
-- be wired into a pipeline:
--
--     sqlplus -L -S dbmon/<pw>@<alias> @test/run_all_tests.sql
--
-- The tests write fixtures into the monitoring repository and delete rows in the
-- current evaluation window, so they refuse to run unless TEST_MODE is Y.
-- Run them on a test database or a clone, never on the production instance you
-- are monitoring.
--------------------------------------------------------------------------------
SET SERVEROUTPUT ON SIZE UNLIMITED
SET LINESIZE 200
SET FEEDBACK OFF
SET DEFINE OFF
WHENEVER SQLERROR EXIT FAILURE

PROMPT
PROMPT ================================================================
PROMPT  ADB monitoring pack - test suite
PROMPT ================================================================

DECLARE
  l_mode VARCHAR2(10) := UPPER(NVL(pkg_mon.cfg('TEST_MODE'), 'N'));
BEGIN
  IF l_mode <> 'Y' THEN
    DBMS_OUTPUT.PUT_LINE(' ');
    DBMS_OUTPUT.PUT_LINE('  TEST_MODE is not enabled, so nothing will run.');
    DBMS_OUTPUT.PUT_LINE(' ');
    DBMS_OUTPUT.PUT_LINE('  These tests modify the monitoring repository. Enable them only');
    DBMS_OUTPUT.PUT_LINE('  on a test database or a clone:');
    DBMS_OUTPUT.PUT_LINE(' ');
    DBMS_OUTPUT.PUT_LINE('      EXEC pkg_mon.set_cfg(''TEST_MODE'',''Y'');');
    DBMS_OUTPUT.PUT_LINE(' ');
    RAISE_APPLICATION_ERROR(-20902, 'TEST_MODE not enabled');
  END IF;
  pkg_mon_test.reset;
END;
/

@@t00_validate.sql
@@t01_notify.sql
@@t02_alerts.sql
@@t03_resource.sql
@@t04_slow_sql.sql
@@t05_backup.sql
@@t06_clone_guard.sql
@@t07_overhead.sql

BEGIN
  pkg_mon_test.summary;
END;
/

@@t99_cleanup.sql

PROMPT
PROMPT All tests passed.
SET FEEDBACK ON
