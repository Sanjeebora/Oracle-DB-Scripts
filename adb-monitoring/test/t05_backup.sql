--------------------------------------------------------------------------------
-- t05_backup.sql   Backup monitoring, driven from captured OCI API payloads.
--
-- This is why PKG_MON_OCI separates fetching from parsing: the whole detection
-- path can be exercised offline, including the cases you cannot reproduce on
-- demand against a real tenancy, such as a failed automatic backup.
--
-- The fixtures below are shaped exactly like a ListAutonomousDatabaseBackups
-- response: a bare JSON array of backup objects.
--------------------------------------------------------------------------------
SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE OFF

DECLARE
  l_n     NUMBER;
  l_txt   VARCHAR2(4000);
  l_json  CLOB;
  l_now   VARCHAR2(30) := TO_CHAR(SYSTIMESTAMP AT TIME ZONE 'UTC',
                                  'YYYY-MM-DD"T"HH24:MI:SS.FF3"Z"');
  l_2h    VARCHAR2(30) := TO_CHAR((SYSTIMESTAMP - INTERVAL '2' HOUR) AT TIME ZONE 'UTC',
                                  'YYYY-MM-DD"T"HH24:MI:SS.FF3"Z"');
  l_4d    VARCHAR2(30) := TO_CHAR((SYSTIMESTAMP - INTERVAL '4' DAY) AT TIME ZONE 'UTC',
                                  'YYYY-MM-DD"T"HH24:MI:SS.FF3"Z"');

  PROCEDURE wipe IS
  BEGIN
    DELETE FROM mon_backup;
    DELETE FROM mon_alert WHERE alert_key LIKE 'BKP!_%' ESCAPE '!'
                             OR alert_key = 'DB_LIFECYCLE';
    COMMIT;
  END;
