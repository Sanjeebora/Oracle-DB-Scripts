--------------------------------------------------------------------------------
-- t_framework.sql
--
-- Minimal assertion helper for the test scripts. Run as DBMON.
-- Install once; the test scripts depend on it.
--
-- The tests write fixture rows into the monitoring repository and delete rows in
-- the current evaluation window. That is destructive, so every test refuses to
-- run unless MON_CONFIG.TEST_MODE is set to Y. Set it deliberately, on a test or
-- clone database, and unset it when you are finished.
--------------------------------------------------------------------------------
SET DEFINE OFF

CREATE OR REPLACE PACKAGE pkg_mon_test AUTHID DEFINER AS
  PROCEDURE reset;
  PROCEDURE require_test_mode;
  PROCEDURE section (p_title  VARCHAR2);
  PROCEDURE ok      (p_name   VARCHAR2, p_cond     BOOLEAN);
  PROCEDURE eq      (p_name   VARCHAR2, p_actual   NUMBER,   p_expected NUMBER);
  PROCEDURE eqs     (p_name   VARCHAR2, p_actual   VARCHAR2, p_expected VARCHAR2);
  PROCEDURE note    (p_text   VARCHAR2);
  PROCEDURE summary;
  FUNCTION  failures RETURN PLS_INTEGER;
END pkg_mon_test;
/
SHOW ERRORS

CREATE OR REPLACE PACKAGE BODY pkg_mon_test AS

  g_pass PLS_INTEGER := 0;
  g_fail PLS_INTEGER := 0;

  PROCEDURE reset IS
  BEGIN
    g_pass := 0;
    g_fail := 0;
  END reset;

  PROCEDURE require_test_mode IS
  BEGIN
    IF UPPER(NVL(pkg_mon.cfg('TEST_MODE'), 'N')) <> 'Y' THEN
      RAISE_APPLICATION_ERROR(-20900,
        'These tests modify the monitoring repository. Enable them with ' ||
        'EXEC pkg_mon.set_cfg(''TEST_MODE'',''Y'') and only on a non-production database.');
    END IF;
  END require_test_mode;

  PROCEDURE section (p_title VARCHAR2) IS
  BEGIN
    DBMS_OUTPUT.PUT_LINE(' ');
    DBMS_OUTPUT.PUT_LINE('--- ' || p_title || ' ' || RPAD('-', GREATEST(66 - LENGTH(p_title), 3), '-'));
  END section;

  PROCEDURE ok (p_name VARCHAR2, p_cond BOOLEAN) IS
  BEGIN
    IF NVL(p_cond, FALSE) THEN
      g_pass := g_pass + 1;
      DBMS_OUTPUT.PUT_LINE('  PASS  ' || p_name);
    ELSE
      g_fail := g_fail + 1;
      DBMS_OUTPUT.PUT_LINE('  FAIL  ' || p_name);
    END IF;
  END ok;

  PROCEDURE eq (p_name VARCHAR2, p_actual NUMBER, p_expected NUMBER) IS
  BEGIN
    IF NVL(p_actual, -999999) = NVL(p_expected, -999999) THEN
      g_pass := g_pass + 1;
      DBMS_OUTPUT.PUT_LINE('  PASS  ' || p_name);
    ELSE
      g_fail := g_fail + 1;
      DBMS_OUTPUT.PUT_LINE('  FAIL  ' || p_name ||
                           '   expected ' || NVL(TO_CHAR(p_expected), 'NULL') ||
                           ', got '       || NVL(TO_CHAR(p_actual),   'NULL'));
    END IF;
  END eq;

  PROCEDURE eqs (p_name VARCHAR2, p_actual VARCHAR2, p_expected VARCHAR2) IS
  BEGIN
    IF NVL(p_actual, '~null~') = NVL(p_expected, '~null~') THEN
      g_pass := g_pass + 1;
      DBMS_OUTPUT.PUT_LINE('  PASS  ' || p_name);
    ELSE
      g_fail := g_fail + 1;
      DBMS_OUTPUT.PUT_LINE('  FAIL  ' || p_name ||
                           '   expected [' || NVL(p_expected, 'NULL') ||
                           '], got ['      || NVL(p_actual,   'NULL') || ']');
    END IF;
  END eqs;

  PROCEDURE note (p_text VARCHAR2) IS
  BEGIN
    DBMS_OUTPUT.PUT_LINE('  note  ' || p_text);
  END note;

  FUNCTION failures RETURN PLS_INTEGER IS
  BEGIN
    RETURN g_fail;
  END failures;

  PROCEDURE summary IS
  BEGIN
    DBMS_OUTPUT.PUT_LINE(' ');
    DBMS_OUTPUT.PUT_LINE(RPAD('=', 72, '='));
    DBMS_OUTPUT.PUT_LINE('  RESULT: ' || g_pass || ' passed, ' || g_fail || ' failed');
    DBMS_OUTPUT.PUT_LINE(RPAD('=', 72, '='));
    IF g_fail > 0 THEN
      RAISE_APPLICATION_ERROR(-20901, g_fail || ' test(s) failed');
    END IF;
  END summary;

END pkg_mon_test;
/
SHOW ERRORS
