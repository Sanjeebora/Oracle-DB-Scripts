--------------------------------------------------------------------------------
-- 01_admin_setup.sql
--
-- Run as ADMIN, once per Autonomous Database.
-- Creates the DBMON schema, grants the minimum privileges the pack needs, and
-- enables the resource principal so the backup checker can call the OCI API
-- without any stored API keys.
--
-- Set the password below before running, or pass it in:
--     sqlplus admin/<pw>@<alias> @01_admin_setup.sql "MyStr0ng#Pass2026"
--------------------------------------------------------------------------------
SET SERVEROUTPUT ON SIZE UNLIMITED
SET LINESIZE 200
SET VERIFY OFF

DEFINE dbmon_pwd = &1

PROMPT
PROMPT === Creating DBMON schema ===

DECLARE
  l_n NUMBER;
BEGIN
  SELECT COUNT(*) INTO l_n FROM dba_users WHERE username = 'DBMON';
  IF l_n = 0 THEN
    EXECUTE IMMEDIATE 'CREATE USER dbmon IDENTIFIED BY "&dbmon_pwd"';
    DBMS_OUTPUT.PUT_LINE('  User DBMON created.');
  ELSE
    DBMS_OUTPUT.PUT_LINE('  User DBMON already exists - leaving password unchanged.');
  END IF;
END;
/

-- Storage quota. On ADB the default tablespace is DATA; adjust if yours differs.
DECLARE
  l_tbs VARCHAR2(128);
BEGIN
  SELECT default_tablespace INTO l_tbs FROM dba_users WHERE username = 'DBMON';
  EXECUTE IMMEDIATE 'ALTER USER dbmon QUOTA 5G ON ' || DBMS_ASSERT.ENQUOTE_NAME(l_tbs);
  DBMS_OUTPUT.PUT_LINE('  Quota 5G granted on ' || l_tbs);
END;
/

PROMPT
PROMPT === Granting system privileges ===
GRANT CREATE SESSION           TO dbmon;
GRANT CREATE TABLE             TO dbmon;
GRANT CREATE VIEW              TO dbmon;
GRANT CREATE PROCEDURE         TO dbmon;
GRANT CREATE SEQUENCE          TO dbmon;
GRANT CREATE JOB               TO dbmon;

PROMPT
PROMPT === Granting dictionary access ===
--
-- SELECT ANY DICTIONARY is the one that matters, and it is not interchangeable
-- with SELECT_CATALOG_ROLE here.
--
-- PKG_MON is a definer's rights package, and privileges granted through a role
-- are not enabled inside definer's rights PL/SQL. With only the role, every
-- collector query succeeds when a DBA types it in SQL*Plus and fails with
-- ORA-00942 the moment the package runs it. The pack degrades quietly rather
-- than breaking, so the symptom is an empty MON_METRIC and a job log full of
-- warnings. SELECT ANY DICTIONARY is a system privilege and does apply.
--
-- The role is granted as well, purely so ad-hoc queries by the DBA work.
--
DECLARE
  PROCEDURE try (p_stmt VARCHAR2) IS
  BEGIN
    EXECUTE IMMEDIATE p_stmt;
    DBMS_OUTPUT.PUT_LINE('  OK       ' || p_stmt);
  EXCEPTION WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('  SKIPPED  ' || p_stmt || '  -- ' || SUBSTR(SQLERRM, 1, 70));
  END;
BEGIN
  try('GRANT SELECT ANY DICTIONARY TO dbmon');   -- the one the package needs
  try('GRANT SELECT_CATALOG_ROLE  TO dbmon');    -- convenience for ad-hoc queries

  -- Explicit object grants, for sites that will not allow SELECT ANY DICTIONARY.
  -- Direct grants also survive the definer's rights rule, so either approach
  -- works; what does not work is the role on its own.
  try('GRANT SELECT ON V_$PDBS                     TO dbmon');
  try('GRANT SELECT ON V_$PARAMETER                TO dbmon');
  try('GRANT SELECT ON V_$SERVICES                 TO dbmon');
  try('GRANT SELECT ON V_$SYSMETRIC                TO dbmon');
  try('GRANT SELECT ON V_$CON_SYSMETRIC            TO dbmon');
  try('GRANT SELECT ON V_$RSRC_CONSUMER_GROUP      TO dbmon');
  try('GRANT SELECT ON V_$RESOURCE_LIMIT           TO dbmon');
  try('GRANT SELECT ON V_$SESSION                  TO dbmon');
  try('GRANT SELECT ON GV_$SESSION                 TO dbmon');
  try('GRANT SELECT ON V_$SQL                      TO dbmon');
  try('GRANT SELECT ON V_$SQL_MONITOR              TO dbmon');
  try('GRANT SELECT ON GV_$SQL_MONITOR             TO dbmon');
  try('GRANT SELECT ON V_$ACTIVE_SESSION_HISTORY   TO dbmon');
END;
/

PROMPT
PROMPT === Granting package execute ===
DECLARE
  PROCEDURE try (p_stmt VARCHAR2) IS
  BEGIN
    EXECUTE IMMEDIATE p_stmt;
    DBMS_OUTPUT.PUT_LINE('  OK       ' || p_stmt);
  EXCEPTION WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('  SKIPPED  ' || p_stmt || '  -- ' || SUBSTR(SQLERRM, 1, 70));
  END;
BEGIN
  try('GRANT EXECUTE ON DBMS_CLOUD              TO dbmon');   -- backup API calls
  try('GRANT EXECUTE ON DBMS_CLOUD_NOTIFICATION TO dbmon');   -- alert delivery
  try('GRANT EXECUTE ON DBMS_SQL_MONITOR        TO dbmon');   -- SQL monitor reports
  try('GRANT EXECUTE ON CS_SESSION              TO dbmon');   -- run collectors in LOW
END;
/

PROMPT
PROMPT === Enabling resource principal ===
DECLARE
  l_n NUMBER;
BEGIN
  BEGIN
    EXECUTE IMMEDIATE 'BEGIN DBMS_CLOUD_ADMIN.ENABLE_RESOURCE_PRINCIPAL(); END;';
    DBMS_OUTPUT.PUT_LINE('  Resource principal enabled for ADMIN.');
  EXCEPTION WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('  ADMIN enable skipped: ' || SUBSTR(SQLERRM, 1, 100));
  END;

  BEGIN
    EXECUTE IMMEDIATE
      q'[BEGIN DBMS_CLOUD_ADMIN.ENABLE_RESOURCE_PRINCIPAL(username => 'DBMON'); END;]';
    DBMS_OUTPUT.PUT_LINE('  Resource principal granted to DBMON.');
  EXCEPTION WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('  DBMON enable skipped: ' || SUBSTR(SQLERRM, 1, 100));
    DBMS_OUTPUT.PUT_LINE('  -> Backup monitoring will not work until this succeeds.');
    DBMS_OUTPUT.PUT_LINE('  -> Check the dynamic group and IAM policy first (see README).');
  END;

  BEGIN
    EXECUTE IMMEDIATE
      q'[SELECT COUNT(*) FROM dba_credentials WHERE credential_name = 'OCI$RESOURCE_PRINCIPAL']'
      INTO l_n;
    DBMS_OUTPUT.PUT_LINE('  OCI$RESOURCE_PRINCIPAL present: ' ||
                         CASE WHEN l_n > 0 THEN 'YES' ELSE 'NO' END);
  EXCEPTION WHEN OTHERS THEN NULL;
  END;
END;
/

PROMPT
PROMPT === Done. Now connect as DBMON and run deploy.sql ===
SET VERIFY ON