BEGIN
  pkg_mon_test.require_test_mode;
  pkg_mon_test.section('t05 backup monitoring');

  pkg_mon.set_cfg('NOTIFY_PROVIDER', 'log');
  pkg_mon.set_cfg('BACKUP_MAX_AGE_HOURS', '30');

  --===========================================================================
  -- Case 1: a healthy recent automatic backup
  --===========================================================================
  wipe;
  l_json := '[
    {"id":"ocid1.autonomousdatabasebackup.oc1..test001",
     "displayName":"automatic-backup-2026-08-31",
     "type":"INCREMENTAL",
     "isAutomatic":true,
     "lifecycleState":"ACTIVE",
     "timeStarted":"' || l_2h || '",
     "timeEnded":"'   || l_2h || '",
     "isRestorable":true,
     "retentionPeriodInDays":60}
  ]';

  pkg_mon_oci.load_backups(l_json);

  SELECT COUNT(*) INTO l_n FROM mon_backup;
  pkg_mon_test.eq('payload parsed into one backup row', l_n, 1);

  SELECT COUNT(*) INTO l_n
    FROM mon_backup
   WHERE backup_id = 'ocid1.autonomousdatabasebackup.oc1..test001'
     AND lifecycle_state = 'ACTIVE'
     AND time_ended IS NOT NULL;
  pkg_mon_test.eq('ISO 8601 timestamps converted correctly', l_n, 1);

  pkg_mon_oci.evaluate_backups;

  SELECT COUNT(*) INTO l_n FROM mon_alert
   WHERE alert_key IN ('BKP_STALE','BKP_NONE') AND state = 'OPEN';
  pkg_mon_test.eq('a recent good backup raises nothing', l_n, 0);

  --===========================================================================
  -- Case 2: last night's automatic backup failed
  --===========================================================================
  wipe;
  l_json := '[
    {"id":"ocid1.autonomousdatabasebackup.oc1..test002",
     "displayName":"automatic-backup-failed",
     "type":"INCREMENTAL",
     "isAutomatic":true,
     "lifecycleState":"FAILED",
     "lifecycleDetails":"Backup failed due to insufficient storage on the destination",
     "timeStarted":"' || l_2h || '",
     "timeEnded":"'   || l_2h || '",
     "isRestorable":false}
  ]';

  pkg_mon_oci.load_backups(l_json);
  pkg_mon_oci.evaluate_backups;

  SELECT COUNT(*) INTO l_n FROM mon_alert
   WHERE alert_key = 'BKP_FAILED_ocid1.autonomousdatabasebackup.oc1..test002'
     AND state = 'OPEN' AND severity = 'CRITICAL';
  pkg_mon_test.eq('a FAILED backup raises a CRITICAL alert', l_n, 1);

  SELECT SUBSTR(detail, 1, 4000) INTO l_txt FROM mon_alert
   WHERE alert_key = 'BKP_FAILED_ocid1.autonomousdatabasebackup.oc1..test002';
  pkg_mon_test.ok('the alert quotes the reason the service gave',
                  INSTR(l_txt, 'insufficient storage') > 0);
  pkg_mon_test.ok('the alert says whether it was automatic',
                  INSTR(l_txt, 'automatic') > 0);

  -- A failed backup also means no good backup, so staleness must fire too.
  SELECT COUNT(*) INTO l_n FROM mon_alert
   WHERE alert_key = 'BKP_STALE' AND state = 'OPEN';
  pkg_mon_test.eq('a failure also triggers the staleness check', l_n, 1);

  --===========================================================================
  -- Case 3: nothing failed, but nothing succeeded either
  --
  -- The important case. A backup that never starts emits no failure event, so
  -- an event-driven alarm alone would stay silent here.
  --===========================================================================
  wipe;
  l_json := '[
    {"id":"ocid1.autonomousdatabasebackup.oc1..test003",
     "displayName":"automatic-backup-old",
     "type":"FULL",
     "isAutomatic":true,
     "lifecycleState":"ACTIVE",
     "timeStarted":"' || l_4d || '",
     "timeEnded":"'   || l_4d || '",
     "isRestorable":true}
  ]';

  pkg_mon_oci.load_backups(l_json);
  pkg_mon_oci.evaluate_backups;

  SELECT COUNT(*) INTO l_n FROM mon_alert
   WHERE alert_key = 'BKP_STALE' AND state = 'OPEN' AND severity = 'CRITICAL';
  pkg_mon_test.eq('four days with no new backup raises BKP_STALE', l_n, 1);

  SELECT COUNT(*) INTO l_n FROM mon_alert
   WHERE alert_key LIKE 'BKP_FAILED%' AND state = 'OPEN';
  pkg_mon_test.eq('nothing is reported as failed, because nothing failed', l_n, 0);

  --===========================================================================
  -- Case 4: no backups exist at all
  --===========================================================================
  wipe;
  pkg_mon_oci.load_backups('[]');
  pkg_mon_oci.evaluate_backups;

  SELECT COUNT(*) INTO l_n FROM mon_alert
   WHERE alert_key = 'BKP_NONE' AND state = 'OPEN' AND severity = 'CRITICAL';
  pkg_mon_test.eq('an empty backup list raises BKP_NONE', l_n, 1);

  --===========================================================================
  -- Case 5: a backup that exists but cannot be restored from
  --===========================================================================
  wipe;
  l_json := '[
    {"id":"ocid1.autonomousdatabasebackup.oc1..test005",
     "displayName":"automatic-backup-unrestorable",
     "type":"INCREMENTAL",
     "isAutomatic":true,
     "lifecycleState":"ACTIVE",
     "timeStarted":"' || l_2h || '",
     "timeEnded":"'   || l_2h || '",
     "isRestorable":false}
  ]';

  pkg_mon_oci.load_backups(l_json);
  pkg_mon_oci.evaluate_backups;

  SELECT COUNT(*) INTO l_n FROM mon_alert
   WHERE alert_key LIKE 'BKP_UNRESTORABLE%' AND state = 'OPEN';
  pkg_mon_test.eq('a successful but unrestorable backup is still flagged', l_n, 1);

  --===========================================================================
  -- Case 6: recovery. A good backup arrives and the alerts close themselves.
  --===========================================================================
  l_json := '[
    {"id":"ocid1.autonomousdatabasebackup.oc1..test006",
     "displayName":"automatic-backup-recovered",
     "type":"INCREMENTAL",
     "isAutomatic":true,
     "lifecycleState":"ACTIVE",
     "timeStarted":"' || l_now || '",
     "timeEnded":"'   || l_now || '",
     "isRestorable":true}
  ]';

  pkg_mon_oci.load_backups(l_json);
  pkg_mon_oci.evaluate_backups;

  SELECT COUNT(*) INTO l_n FROM mon_alert
   WHERE alert_key IN ('BKP_STALE','BKP_NONE') AND state = 'OPEN';
  pkg_mon_test.eq('a fresh good backup closes the staleness alerts', l_n, 0);

  --===========================================================================
  -- Case 7: idempotent reload. Polling every 30 minutes must not duplicate.
  --===========================================================================
  pkg_mon_oci.load_backups(l_json);
  pkg_mon_oci.load_backups(l_json);

  SELECT COUNT(*) INTO l_n
    FROM mon_backup WHERE backup_id = 'ocid1.autonomousdatabasebackup.oc1..test006';
  pkg_mon_test.eq('re-polling the same backup updates rather than duplicates', l_n, 1);

  --===========================================================================
  -- Case 8: an {"items":[...]} wrapper is handled as well as a bare array
  --===========================================================================
  wipe;
  pkg_mon_oci.load_backups('{"items":[
    {"id":"ocid1.autonomousdatabasebackup.oc1..test008",
     "displayName":"wrapped","type":"FULL","isAutomatic":true,
     "lifecycleState":"ACTIVE","timeStarted":"' || l_2h || '",
     "timeEnded":"' || l_2h || '","isRestorable":true}]}');

  SELECT COUNT(*) INTO l_n FROM mon_backup;
  pkg_mon_test.eq('a wrapped payload parses too', l_n, 1);

  --===========================================================================
  -- Case 9: database detail payload, retention drift and lifecycle state
  --===========================================================================
  DELETE FROM mon_alert WHERE alert_key IN ('BKP_RETENTION','DB_LIFECYCLE');
  COMMIT;

  pkg_mon.set_cfg('BACKUP_MIN_RETENTION_DAYS', '30');
  pkg_mon_oci.load_db_details(
    '{"lifecycleState":"AVAILABLE","backupRetentionPeriodInDays":7}');

  SELECT COUNT(*) INTO l_n FROM mon_alert
   WHERE alert_key = 'BKP_RETENTION' AND state = 'OPEN';
  pkg_mon_test.eq('retention below policy raises a warning', l_n, 1);

  pkg_mon_oci.load_db_details(
    '{"lifecycleState":"AVAILABLE","backupRetentionPeriodInDays":60}');

  SELECT COUNT(*) INTO l_n FROM mon_alert
   WHERE alert_key = 'BKP_RETENTION' AND state = 'OPEN';
  pkg_mon_test.eq('restoring retention closes the warning', l_n, 0);

  pkg_mon_oci.load_db_details(
    '{"lifecycleState":"UNAVAILABLE","backupRetentionPeriodInDays":60}');

  SELECT COUNT(*) INTO l_n FROM mon_alert
   WHERE alert_key = 'DB_LIFECYCLE' AND state = 'OPEN' AND severity = 'CRITICAL';
  pkg_mon_test.eq('a non-AVAILABLE lifecycle state is CRITICAL', l_n, 1);

  --===========================================================================
  -- Case 10: the summary view a DBA actually looks at
  --===========================================================================
  wipe;
  pkg_mon_oci.load_backups('[
    {"id":"b1","displayName":"ok","type":"INCREMENTAL","isAutomatic":true,
     "lifecycleState":"ACTIVE","timeStarted":"' || l_2h || '",
     "timeEnded":"' || l_2h || '","isRestorable":true},
    {"id":"b2","displayName":"bad","type":"INCREMENTAL","isAutomatic":true,
     "lifecycleState":"FAILED","timeStarted":"' || l_4d || '",
     "timeEnded":"' || l_4d || '","isRestorable":false}]');

  SELECT failed_last_7d INTO l_n FROM v_mon_backup_summary;
  pkg_mon_test.eq('summary view counts recent failures', l_n, 1);

  SELECT ROUND(hours_since_good) INTO l_n FROM v_mon_backup_summary;
  pkg_mon_test.eq('summary view reports the age of the last good backup', l_n, 2);

  ------------------------------------------------------------------- cleanup
  wipe;
  DELETE FROM mon_alert WHERE alert_key IN ('BKP_RETENTION','DB_LIFECYCLE');
  DELETE FROM mon_notify_log;
  DELETE FROM mon_metric WHERE metric_group = 'BACKUP';
  COMMIT;
END;
/

PROMPT
PROMPT --- Live API check (real tenancy only)
PROMPT   EXEC pkg_mon_oci.self_test;;
PROMPT   EXEC pkg_mon_oci.check_backups;;
PROMPT   SELECT * FROM v_mon_backup_summary;;
PROMPT   SELECT * FROM v_mon_backup_status ORDER BY time_ended DESC;;
PROMPT
PROMPT   If self_test reports FAILED, the alert MON_ALERT key BKP_API explains
PROMPT   which of the four usual causes applies.
