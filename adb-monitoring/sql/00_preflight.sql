--------------------------------------------------------------------------------
-- 00_preflight.sql
--
-- Run as ADMIN, BEFORE installing anything.
-- Reports which dictionary views and packages this Autonomous Database exposes,
-- so you know up front what the monitoring pack can and cannot collect here.
--
-- Nothing is created or modified by this script.
--
-- Usage:  sqlplus admin/<pw>@<tns_alias> @00_preflight.sql
--------------------------------------------------------------------------------
SET SERVEROUTPUT ON SIZE UNLIMITED
SET LINESIZE 200
SET FEEDBACK OFF
SET DEFINE OFF

PROMPT
PROMPT ================================================================
PROMPT  ADB monitoring pack - preflight probe
PROMPT ================================================================
PROMPT

-- ---------------------------------------------------------------- identity ---
PROMPT --- Database identity
DECLARE
  l_json   CLOB;
  l_banner VARCHAR2(400);
BEGIN
  BEGIN
    EXECUTE IMMEDIATE 'SELECT cloud_identity FROM v$pdbs WHERE ROWNUM = 1' INTO l_json;
    DBMS_OUTPUT.PUT_LINE('  DATABASE_NAME    : ' || JSON_VALUE(l_json, '$.DATABASE_NAME'));
    DBMS_OUTPUT.PUT_LINE('  DATABASE_OCID    : ' || JSON_VALUE(l_json, '$.DATABASE_OCID'));
    DBMS_OUTPUT.PUT_LINE('  COMPARTMENT_OCID : ' || JSON_VALUE(l_json, '$.COMPARTMENT_OCID'));
    DBMS_OUTPUT.PUT_LINE('  REGION           : ' || JSON_VALUE(l_json, '$.REGION'));
    DBMS_OUTPUT.PUT_LINE('  SERVICE          : ' || JSON_VALUE(l_json, '$.SERVICE'));
    DBMS_OUTPUT.PUT_LINE('  INFRASTRUCTURE   : ' || JSON_VALUE(l_json, '$.INFRASTRUCTURE'));
    DBMS_OUTPUT.PUT_LINE('  COMPUTE_MODEL    : ' || JSON_VALUE(l_json, '$.COMPUTE_MODEL'));
    DBMS_OUTPUT.PUT_LINE('  COMPUTE_COUNT    : ' || JSON_VALUE(l_json, '$.COMPUTE_COUNT'));
    DBMS_OUTPUT.PUT_LINE('  AUTOSCALING      : ' || JSON_VALUE(l_json, '$.COMPUTE_AUTOSCALING'));
  EXCEPTION WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('  V$PDBS.CLOUD_IDENTITY unavailable: ' || SQLERRM);
    DBMS_OUTPUT.PUT_LINE('  -> Not an Autonomous Database, or no privilege on V$PDBS.');
    DBMS_OUTPUT.PUT_LINE('  -> Set DB_OCID / REGION / DB_NAME manually in MON_CONFIG.');
  END;
  BEGIN
    SELECT MIN(banner) INTO l_banner FROM v$version WHERE banner LIKE 'Oracle%';
    DBMS_OUTPUT.PUT_LINE('  Banner           : ' || l_banner);
  EXCEPTION WHEN OTHERS THEN NULL;
  END;
END;
/

-- ------------------------------------------------------------------ views ---
PROMPT
PROMPT --- Dictionary views
DECLARE
  TYPE t_list IS TABLE OF VARCHAR2(60);
  l_objs t_list := t_list(
    'V$PDBS','V$VERSION','V$PARAMETER','V$SERVICES',
    'V$SYSMETRIC','V$CON_SYSMETRIC','V$SYSMETRIC_HISTORY',
    'V$RSRC_CONSUMER_GROUP','V$RSRCMGRMETRIC','V$RSRC_SESSION_INFO',
    'V$RESOURCE_LIMIT','V$SESSION','GV$SESSION',
    'V$SQL','V$SQLSTATS','V$SQL_MONITOR','GV$SQL_MONITOR',
    'V$ACTIVE_SESSION_HISTORY','GV$ACTIVE_SESSION_HISTORY',
    'DBA_HIST_SNAPSHOT','DBA_HIST_SQLSTAT','DBA_HIST_SYSMETRIC_SUMMARY',
    'DBA_TABLESPACE_USAGE_METRICS','DBA_SEGMENTS','DBA_USERS',
    'DBA_SCHEDULER_JOBS','DBA_SCHEDULER_JOB_RUN_DETAILS',
    'DBA_AUTO_INDEX_EXECUTIONS','DBA_DATAPUMP_JOBS',
    'V$RMAN_STATUS','V$RMAN_BACKUP_JOB_DETAILS','DBA_RMAN_BACKUP_JOB_DETAILS');
  l_n NUMBER;
