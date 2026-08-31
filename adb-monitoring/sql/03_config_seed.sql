--------------------------------------------------------------------------------
-- 03_config_seed.sql
--
-- Run as DBMON. Seeds default configuration.
-- Re-runnable: only inserts keys that are missing, so your tuned thresholds and
-- notification settings survive an upgrade.
--
-- Every threshold lives here, never in code. Tune with:
--     EXEC pkg_mon.set_cfg('CPU_PCT_WARN', '90');
--------------------------------------------------------------------------------
SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE OFF

DECLARE
  PROCEDURE seed (p_key VARCHAR2, p_val VARCHAR2, p_descr VARCHAR2) IS
  BEGIN
    INSERT INTO mon_config (cfg_key, cfg_value, descr)
    SELECT p_key, p_val, p_descr FROM dual
     WHERE NOT EXISTS (SELECT 1 FROM mon_config WHERE cfg_key = p_key);
    IF SQL%ROWCOUNT > 0 THEN
      DBMS_OUTPUT.PUT_LINE('  seeded  ' || RPAD(p_key, 28) || ' = ' || p_val);
    ELSE
      DBMS_OUTPUT.PUT_LINE('  kept    ' || RPAD(p_key, 28) || ' (existing value)');
    END IF;
  END;
BEGIN
  ------------------------------------------------------------- global switches --
  seed('ENABLED',              'Y',   'Master switch. N disables every collector.');
  seed('PACK_VERSION',         '1.0.0','Installed version of the monitoring pack.');

  --------------------------------------------------------------- identity ------
  -- Left blank on ADB: resolved automatically from V$PDBS.CLOUD_IDENTITY.
  -- Populate manually only if V$PDBS is not readable.
  seed('DB_OCID',              NULL,  'Override for this database OCID.');
  seed('COMPARTMENT_OCID',     NULL,  'Override for the compartment OCID.');
  seed('REGION',               NULL,  'Override for the OCI region, e.g. eu-frankfurt-1.');
  seed('DB_NAME',              NULL,  'Override for the display name used in alerts.');
  seed('SERVICE_DOMAIN',       'oraclecloud.com',
       'Realm domain for OCI endpoints. Change for Gov/dedicated realms.');

  -- Clone guard: if the live OCID stops matching this, the pack goes silent.
  -- 10_verify.sql populates it. Clear it to disable the guard.
  seed('EXPECTED_DB_OCID',     NULL,  'Pack refuses to alert if the live OCID differs.');

  ----------------------------------------------------------- notification ------
  -- Ships as "log" so a fresh install never pages anyone before it is configured.
  seed('NOTIFY_PROVIDER',      'log',
       'log | oci | slack | msteams | email.  log = record only, send nothing.');
  seed('NOTIFY_CREDENTIAL',    'OCI$RESOURCE_PRINCIPAL',
       'Credential for DBMS_CLOUD_NOTIFICATION.');
  seed('NOTIFY_TOPIC_OCID',    NULL,  'ONS topic OCID when NOTIFY_PROVIDER = oci.');
  seed('NOTIFY_CHANNEL',       NULL,  'Channel id when NOTIFY_PROVIDER = slack/msteams.');
  seed('NOTIFY_EMAIL',         NULL,  'Recipient when NOTIFY_PROVIDER = email.');
  seed('NOTIFY_MIN_SEVERITY',  'INFO','Lowest severity actually delivered: INFO|WARNING|CRITICAL.');
  seed('ALERT_COOLDOWN_MIN',   '30',  'Minutes before the same open alert re-notifies.');
  seed('ALERT_AUTOCLOSE_MIN',  '60',  'Minutes of silence before an alert self-closes.');

  ------------------------------------------------- resource consumption --------
  seed('CPU_PCT_WARN',         '85',  'Database CPU time ratio percent, informational.');
  seed('AAS_PER_CPU_WARN',     '1.5', 'Average active sessions per allocated CPU.');
  seed('QUEUE_LEN_WARN',       '5',   'Queued sessions in a consumer group.');
  seed('TBS_PCT_WARN',         '85',  'Tablespace used percent, warning.');
  seed('TBS_PCT_CRIT',         '92',  'Tablespace used percent, critical.');
  seed('SESSION_PCT_WARN',     '85',  'Session/process utilisation percent.');
  seed('STORAGE_DAYS_TO_FULL_WARN', '14',
       'Warn when the growth trend projects a full tablespace within N days.');

  --------------------------------------------------------------- slow SQL ------
  seed('SLOW_SQL_SEC',         '300', 'A statement running longer than this is "slow".');
  seed('SLOW_SQL_MIN_EXECS',   '10',  'Minimum executions before average-based alerting.');
  seed('SLOW_SQL_ASH_SAMPLES', '30',  'Minimum ASH samples for a SQL to count as a top consumer.');
  seed('REGRESSION_FACTOR',    '2',   'New plan is a regression if this many times slower.');
  seed('SQL_EXCLUDE_USERS',    'SYS,SYSTEM,DBSNMP,DBMON,C##CLOUD$SERVICE',
       'Comma separated users never reported as slow-SQL owners.');

  ---------------------------------------------------------------- backups ------
  seed('BACKUP_MAX_AGE_HOURS', '30',
       'Alert if no successful backup completed within this many hours.');
  seed('BACKUP_MIN_RETENTION_DAYS', '30',
       'Alert if the configured backup retention drops below this.');
  seed('BACKUP_API_LIMIT',     '25',  'How many backups to fetch per poll.');
  seed('BACKUP_CHECK_DB_STATE','Y',   'Also check lifecycleState and retention drift.');

  ------------------------------------------------------------- retention -------
  seed('RETAIN_METRIC_DAYS',   '35',  'Days of mon_metric history to keep.');
  seed('RETAIN_SQL_DAYS',      '90',  'Days of mon_sql_slow history to keep.');
  seed('RETAIN_ALERT_DAYS',    '180', 'Days of closed alerts to keep.');
  seed('RETAIN_JOBLOG_DAYS',   '14',  'Days of mon_job_log to keep.');

  ------------------------------------------------------------ remediation ------
  -- Off by default. Turn on only after you have read the README section on
  -- guardrails, and keep DRY_RUN = Y until you trust the allowlist.
  seed('REMEDIATION_ENABLED',  'N',   'Master switch for automatic actions.');
  seed('REMEDIATION_DRY_RUN',  'Y',   'Log the action that would be taken, do not take it.');
  seed('REMEDIATION_ALLOW_USERS', NULL,
       'Comma separated schemas whose SQL may be cancelled automatically.');
  seed('REMEDIATION_MAX_PER_HOUR', '3', 'Hard cap on automatic actions per hour.');

  COMMIT;
END;
/

PROMPT
PROMPT --- Current configuration
COLUMN cfg_key   FORMAT A30
COLUMN cfg_value FORMAT A40
SELECT cfg_key, cfg_value FROM mon_config ORDER BY cfg_key;
