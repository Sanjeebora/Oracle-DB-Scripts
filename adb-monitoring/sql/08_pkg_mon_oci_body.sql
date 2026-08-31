--------------------------------------------------------------------------------
-- 08_pkg_mon_oci_body.sql
--
-- Run as DBMON.
--------------------------------------------------------------------------------
SET DEFINE OFF

CREATE OR REPLACE PACKAGE BODY pkg_mon_oci AS

  c_cred CONSTANT VARCHAR2(64) := 'OCI$RESOURCE_PRINCIPAL';

  --=============================================================== utilities ==--

  PROCEDURE log_run (p_proc VARCHAR2, p_status VARCHAR2,
                     p_ms NUMBER DEFAULT NULL, p_err VARCHAR2 DEFAULT NULL) IS
    PRAGMA AUTONOMOUS_TRANSACTION;
  BEGIN
    INSERT INTO mon_job_log (proc_name, status, ms_elapsed, err)
    VALUES (SUBSTR(p_proc, 1, 60), p_status, p_ms, SUBSTR(p_err, 1, 4000));
    COMMIT;
  EXCEPTION WHEN OTHERS THEN
    ROLLBACK;
  END log_run;

  FUNCTION iso_ts (p_txt IN VARCHAR2) RETURN TIMESTAMP WITH TIME ZONE IS
    l_clean VARCHAR2(64);
  BEGIN
    IF p_txt IS NULL THEN
      RETURN NULL;
    END IF;
    l_clean := REPLACE(REPLACE(p_txt, 'T', ' '), 'Z', '');
    BEGIN
      RETURN FROM_TZ(TO_TIMESTAMP(l_clean, 'YYYY-MM-DD HH24:MI:SS.FF'), 'UTC');
    EXCEPTION WHEN OTHERS THEN
      RETURN FROM_TZ(TO_TIMESTAMP(l_clean, 'YYYY-MM-DD HH24:MI:SS'), 'UTC');
    END;
  EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
  END iso_ts;

  FUNCTION endpoint_base RETURN VARCHAR2 IS
  BEGIN
    RETURN 'https://database.' || pkg_mon.db_region || '.' ||
           pkg_mon.cfg('SERVICE_DOMAIN', 'oraclecloud.com');
  END endpoint_base;

  FUNCTION as_array (p_json IN CLOB) RETURN CLOB IS
  BEGIN
    IF p_json IS NULL THEN
      RETURN NULL;
    END IF;
    IF SUBSTR(LTRIM(p_json), 1, 1) = '[' THEN
      RETURN p_json;
    END IF;
    RETURN NVL(JSON_QUERY(p_json, '$.items'), p_json);
  END as_array;

  --=============================================================== retrieval ==--

  FUNCTION send_get (p_uri IN VARCHAR2, p_tag IN VARCHAR2) RETURN CLOB IS
    l_resp DBMS_CLOUD_TYPES.RESP;
    l_code NUMBER;
    l_text CLOB;
  BEGIN
    l_resp := DBMS_CLOUD.SEND_REQUEST(credential_name => c_cred,
                                      uri             => p_uri,
                                      method          => DBMS_CLOUD.METHOD_GET);
    l_code := DBMS_CLOUD.GET_RESPONSE_STATUS_CODE(l_resp);
    l_text := DBMS_CLOUD.GET_RESPONSE_TEXT(l_resp);

    IF l_code <> 200 THEN
      -- Blind monitoring is worse than no monitoring, so this is CRITICAL.
      pkg_mon.raise_alert('BKP_API', 'CRITICAL',
        'Cannot read backup status from OCI (HTTP ' || l_code || ')',
        'Backup monitoring is blind until this is fixed.' || CHR(10) ||
        'Endpoint : ' || p_uri || CHR(10) ||
        'Response : ' || SUBSTR(l_text, 1, 1200) || CHR(10) || CHR(10) ||
        'Usual causes, in order of likelihood:' || CHR(10) ||
        '  1. The dynamic group does not match this database.' || CHR(10) ||
        '  2. No policy granting "read autonomous-database-family".' || CHR(10) ||
        '  3. Resource principal not enabled for DBMON.' || CHR(10) ||
        '  4. Wrong SERVICE_DOMAIN for this realm.');
      log_run('oci:' || p_tag, 'ERROR', NULL, 'HTTP ' || l_code);
      RETURN NULL;
    END IF;

    pkg_mon.clear_alert('BKP_API');
    RETURN l_text;
  EXCEPTION WHEN OTHERS THEN
    log_run('oci:' || p_tag, 'ERROR', NULL, SQLERRM);
    pkg_mon.raise_alert('BKP_API', 'CRITICAL',
      'Backup status call failed',
      'Endpoint : ' || p_uri || CHR(10) || 'Error : ' || SQLERRM);
    RETURN NULL;
  END send_get;

  FUNCTION fetch_backups_json RETURN CLOB IS
    l_uri VARCHAR2(2000);
  BEGIN
    IF pkg_mon.db_ocid IS NULL THEN
      log_run('oci:fetch_backups', 'SKIP', NULL, 'database OCID unknown');
      RETURN NULL;
    END IF;

    l_uri := endpoint_base ||
             '/20160918/autonomousDatabaseBackups' ||
             '?autonomousDatabaseId=' || pkg_mon.db_ocid ||
             '&sortBy=TIMECREATED&sortOrder=DESC' ||
             '&limit=' || TO_CHAR(NVL(pkg_mon.cfgn('BACKUP_API_LIMIT', 25), 25));

    RETURN send_get(l_uri, 'fetch_backups');
  END fetch_backups_json;

  FUNCTION fetch_database_json RETURN CLOB IS
    l_uri VARCHAR2(2000);
  BEGIN
    IF pkg_mon.db_ocid IS NULL THEN
      RETURN NULL;
    END IF;
    l_uri := endpoint_base || '/20160918/autonomousDatabases/' || pkg_mon.db_ocid;
    RETURN send_get(l_uri, 'fetch_database');
  END fetch_database_json;

  --================================================================= loading ==--

  PROCEDURE load_backups (p_json IN CLOB) IS
    l_arr  CLOB := as_array(p_json);
    l_rows NUMBER := 0;
  BEGIN
    IF l_arr IS NULL THEN
      RETURN;
    END IF;

    MERGE INTO mon_backup t
    USING (
      SELECT jt.backup_id,
             jt.display_name,
             jt.backup_type,
             jt.is_automatic,
             jt.lifecycle_state,
             jt.lifecycle_details,
             iso_ts(jt.time_started) AS time_started,
             iso_ts(jt.time_ended)   AS time_ended,
             jt.is_restorable,
             jt.retention_days
        FROM JSON_TABLE(l_arr, '$[*]'
               COLUMNS (backup_id         VARCHAR2(255)  PATH '$.id',
                        display_name      VARCHAR2(255)  PATH '$.displayName',
                        backup_type       VARCHAR2(30)   PATH '$.type',
                        is_automatic      VARCHAR2(10)   PATH '$.isAutomatic',
                        lifecycle_state   VARCHAR2(30)   PATH '$.lifecycleState',
                        lifecycle_details VARCHAR2(2000) PATH '$.lifecycleDetails',
                        time_started      VARCHAR2(64)   PATH '$.timeStarted',
                        time_ended        VARCHAR2(64)   PATH '$.timeEnded',
                        is_restorable     VARCHAR2(10)   PATH '$.isRestorable',
                        retention_days    NUMBER         PATH '$.retentionPeriodInDays')) jt
       WHERE jt.backup_id IS NOT NULL
    ) s
    ON (t.backup_id = s.backup_id)
    WHEN MATCHED THEN
      UPDATE SET t.display_name      = s.display_name,
                 t.lifecycle_state   = s.lifecycle_state,
                 t.lifecycle_details = s.lifecycle_details,
                 t.time_ended        = s.time_ended,
                 t.is_restorable     = s.is_restorable,
                 t.retention_days    = s.retention_days,
                 t.last_seen_at      = SYSTIMESTAMP
    WHEN NOT MATCHED THEN
      INSERT (backup_id, display_name, backup_type, is_automatic, lifecycle_state,
              lifecycle_details, time_started, time_ended, is_restorable, retention_days)
      VALUES (s.backup_id, s.display_name, s.backup_type, s.is_automatic, s.lifecycle_state,
              s.lifecycle_details, s.time_started, s.time_ended, s.is_restorable,
              s.retention_days);

    l_rows := SQL%ROWCOUNT;
    COMMIT;
    log_run('oci:load_backups', 'OK', NULL, l_rows || ' rows merged');
  EXCEPTION WHEN OTHERS THEN
    ROLLBACK;
    log_run('oci:load_backups', 'ERROR', NULL, SQLERRM);
    RAISE;
  END load_backups;

  PROCEDURE load_db_details (p_json IN CLOB) IS
    l_state     VARCHAR2(64);
    l_retention NUMBER;
    l_min_ret   NUMBER := NVL(pkg_mon.cfgn('BACKUP_MIN_RETENTION_DAYS', 30), 30);
  BEGIN
    IF p_json IS NULL THEN
      RETURN;
    END IF;

    l_state     := JSON_VALUE(p_json, '$.lifecycleState');
    l_retention := JSON_VALUE(p_json, '$.backupRetentionPeriodInDays' RETURNING NUMBER);

    IF l_retention IS NOT NULL THEN
      INSERT INTO mon_metric (metric_group, metric_name, dim1, metric_value, metric_unit)
      VALUES ('BACKUP', 'retention_days', NULL, l_retention, 'days');
      COMMIT;

      IF l_retention < l_min_ret THEN
        pkg_mon.raise_alert('BKP_RETENTION', 'WARNING',
          'Backup retention is ' || l_retention || ' days',
          'Policy requires at least ' || l_min_ret || ' days. Retention was either' ||
          CHR(10) || 'lowered deliberately or reset by a clone or a restore.');
      ELSE
        pkg_mon.clear_alert('BKP_RETENTION');
      END IF;
    END IF;

    IF l_state IS NOT NULL AND l_state NOT IN ('AVAILABLE', 'AVAILABLE_NEEDS_ATTENTION') THEN
      pkg_mon.raise_alert('DB_LIFECYCLE', 'CRITICAL',
        'Database lifecycle state is ' || l_state,
        'The OCI control plane does not report this database as AVAILABLE.' || CHR(10) ||
        'If you are reading this from an alert, the database was still up when' || CHR(10) ||
        'the check ran. Confirm with the OCI console.');
    ELSIF l_state = 'AVAILABLE_NEEDS_ATTENTION' THEN
      pkg_mon.raise_alert('DB_LIFECYCLE', 'WARNING',
        'Database state AVAILABLE_NEEDS_ATTENTION',
        'The service flagged something that needs a look in the console.');
    ELSE
      pkg_mon.clear_alert('DB_LIFECYCLE');
    END IF;

  EXCEPTION WHEN OTHERS THEN
    ROLLBACK;
    log_run('oci:load_db_details', 'ERROR', NULL, SQLERRM);
  END load_db_details;

  --============================================================== evaluation ==--

  PROCEDURE evaluate_backups IS
    l_last    TIMESTAMP WITH TIME ZONE;
    l_maxage  NUMBER := NVL(pkg_mon.cfgn('BACKUP_MAX_AGE_HOURS', 30), 30);
    l_known   NUMBER;
    l_age_hrs NUMBER;
  BEGIN
    SELECT COUNT(*) INTO l_known FROM mon_backup;

    ------------------------------------------------- explicit failures, 24 hours
    FOR r IN (SELECT backup_id, display_name, backup_type, is_automatic,
                     lifecycle_details, NVL(time_ended, time_started) AS ts
                FROM mon_backup
               WHERE lifecycle_state = 'FAILED'
                 AND NVL(time_ended, time_started) > SYSTIMESTAMP - INTERVAL '1' DAY) LOOP
      pkg_mon.raise_alert('BKP_FAILED_' || r.backup_id, 'CRITICAL',
        'Backup FAILED: ' || NVL(r.display_name, r.backup_id),
        'Type      : ' || NVL(r.backup_type, '?') ||
        CASE WHEN LOWER(NVL(r.is_automatic, 'false')) = 'true'
             THEN ' (automatic)' ELSE ' (manual)' END || CHR(10) ||
        'Finished  : ' || NVL(TO_CHAR(r.ts, 'YYYY-MM-DD HH24:MI TZR'), 'never') || CHR(10) ||
        'Reported  : ' || NVL(r.lifecycle_details, 'no detail supplied by the service') ||
        CHR(10) || CHR(10) ||
        'A failed automatic backup does not retry on your schedule. Take a manual' || CHR(10) ||
        'backup now if this database is close to the edge of its retention window.');
    END LOOP;

    ------------------------------------------------------ silent absence of one
    -- This is the check that matters most. A backup that never starts emits no
    -- failure event at all, so nothing else in the stack will tell you.
    SELECT MAX(NVL(time_ended, time_started))
      INTO l_last
      FROM mon_backup
     WHERE lifecycle_state = 'ACTIVE';

    IF l_known = 0 THEN
      pkg_mon.raise_alert('BKP_NONE', 'CRITICAL',
        'No backups are visible for this database',
        'The OCI API returned no backup records at all. Either automatic backups' ||
        CHR(10) || 'are disabled, or this database was created too recently to have one.');
    ELSE
      pkg_mon.clear_alert('BKP_NONE');
    END IF;

    IF l_known > 0 THEN
      IF l_last IS NULL
         OR l_last < SYSTIMESTAMP - NUMTODSINTERVAL(l_maxage, 'HOUR') THEN
        l_age_hrs := ROUND((CAST(SYSTIMESTAMP AS DATE) - CAST(l_last AS DATE)) * 24, 1);
        pkg_mon.raise_alert('BKP_STALE', 'CRITICAL',
          'No successful backup in the last ' || l_maxage || ' hours',
          'Most recent successful backup: ' ||
          NVL(TO_CHAR(l_last, 'YYYY-MM-DD HH24:MI TZR'), 'none on record') ||
          CASE WHEN l_age_hrs IS NOT NULL
               THEN '  (' || l_age_hrs || ' hours ago)' END || CHR(10) || CHR(10) ||
          'Backups that never start produce no failure event. Check that automatic' ||
          CHR(10) || 'backups are still enabled, and confirm the retention window.');
      ELSE
        pkg_mon.clear_alert('BKP_STALE');
      END IF;
    END IF;

    ------------------------------------------------------- restorability check
    FOR r IN (SELECT backup_id, display_name
                FROM mon_backup
               WHERE lifecycle_state = 'ACTIVE'
                 AND LOWER(NVL(is_restorable, 'true')) = 'false'
                 AND NVL(time_ended, time_started) > SYSTIMESTAMP - INTERVAL '7' DAY) LOOP
      pkg_mon.raise_alert('BKP_UNRESTORABLE_' || r.backup_id, 'WARNING',
        'Backup exists but is not restorable: ' || NVL(r.display_name, r.backup_id),
        'The service reports isRestorable = false. A backup you cannot restore' || CHR(10) ||
        'from is not a backup. Verify your recovery window covers this gap.');
    END LOOP;

  EXCEPTION WHEN OTHERS THEN
    log_run('oci:evaluate_backups', 'ERROR', NULL, SQLERRM);
  END evaluate_backups;

  --=========================================================== orchestration ==--

  PROCEDURE check_backups IS
    l_t0     NUMBER := DBMS_UTILITY.GET_TIME;
    l_reason VARCHAR2(400) := pkg_mon.inactive_reason;
    l_json   CLOB;
  BEGIN
    IF l_reason IS NOT NULL THEN
      log_run('check_backups', 'SKIP', NULL, l_reason);
      RETURN;
    END IF;

    -- Without an OCID there is nothing to ask the API about. Say that, rather
    -- than letting evaluate_backups conclude "no backups exist" from an empty
    -- table: a configuration gap and a missing backup need different responses.
    IF pkg_mon.db_ocid IS NULL THEN
      pkg_mon.raise_alert('BKP_CONFIG', 'WARNING',
        'Backup monitoring is not configured',
        'This database OCID could not be determined, so backup status was never' || CHR(10) ||
        'requested from OCI. Grant DBMON access to V$PDBS, or set DB_OCID in' || CHR(10) ||
        'MON_CONFIG. Until then nothing is watching your backups.');
      log_run('check_backups', 'SKIP', NULL, 'database OCID unknown');
      RETURN;
    END IF;
    pkg_mon.clear_alert('BKP_CONFIG');

    l_json := fetch_backups_json;
    IF l_json IS NOT NULL THEN
      load_backups(l_json);
    END IF;

    IF UPPER(NVL(pkg_mon.cfg('BACKUP_CHECK_DB_STATE', 'Y'), 'Y')) = 'Y' THEN
      l_json := fetch_database_json;
      IF l_json IS NOT NULL THEN
        load_db_details(l_json);
      END IF;
    END IF;

    evaluate_backups;

    log_run('check_backups', 'OK', (DBMS_UTILITY.GET_TIME - l_t0) * 10);
  EXCEPTION WHEN OTHERS THEN
    log_run('check_backups', 'ERROR', (DBMS_UTILITY.GET_TIME - l_t0) * 10, SQLERRM);
  END check_backups;

  --========================================================== custom metrics ==--

  PROCEDURE publish_metric (p_name  IN VARCHAR2,
                            p_value IN NUMBER,
                            p_unit  IN VARCHAR2 DEFAULT NULL) IS
    l_resp    DBMS_CLOUD_TYPES.RESP;
    l_body    VARCHAR2(32767);
    l_uri     VARCHAR2(500);
    l_comp    VARCHAR2(255) := pkg_mon.compartment;
    l_code    NUMBER;
  BEGIN
    IF l_comp IS NULL OR pkg_mon.db_region IS NULL THEN
      log_run('oci:publish_metric', 'SKIP', NULL, 'compartment or region unknown');
      RETURN;
    END IF;

    l_body := JSON_OBJECT(
      'metricData' VALUE JSON_ARRAY(
        JSON_OBJECT(
          'namespace'     VALUE 'custom_adb_monitor',
          'compartmentId' VALUE l_comp,
          'name'          VALUE p_name,
          'dimensions'    VALUE JSON_OBJECT('dbName'     VALUE pkg_mon.db_name,
                                            'resourceId' VALUE pkg_mon.db_ocid),
          'datapoints'    VALUE JSON_ARRAY(
            JSON_OBJECT('timestamp' VALUE TO_CHAR(SYSTIMESTAMP AT TIME ZONE 'UTC',
                                                  'YYYY-MM-DD"T"HH24:MI:SS.FF3"Z"'),
                        'value'     VALUE p_value)))));

    l_uri := 'https://telemetry-ingestion.' || pkg_mon.db_region || '.' ||
             pkg_mon.cfg('SERVICE_DOMAIN', 'oraclecloud.com') || '/20180401/metrics';

    l_resp := DBMS_CLOUD.SEND_REQUEST(credential_name => c_cred,
                                      uri             => l_uri,
                                      method          => DBMS_CLOUD.METHOD_POST,
                                      body            => UTL_RAW.CAST_TO_RAW(l_body));

    l_code := DBMS_CLOUD.GET_RESPONSE_STATUS_CODE(l_resp);
    IF l_code NOT IN (200, 201) THEN
      log_run('oci:publish_metric', 'WARN', NULL,
              p_name || ': HTTP ' || l_code || ' ' ||
              SUBSTR(DBMS_CLOUD.GET_RESPONSE_TEXT(l_resp), 1, 500));
    END IF;
  EXCEPTION WHEN OTHERS THEN
    log_run('oci:publish_metric', 'WARN', NULL, p_name || ': ' || SQLERRM);
  END publish_metric;

  PROCEDURE publish_heartbeat IS
    l_open  NUMBER;
    l_age   NUMBER;
    l_errs  NUMBER;
  BEGIN
    IF pkg_mon.is_active = 'N' THEN
      RETURN;                                   -- a clone must not fake a heartbeat
    END IF;

    publish_metric('MonitorHeartbeat', 1, 'count');

    SELECT COUNT(*) INTO l_open FROM mon_alert WHERE state = 'OPEN';
    publish_metric('OpenAlerts', l_open, 'count');

    SELECT hours_since_good INTO l_age FROM v_mon_backup_summary;
    IF l_age IS NOT NULL THEN
      publish_metric('BackupAgeHours', l_age, 'hours');
    END IF;

    SELECT COUNT(*) INTO l_errs
      FROM mon_job_log
     WHERE run_at > SYSTIMESTAMP - INTERVAL '1' HOUR
       AND status = 'ERROR';
    publish_metric('CollectorErrors', l_errs, 'count');
  EXCEPTION WHEN OTHERS THEN
    log_run('oci:publish_heartbeat', 'WARN', NULL, SQLERRM);
  END publish_heartbeat;

  --============================================================== self test ==--

  PROCEDURE self_test IS
    l_json CLOB;
    l_n    NUMBER;
  BEGIN
    DBMS_OUTPUT.PUT_LINE('pkg_mon_oci ' || c_version);
    DBMS_OUTPUT.PUT_LINE('  credential : ' || c_cred);
    DBMS_OUTPUT.PUT_LINE('  endpoint   : ' || endpoint_base);

    l_json := fetch_backups_json;
    IF l_json IS NULL THEN
      DBMS_OUTPUT.PUT_LINE('  API call   : FAILED - see MON_ALERT key BKP_API');
    ELSE
      SELECT COUNT(*) INTO l_n
        FROM JSON_TABLE(as_array(l_json), '$[*]' COLUMNS (id VARCHAR2(255) PATH '$.id'));
      DBMS_OUTPUT.PUT_LINE('  API call   : OK, ' || l_n || ' backups returned');
    END IF;
  EXCEPTION WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('  self_test  : ' || SQLERRM);
  END self_test;

END pkg_mon_oci;
/
SHOW ERRORS