BEGIN
  FOR i IN 1 .. l_objs.COUNT LOOP
    BEGIN
      EXECUTE IMMEDIATE
        'SELECT COUNT(*) FROM (SELECT 1 FROM ' || l_objs(i) || ' WHERE ROWNUM < 2)' INTO l_n;
      DBMS_OUTPUT.PUT_LINE('  ' || RPAD(l_objs(i), 34) || 'OK' ||
                           CASE WHEN l_n = 0 THEN '   (accessible but empty)' END);
    EXCEPTION WHEN OTHERS THEN
      DBMS_OUTPUT.PUT_LINE('  ' || RPAD(l_objs(i), 34) || 'UNAVAILABLE  ' ||
                           SUBSTR(SQLERRM, 1, 60));
    END;
  END LOOP;
END;
/

-- --------------------------------------------------------------- packages ---
PROMPT
PROMPT --- Packages
DECLARE
  TYPE t_list IS TABLE OF VARCHAR2(60);
  l_pkgs t_list := t_list(
    'DBMS_CLOUD','DBMS_CLOUD_ADMIN','DBMS_CLOUD_NOTIFICATION','DBMS_CLOUD_TYPES',
    'DBMS_CLOUD_OCI_DB_DATABASE','CS_RESOURCE_MANAGER','CS_SESSION',
    'DBMS_SCHEDULER','DBMS_SQL_MONITOR','DBMS_WORKLOAD_REPOSITORY','DBMS_AUTO_INDEX');
  l_n NUMBER;
BEGIN
  FOR i IN 1 .. l_pkgs.COUNT LOOP
    SELECT COUNT(*) INTO l_n
      FROM all_objects
     WHERE object_name = l_pkgs(i) AND object_type IN ('PACKAGE','PACKAGE BODY','SYNONYM');
    DBMS_OUTPUT.PUT_LINE('  ' || RPAD(l_pkgs(i), 34) ||
                         CASE WHEN l_n > 0 THEN 'VISIBLE' ELSE 'NOT VISIBLE / NOT GRANTED' END);
  END LOOP;
END;
/

-- ------------------------------------------------------- resource principal ---
PROMPT
PROMPT --- Resource principal
DECLARE
  l_n NUMBER;
BEGIN
  BEGIN
    EXECUTE IMMEDIATE
      q'[SELECT COUNT(*) FROM dba_credentials
          WHERE credential_name = 'OCI$RESOURCE_PRINCIPAL']' INTO l_n;
    IF l_n > 0 THEN
      DBMS_OUTPUT.PUT_LINE('  OCI$RESOURCE_PRINCIPAL   ENABLED');
    ELSE
      DBMS_OUTPUT.PUT_LINE('  OCI$RESOURCE_PRINCIPAL   NOT ENABLED');
      DBMS_OUTPUT.PUT_LINE('  -> run: EXEC DBMS_CLOUD_ADMIN.ENABLE_RESOURCE_PRINCIPAL();');
    END IF;
  EXCEPTION WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('  DBA_CREDENTIALS not readable: ' || SUBSTR(SQLERRM, 1, 80));
  END;
END;
/

-- ------------------------------------------------------------- interpretation ---
PROMPT
PROMPT --- How to read this
PROMPT   V$RMAN_* / DBA_RMAN_BACKUP_JOB_DETAILS are expected to be UNAVAILABLE or
PROMPT   empty on Autonomous Database Serverless. Oracle runs automatic backups in
PROMPT   the control plane, so backup status is read from the OCI Database API by
PROMPT   PKG_MON_OCI instead. That is by design, not a misconfiguration.
PROMPT
PROMPT   Any view reported UNAVAILABLE simply disables its collector at runtime.
PROMPT   The pack degrades gracefully; it never fails to install because of one.
PROMPT
PROMPT ================================================================
PROMPT  Preflight complete
PROMPT ================================================================
SET FEEDBACK ON
