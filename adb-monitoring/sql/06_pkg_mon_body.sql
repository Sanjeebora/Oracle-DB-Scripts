--------------------------------------------------------------------------------
-- 06_pkg_mon_body.sql
--
-- Run as DBMON. Core monitoring package body.
--
-- Design notes
--   * Every dictionary access is dynamic SQL built from a template. A view that
--     is not granted disables exactly one collector, at runtime, with a WARN row
--     in MON_JOB_LOG. The package always compiles.
--   * Because the statements are dynamic, their syntax is NOT checked at compile
--     time. pkg_mon.validate_sql parses all of them against the live dictionary,
--     which is the check that matters. Run it after every install and after any
--     Autonomous Database version upgrade.
--   * Thresholds are substituted as validated numeric literals, never as raw
--     configuration text, so MON_CONFIG cannot be used to inject SQL.
--------------------------------------------------------------------------------
SET DEFINE OFF

CREATE OR REPLACE PACKAGE BODY pkg_mon AS

  --=================================================== state and declarations ==--

  g_init        BOOLEAN := FALSE;
  g_db_ocid     VARCHAR2(255);
  g_region      VARCHAR2(64);
  g_db_name     VARCHAR2(128);
  g_compartment VARCHAR2(255);

  TYPE t_coll  IS RECORD (tag VARCHAR2(40), stmt VARCHAR2(32767));
  TYPE t_colls IS TABLE OF t_coll INDEX BY PLS_INTEGER;

  --------------------------------------------------------------------------------
  -- Collector templates. %TOKEN% placeholders are replaced with validated
  -- literals by the collectors function below.
  --------------------------------------------------------------------------------

  -- One row per metric, taken from the longest reporting interval available.
  --
  -- Deliberately does not filter on GROUP_ID. Both views carry the same metric
  -- under several group ids (short and long sampling windows), and the numbering
  -- differs between them: V$SYSMETRIC uses 2 for the long window while
  -- V$CON_SYSMETRIC uses 18. Hardcoding 2 silently collects nothing on a PDB,
  -- and Autonomous Database is a PDB. Picking the largest INTSIZE_CSEC gets the
  -- long window whatever it is numbered, and the GROUP BY removes the duplicates.
  c_sql_sysmetric CONSTANT VARCHAR2(4000) := q'~
INSERT INTO mon_metric (metric_group, metric_name, dim1, metric_value, metric_unit)
SELECT 'SYS', metric_name, NULL,
       MAX(value)       KEEP (DENSE_RANK LAST ORDER BY intsize_csec, end_time),
       MAX(metric_unit) KEEP (DENSE_RANK LAST ORDER BY intsize_csec, end_time)
  FROM %VIEW%
 WHERE metric_name IN ('CPU Usage Per Sec',
                       'Average Active Sessions',
                       'Database CPU Time Ratio',
                       'Database Wait Time Ratio',
                       'Executions Per Sec',
                       'User Transaction Per Sec',
                       'SQL Service Response Time',
                       'Logons Per Sec',
                       'Session Limit %',
                       'RM eCPU Waits Per Sec',
                       'Physical Read Total Bytes Per Sec',
                       'Physical Write Total Bytes Per Sec')
 GROUP BY metric_name~';

  c_sql_rsrc CONSTANT VARCHAR2(4000) := q'~
INSERT INTO mon_metric (metric_group, metric_name, dim1, metric_value, metric_unit)
SELECT 'RSRC', 'active_sessions', name, active_sessions, 'sessions'
  FROM v$rsrc_consumer_group
 WHERE name IN ('TPURGENT','TP','HIGH','MEDIUM','LOW')
UNION ALL
SELECT 'RSRC', 'queue_length', name, queue_length, 'sessions'
  FROM v$rsrc_consumer_group
 WHERE name IN ('TPURGENT','TP','HIGH','MEDIUM','LOW')
UNION ALL
SELECT 'RSRC', 'cpu_wait_time', name, cpu_wait_time, 'ms'
  FROM v$rsrc_consumer_group
 WHERE name IN ('TPURGENT','TP','HIGH','MEDIUM','LOW')
UNION ALL
SELECT 'RSRC', 'consumed_cpu_time', name, consumed_cpu_time, 'ms'
  FROM v$rsrc_consumer_group
 WHERE name IN ('TPURGENT','TP','HIGH','MEDIUM','LOW')~';

  c_sql_storage CONSTANT VARCHAR2(4000) := q'~
INSERT INTO mon_metric (metric_group, metric_name, dim1, metric_value, metric_unit)
SELECT 'STORAGE', 'tablespace_used_pct', tablespace_name, used_percent, 'percent'
  FROM dba_tablespace_usage_metrics~';

  c_sql_limits CONSTANT VARCHAR2(4000) := q'~
INSERT INTO mon_metric (metric_group, metric_name, dim1, metric_value, metric_unit)
SELECT 'LIMIT', 'utilization_pct', resource_name,
       ROUND(current_utilization * 100 /
             NULLIF(TO_NUMBER(NULLIF(TRIM(limit_value), 'UNLIMITED')), 0), 2), 'percent'
  FROM v$resource_limit
 WHERE resource_name IN ('processes','sessions')~';

  c_sql_cpucount CONSTANT VARCHAR2(4000) := q'~
INSERT INTO mon_metric (metric_group, metric_name, dim1, metric_value, metric_unit)
SELECT 'SYS', 'cpu_count', NULL, TO_NUMBER(value), 'count'
  FROM v$parameter
 WHERE name = 'cpu_count'~';

  -- Statements running right now for longer than the slow threshold.
  -- V$SQL_MONITOR carries SERVICE_NAME itself, so no join to V$SESSION is needed.
  -- Deliberately avoids ROWS_PROCESSED, which is not present in every release.
  c_sql_rtsm CONSTANT VARCHAR2(4000) := q'~
INSERT INTO mon_sql_slow (source, sql_id, plan_hash, username, service_name, module,
                          elapsed_sec, cpu_sec, buffer_gets, execs, sql_text)
SELECT 'RTSM', m.sql_id, m.sql_plan_hash_value, m.username, m.service_name, m.module,
       ROUND(m.elapsed_time / 1e6, 1), ROUND(m.cpu_time / 1e6, 1),
       m.buffer_gets, 1, SUBSTR(m.sql_text, 1, 4000)
  FROM gv$sql_monitor m
 WHERE m.status = 'EXECUTING'
   AND m.elapsed_time > %SLOWSEC% * 1e6
   AND INSTR('%EXCL%', ',' || NVL(m.username, '?') || ',') = 0~';

  -- Top SQL by sampled database time over the recent ASH window.
  c_sql_ash CONSTANT VARCHAR2(4000) := q'~
INSERT INTO mon_sql_slow (source, sql_id, plan_hash, username, service_name, module,
                          elapsed_sec, top_event, sql_text)
SELECT 'ASH', x.sql_id, x.plan_hash, u.username,
       (SELECT MAX(sv.name) FROM v$services sv WHERE sv.name_hash = x.service_hash),
       x.module, x.db_time_sec, x.top_event,
       (SELECT SUBSTR(MAX(q.sql_text), 1, 4000) FROM v$sql q WHERE q.sql_id = x.sql_id)
  FROM (SELECT a.sql_id,
               MAX(a.sql_plan_hash_value)         AS plan_hash,
               MAX(a.user_id)                     AS user_id,
               MAX(a.service_hash)                AS service_hash,
               MAX(a.module)                      AS module,
               COUNT(*)                           AS db_time_sec,
               NVL(STATS_MODE(a.event), 'ON CPU') AS top_event
          FROM v$active_session_history a
         WHERE a.sample_time > SYSTIMESTAMP - INTERVAL '5' MINUTE
           AND a.sql_id IS NOT NULL
         GROUP BY a.sql_id
        HAVING COUNT(*) >= %MINSAMPLES%
         ORDER BY COUNT(*) DESC
         FETCH FIRST 15 ROWS ONLY) x
  LEFT JOIN dba_users u ON u.user_id = x.user_id
 WHERE INSTR('%EXCL%', ',' || NVL(u.username, '?') || ',') = 0~';

  -- Same SQL, newer plan, materially slower than the plan it replaced.
  c_sql_regress CONSTANT VARCHAR2(4000) := q'~
WITH s AS (
  SELECT h.sql_id,
         h.plan_hash_value,
         SUM(h.elapsed_time_delta) / NULLIF(SUM(h.executions_delta), 0) / 1e6 AS avg_sec,
         SUM(h.executions_delta)     AS execs,
         MIN(sn.begin_interval_time) AS first_seen
    FROM dba_hist_sqlstat h
    JOIN dba_hist_snapshot sn
      ON sn.snap_id         = h.snap_id
     AND sn.dbid            = h.dbid
     AND sn.instance_number = h.instance_number
   WHERE sn.begin_interval_time > SYSTIMESTAMP - INTERVAL '7' DAY
     AND h.plan_hash_value > 0
   GROUP BY h.sql_id, h.plan_hash_value
  HAVING SUM(h.executions_delta) >= %MINEXECS%
)
SELECT cur.sql_id,
       cur.plan_hash_value    AS new_plan,
       ROUND(cur.avg_sec, 3)  AS new_sec,
       prev.plan_hash_value   AS old_plan,
       ROUND(prev.avg_sec, 3) AS old_sec,
       cur.execs              AS new_execs
  FROM s cur
  JOIN s prev
    ON prev.sql_id = cur.sql_id
   AND prev.plan_hash_value <> cur.plan_hash_value
   AND prev.first_seen < cur.first_seen
 WHERE cur.first_seen > SYSTIMESTAMP - INTERVAL '1' DAY
   AND cur.avg_sec > prev.avg_sec * %FACTOR%
   AND cur.avg_sec > 0.5
 ORDER BY cur.avg_sec DESC
 FETCH FIRST 10 ROWS ONLY~';

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

  FUNCTION cfg (p_key IN VARCHAR2, p_def IN VARCHAR2 DEFAULT NULL) RETURN VARCHAR2 IS
    l_val VARCHAR2(4000);
  BEGIN
    SELECT cfg_value INTO l_val FROM mon_config WHERE cfg_key = p_key;
    RETURN NVL(l_val, p_def);
  EXCEPTION
    WHEN NO_DATA_FOUND THEN RETURN p_def;
    WHEN OTHERS         THEN RETURN p_def;
  END cfg;

  FUNCTION cfgn (p_key IN VARCHAR2, p_def IN NUMBER DEFAULT NULL) RETURN NUMBER IS
    l_val VARCHAR2(4000) := cfg(p_key);
  BEGIN
    IF l_val IS NULL THEN
      RETURN p_def;                           -- missing key, or key set to NULL
    END IF;
    RETURN TO_NUMBER(l_val);
  EXCEPTION WHEN OTHERS THEN
    RETURN p_def;                             -- present but not a number
  END cfgn;

  PROCEDURE set_cfg (p_key IN VARCHAR2, p_value IN VARCHAR2) IS
  BEGIN
    MERGE INTO mon_config t
    USING (SELECT p_key AS k, p_value AS v FROM dual) s
    ON (t.cfg_key = s.k)
    WHEN MATCHED THEN UPDATE SET t.cfg_value = s.v, t.updated_at = SYSTIMESTAMP
    WHEN NOT MATCHED THEN INSERT (cfg_key, cfg_value, descr)
                          VALUES (s.k, s.v, 'set via pkg_mon.set_cfg');
    COMMIT;
  END set_cfg;

  -- Numeric literal, safe to inline into generated SQL.
  FUNCTION num_lit (p_key VARCHAR2, p_def NUMBER) RETURN VARCHAR2 IS
    l_n NUMBER := NVL(cfgn(p_key, p_def), p_def);
  BEGIN
    RETURN TO_CHAR(l_n, 'TM9', 'NLS_NUMERIC_CHARACTERS=''.,''');
  END num_lit;

  -- Comma list reduced to identifier characters, safe to inline into generated SQL.
  FUNCTION list_lit (p_key VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    RETURN ',' || REGEXP_REPLACE(UPPER(NVL(cfg(p_key), 'SYS')), '[^A-Z0-9_$#,]', '') || ',';
  END list_lit;

  --================================================================ identity ==--

  PROCEDURE init_identity IS
    l_json CLOB;
  BEGIN
    IF g_init THEN
      RETURN;
    END IF;

    BEGIN
      EXECUTE IMMEDIATE 'SELECT cloud_identity FROM v$pdbs WHERE ROWNUM = 1' INTO l_json;
      g_db_ocid     := JSON_VALUE(l_json, '$.DATABASE_OCID');
      g_region      := JSON_VALUE(l_json, '$.REGION');
      g_db_name     := JSON_VALUE(l_json, '$.DATABASE_NAME');
      g_compartment := JSON_VALUE(l_json, '$.COMPARTMENT_OCID');
    EXCEPTION WHEN OTHERS THEN
      NULL;                                   -- not an ADB, or no grant on V$PDBS
    END;

    g_db_ocid     := NVL(g_db_ocid,     cfg('DB_OCID'));
    g_region      := NVL(g_region,      cfg('REGION'));
    g_compartment := NVL(g_compartment, cfg('COMPARTMENT_OCID'));
    g_db_name     := NVL(NVL(g_db_name, cfg('DB_NAME')), SYS_CONTEXT('USERENV', 'DB_NAME'));

    g_init := TRUE;
  END init_identity;

  PROCEDURE reset_identity IS
  BEGIN
    g_init        := FALSE;
    g_db_ocid     := NULL;
    g_region      := NULL;
    g_db_name     := NULL;
    g_compartment := NULL;
  END reset_identity;

  FUNCTION db_ocid RETURN VARCHAR2 IS
  BEGIN
    init_identity;
    RETURN g_db_ocid;
  END db_ocid;

  FUNCTION db_region RETURN VARCHAR2 IS
  BEGIN
    init_identity;
    RETURN g_region;
  END db_region;

  FUNCTION db_name RETURN VARCHAR2 IS
  BEGIN
    init_identity;
    RETURN g_db_name;
  END db_name;

  FUNCTION compartment RETURN VARCHAR2 IS
  BEGIN
    init_identity;
    RETURN g_compartment;
  END compartment;

  FUNCTION console_url RETURN VARCHAR2 IS
  BEGIN
    init_identity;
    IF g_db_ocid IS NULL THEN
      RETURN NULL;
    END IF;
    RETURN 'https://cloud.oracle.com/db/adb/' || g_db_ocid || '?region=' || g_region;
  END console_url;

  FUNCTION inactive_reason RETURN VARCHAR2 IS
    l_expected VARCHAR2(4000) := cfg('EXPECTED_DB_OCID');
  BEGIN
    init_identity;

    IF UPPER(NVL(cfg('ENABLED', 'Y'), 'Y')) <> 'Y' THEN
      RETURN 'disabled by MON_CONFIG.ENABLED';
    END IF;

    -- Clone guard. A refreshed clone inherits these jobs; without this it would
    -- page the production on-call about a database nobody is using.
    IF l_expected IS NOT NULL
       AND g_db_ocid IS NOT NULL
       AND LOWER(l_expected) <> LOWER(g_db_ocid) THEN
      RETURN 'clone detected: live OCID does not match EXPECTED_DB_OCID';
    END IF;

    RETURN NULL;
  END inactive_reason;

  FUNCTION is_active RETURN VARCHAR2 IS
  BEGIN
    RETURN CASE WHEN inactive_reason IS NULL THEN 'Y' ELSE 'N' END;
  END is_active;

  -- Run collectors in the LOW consumer group so monitoring never competes with
  -- user workload. Best effort: not available outside Autonomous Database.
  PROCEDURE demote IS
    l_old VARCHAR2(128);
  BEGIN
    EXECUTE IMMEDIATE
      'BEGIN CS_SESSION.SWITCH_CURRENT_CONSUMER_GROUP(:1, :2, FALSE); END;'
      USING IN 'LOW', OUT l_old;
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END demote;

  --============================================================ notification ==--

  FUNCTION sev_rank (p_sev VARCHAR2) RETURN NUMBER IS
  BEGIN
    RETURN CASE UPPER(p_sev) WHEN 'CRITICAL' THEN 3 WHEN 'WARNING' THEN 2 ELSE 1 END;
  END sev_rank;

  PROCEDURE notify (p_sev IN VARCHAR2, p_title IN VARCHAR2, p_body IN CLOB) IS
    l_provider VARCHAR2(30)  := LOWER(NVL(cfg('NOTIFY_PROVIDER', 'log'), 'log'));
    l_cred     VARCHAR2(128) := cfg('NOTIFY_CREDENTIAL', 'OCI$RESOURCE_PRINCIPAL');
    l_min_sev  VARCHAR2(10)  := cfg('NOTIFY_MIN_SEVERITY', 'INFO');
    l_msg      VARCHAR2(4000);
    l_subject  VARCHAR2(400);
    l_params   CLOB;
    l_status   VARCHAR2(10)  := 'SENT';
    l_err      VARCHAR2(4000);
  BEGIN
    init_identity;

    l_subject := SUBSTR('[' || UPPER(p_sev) || '] ' || g_db_name || ' - ' || p_title, 1, 400);
    l_msg     := SUBSTR(l_subject || CHR(10) || CHR(10) ||
                        SUBSTR(p_body, 1, 3200) || CHR(10) || CHR(10) ||
                        'Time    : ' || TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD HH24:MI:SS TZR') ||
                        CHR(10) ||
                        'Console : ' || NVL(console_url, 'n/a'), 1, 4000);

    IF sev_rank(p_sev) < sev_rank(l_min_sev) THEN
      l_provider := 'log';
      l_status   := 'FILTERED';
    END IF;

    IF l_provider <> 'log' THEN
      BEGIN
        IF l_provider = 'oci' THEN
          l_params := JSON_OBJECT('topic_ocid' VALUE cfg('NOTIFY_TOPIC_OCID'),
                                  'title'      VALUE l_subject);
        ELSIF l_provider IN ('slack', 'msteams') THEN
          l_params := JSON_OBJECT('channel'    VALUE cfg('NOTIFY_CHANNEL'));
        ELSIF l_provider = 'email' THEN
          l_params := JSON_OBJECT('recipient'  VALUE cfg('NOTIFY_EMAIL'),
                                  'subject'    VALUE l_subject);
        ELSE
          RAISE_APPLICATION_ERROR(-20001, 'Unknown NOTIFY_PROVIDER: ' || l_provider);
        END IF;

        EXECUTE IMMEDIATE
          'BEGIN DBMS_CLOUD_NOTIFICATION.SEND_MESSAGE(' ||
          ' provider => :1, credential_name => :2, message => :3, params => :4); END;'
          USING l_provider, l_cred, l_msg, l_params;

      EXCEPTION WHEN OTHERS THEN
        l_status := 'ERROR';
        l_err    := SUBSTR(SQLERRM, 1, 4000);
      END;
    ELSIF l_status = 'SENT' THEN
      l_status := 'LOGGED';
    END IF;

    INSERT INTO mon_notify_log (provider, severity, title, body, status, err)
    VALUES (l_provider, UPPER(p_sev), l_subject, l_msg, l_status, l_err);

    IF l_status = 'ERROR' THEN
      RAISE_APPLICATION_ERROR(-20002, 'Notification failed: ' || l_err);
    END IF;
  END notify;

  --=============================================================== alerting ==--

  PROCEDURE raise_alert (p_key    IN VARCHAR2,
                         p_sev    IN VARCHAR2,
                         p_title  IN VARCHAR2,
                         p_detail IN CLOB) IS
    PRAGMA AUTONOMOUS_TRANSACTION;
    l_id       NUMBER;
    l_notified TIMESTAMP;
    l_cooldown NUMBER := NVL(cfgn('ALERT_COOLDOWN_MIN', 30), 30);
    l_err      VARCHAR2(4000);
  BEGIN
    BEGIN
      SELECT alert_id, notified_at
        INTO l_id, l_notified
        FROM mon_alert
       WHERE alert_key = p_key AND state = 'OPEN'
         FOR UPDATE;

      UPDATE mon_alert
         SET occurrences  = occurrences + 1,
             last_seen_at = SYSTIMESTAMP,
             severity     = UPPER(p_sev),
             title        = SUBSTR(p_title, 1, 400),
             detail       = p_detail
       WHERE alert_id = l_id;

    EXCEPTION WHEN NO_DATA_FOUND THEN
      INSERT INTO mon_alert (alert_key, severity, title, detail)
      VALUES (SUBSTR(p_key, 1, 200), UPPER(p_sev), SUBSTR(p_title, 1, 400), p_detail)
      RETURNING alert_id INTO l_id;
      l_notified := NULL;
    END;

    -- Notify on first sight, then at most once per cooldown window.
    IF l_notified IS NULL
       OR l_notified < SYSTIMESTAMP - NUMTODSINTERVAL(l_cooldown, 'MINUTE') THEN
      BEGIN
        notify(p_sev, p_title, p_detail);
        UPDATE mon_alert
           SET notified_at = SYSTIMESTAMP, notify_error = NULL
         WHERE alert_id = l_id;
      EXCEPTION WHEN OTHERS THEN
        l_err := SUBSTR(SQLERRM, 1, 4000);      -- SQLERRM is not valid inside SQL
        UPDATE mon_alert
           SET notify_error = l_err
         WHERE alert_id = l_id;
      END;
    END IF;

    COMMIT;
  EXCEPTION WHEN OTHERS THEN
    ROLLBACK;
    log_run('raise_alert', 'ERROR', NULL, p_key || ': ' || SQLERRM);
  END raise_alert;

  PROCEDURE clear_alert (p_key IN VARCHAR2) IS
    PRAGMA AUTONOMOUS_TRANSACTION;
    l_rows NUMBER;
    l_ttl  VARCHAR2(400);
  BEGIN
    BEGIN
      SELECT title INTO l_ttl
        FROM mon_alert
       WHERE alert_key = p_key AND state = 'OPEN';
    EXCEPTION WHEN NO_DATA_FOUND THEN
      COMMIT;
      RETURN;                                 -- nothing open, nothing to clear
    END;

    UPDATE mon_alert
       SET state = 'CLOSED', closed_at = SYSTIMESTAMP
     WHERE alert_key = p_key AND state = 'OPEN';
    l_rows := SQL%ROWCOUNT;

    IF l_rows > 0 THEN
      BEGIN
        notify('INFO', 'RESOLVED: ' || l_ttl,
               'The condition behind alert key ' || p_key || ' is no longer present.');
      EXCEPTION WHEN OTHERS THEN
        NULL;                                 -- never let a resolve message fail a job
      END;
    END IF;

    COMMIT;
  EXCEPTION WHEN OTHERS THEN
    ROLLBACK;
    log_run('clear_alert', 'ERROR', NULL, p_key || ': ' || SQLERRM);
  END clear_alert;

  PROCEDURE autoclose_alerts IS
    l_min NUMBER := NVL(cfgn('ALERT_AUTOCLOSE_MIN', 60), 60);
  BEGIN
    FOR r IN (SELECT alert_key
                FROM mon_alert
               WHERE state = 'OPEN'
                 AND last_seen_at < SYSTIMESTAMP - NUMTODSINTERVAL(l_min, 'MINUTE')) LOOP
      clear_alert(r.alert_key);
    END LOOP;
  END autoclose_alerts;

  --=================================================== collector dispatching ==--

  FUNCTION collectors RETURN t_colls IS
    l t_colls;
    i PLS_INTEGER := 0;

    PROCEDURE add (p_tag VARCHAR2, p_stmt VARCHAR2) IS
    BEGIN
      i := i + 1;
      l(i).tag  := p_tag;
      l(i).stmt := p_stmt;
    END;
  BEGIN
    add('SYSMETRIC',      REPLACE(c_sql_sysmetric, '%VIEW%', 'v$sysmetric'));
    add('SYSMETRIC_CON',  REPLACE(c_sql_sysmetric, '%VIEW%', 'v$con_sysmetric'));
    add('RSRC_GROUPS',    c_sql_rsrc);
    add('STORAGE',        c_sql_storage);
    add('RESOURCE_LIMIT', c_sql_limits);
    add('CPU_COUNT',      c_sql_cpucount);
    add('RTSM_LONG',      REPLACE(REPLACE(c_sql_rtsm,
                            '%SLOWSEC%', num_lit('SLOW_SQL_SEC', 300)),
                            '%EXCL%',    list_lit('SQL_EXCLUDE_USERS')));
    add('ASH_TOP_SQL',    REPLACE(REPLACE(c_sql_ash,
                            '%MINSAMPLES%', num_lit('SLOW_SQL_ASH_SAMPLES', 30)),
                            '%EXCL%',       list_lit('SQL_EXCLUDE_USERS')));
    add('SQL_REGRESSION', REPLACE(REPLACE(c_sql_regress,
                            '%MINEXECS%', num_lit('SLOW_SQL_MIN_EXECS', 10)),
                            '%FACTOR%',   num_lit('REGRESSION_FACTOR', 2)));
    RETURN l;
  END collectors;

  FUNCTION stmt_of (p_tag VARCHAR2) RETURN VARCHAR2 IS
    l t_colls := collectors;
  BEGIN
    FOR j IN 1 .. l.COUNT LOOP
      IF l(j).tag = p_tag THEN
        RETURN l(j).stmt;
      END IF;
    END LOOP;
    RETURN NULL;
  END stmt_of;

  -- Runs one collector. Returns rows inserted, or -1 when the collector is not
  -- usable here (missing view, missing grant, unsupported column).
  FUNCTION run_dml (p_tag VARCHAR2) RETURN NUMBER IS
    l_stmt VARCHAR2(32767) := stmt_of(p_tag);
    l_n    NUMBER;
  BEGIN
    IF l_stmt IS NULL THEN
      RETURN -1;
    END IF;
    EXECUTE IMMEDIATE l_stmt;
    l_n := SQL%ROWCOUNT;
    RETURN l_n;
  EXCEPTION WHEN OTHERS THEN
    log_run('collect:' || p_tag, 'WARN', NULL, SQLERRM);
    RETURN -1;
  END run_dml;

  PROCEDURE validate_sql IS
    l     t_colls := collectors;
    l_c   INTEGER;
    l_ok  PLS_INTEGER := 0;
    l_bad PLS_INTEGER := 0;
  BEGIN
    DBMS_OUTPUT.PUT_LINE('Collector statements parsed against the live dictionary:');
    DBMS_OUTPUT.PUT_LINE(RPAD('-', 76, '-'));

    FOR j IN 1 .. l.COUNT LOOP
      l_c := DBMS_SQL.OPEN_CURSOR;
      BEGIN
        DBMS_SQL.PARSE(l_c, l(j).stmt, DBMS_SQL.NATIVE);
        DBMS_OUTPUT.PUT_LINE('  ' || RPAD(l(j).tag, 20) || 'PARSE OK');
        l_ok := l_ok + 1;
      EXCEPTION WHEN OTHERS THEN
        l_bad := l_bad + 1;
        DBMS_OUTPUT.PUT_LINE('  ' || RPAD(l(j).tag, 20) ||
          CASE WHEN SQLCODE IN (-942, -1031) THEN 'UNAVAILABLE  ' ELSE 'SYNTAX ERROR ' END ||
          SUBSTR(SQLERRM, 1, 90));
      END;
      IF DBMS_SQL.IS_OPEN(l_c) THEN
        DBMS_SQL.CLOSE_CURSOR(l_c);
      END IF;
    END LOOP;

    DBMS_OUTPUT.PUT_LINE(RPAD('-', 76, '-'));
    DBMS_OUTPUT.PUT_LINE('  parsed OK: ' || l_ok || '    not usable here: ' || l_bad);
    DBMS_OUTPUT.PUT_LINE('  ORA-00942 and ORA-01031 mean the view is absent or not granted,');
    DBMS_OUTPUT.PUT_LINE('  which disables only that collector. Anything else is a defect.');
  END validate_sql;

  FUNCTION syntax_errors RETURN PLS_INTEGER IS
    l    t_colls := collectors;
    l_c  INTEGER;
    l_n  PLS_INTEGER := 0;
  BEGIN
    FOR j IN 1 .. l.COUNT LOOP
      l_c := DBMS_SQL.OPEN_CURSOR;
      BEGIN
        DBMS_SQL.PARSE(l_c, l(j).stmt, DBMS_SQL.NATIVE);
      EXCEPTION WHEN OTHERS THEN
        IF SQLCODE NOT IN (-942, -1031) THEN
          l_n := l_n + 1;
          log_run('validate:' || l(j).tag, 'ERROR', NULL, SQLERRM);
        END IF;
      END;
      IF DBMS_SQL.IS_OPEN(l_c) THEN
        DBMS_SQL.CLOSE_CURSOR(l_c);
      END IF;
    END LOOP;
    RETURN l_n;
  END syntax_errors;

  --==================================================== resource consumption ==--

  PROCEDURE evaluate_resource IS
    l_aas    NUMBER;
    l_cpu    NUMBER;
    l_pct    NUMBER;
    l_detail VARCHAR2(4000);
  BEGIN
    ------------------------------------------------ CPU pressure, felt by users
    SELECT AVG(CASE WHEN metric_name = 'Average Active Sessions' THEN metric_value END),
           MAX(CASE WHEN metric_name = 'cpu_count'               THEN metric_value END)
      INTO l_aas, l_cpu
      FROM mon_metric
     WHERE metric_group = 'SYS'
       AND collected_at > SYSTIMESTAMP - INTERVAL '5' MINUTE;

    IF l_aas IS NOT NULL AND NVL(l_cpu, 0) > 0 THEN
      IF l_aas / l_cpu > NVL(cfgn('AAS_PER_CPU_WARN', 1.5), 1.5) THEN
        SELECT LISTAGG(dim1 || '=' || ROUND(metric_value, 1), ', ')
                 WITHIN GROUP (ORDER BY dim1)
          INTO l_detail
          FROM mon_metric
         WHERE metric_group = 'RSRC'
           AND metric_name  = 'active_sessions'
           AND collected_at > SYSTIMESTAMP - INTERVAL '2' MINUTE;

        raise_alert('RES_AAS', 'WARNING',
          'CPU bound: ' || ROUND(l_aas, 1) || ' average active sessions on ' ||
          TO_CHAR(l_cpu) || ' CPUs',
          'Sustained demand exceeds the CPU allocated to this database.' || CHR(10) ||
          'Active sessions by consumer group: ' || NVL(l_detail, 'n/a') || CHR(10) ||
          'Next step: look at V_MON_TOP_SQL_24H for the same window, then choose' || CHR(10) ||
          'between tuning that SQL, moving batch work to LOW, or adding ECPUs.');
      ELSE
        clear_alert('RES_AAS');
      END IF;
    END IF;

    -------------------------------------------------------- statement queueing
    FOR r IN (SELECT dim1 AS grp, MAX(metric_value) AS q
                FROM mon_metric
               WHERE metric_group = 'RSRC'
                 AND metric_name  = 'queue_length'
                 AND collected_at > SYSTIMESTAMP - INTERVAL '5' MINUTE
               GROUP BY dim1) LOOP
      IF r.q > NVL(cfgn('QUEUE_LEN_WARN', 5), 5) THEN
        raise_alert('RES_QUEUE_' || r.grp, 'WARNING',
          'Statements queuing in ' || r.grp || ' (peak ' || r.q || ')',
          'Sessions are waiting for a concurrency slot in consumer group ' ||
          r.grp || '.' || CHR(10) ||
          'This is the earliest signal that a service is undersized for its' || CHR(10) ||
          'workload. Options: move reporting to LOW, enable compute autoscaling,' || CHR(10) ||
          'raise the ECPU count, or tune the top SQL running on this service.');
      ELSE
        clear_alert('RES_QUEUE_' || r.grp);
      END IF;
    END LOOP;

    ------------------------------------------------------------------ storage
    FOR r IN (SELECT dim1 AS tbs, MAX(metric_value) AS pct
                FROM mon_metric
               WHERE metric_group = 'STORAGE'
                 AND collected_at > SYSTIMESTAMP - INTERVAL '15' MINUTE
               GROUP BY dim1) LOOP
      IF r.pct > NVL(cfgn('TBS_PCT_WARN', 85), 85) THEN
        raise_alert('RES_TBS_' || r.tbs,
          CASE WHEN r.pct > NVL(cfgn('TBS_PCT_CRIT', 92), 92)
               THEN 'CRITICAL' ELSE 'WARNING' END,
          'Tablespace ' || r.tbs || ' at ' || ROUND(r.pct, 1) || '% used',
          'Check V_MON_STORAGE_FORECAST for the growth trend and the projected' || CHR(10) ||
          'date it fills. Scale storage, or find the segment that is growing.');
      ELSE
        clear_alert('RES_TBS_' || r.tbs);
      END IF;
    END LOOP;

    ------------------------------------------------------- session saturation
    -- V$RESOURCE_LIMIT is frequently empty inside a PDB, so the same condition
    -- is also watched through the Session Limit % system metric. Separate alert
    -- keys, so the two sources cannot flap against each other.
    SELECT MAX(metric_value)
      INTO l_pct
      FROM mon_metric
     WHERE metric_group = 'SYS'
       AND metric_name  = 'Session Limit %'
       AND collected_at > SYSTIMESTAMP - INTERVAL '5' MINUTE;

    IF l_pct IS NOT NULL THEN
      IF l_pct > NVL(cfgn('SESSION_PCT_WARN', 85), 85) THEN
        raise_alert('RES_SESSION_LIMIT', 'WARNING',
          'Session limit at ' || ROUND(l_pct, 1) || '% of the service maximum',
          'New connections are refused once this reaches 100%. On Autonomous' || CHR(10) ||
          'Database the ceiling scales with ECPU count, so this is usually a' || CHR(10) ||
          'connection pool that is not returning sessions rather than real demand.');
      ELSE
        clear_alert('RES_SESSION_LIMIT');
      END IF;
    END IF;

    ----------------------------------------------------- sessions / processes
    FOR r IN (SELECT dim1 AS res, MAX(metric_value) AS pct
                FROM mon_metric
               WHERE metric_group = 'LIMIT'
                 AND collected_at > SYSTIMESTAMP - INTERVAL '5' MINUTE
               GROUP BY dim1) LOOP
      IF r.pct > NVL(cfgn('SESSION_PCT_WARN', 85), 85) THEN
        raise_alert('RES_LIMIT_' || r.res, 'WARNING',
          UPPER(r.res) || ' utilisation at ' || ROUND(r.pct, 1) || '%',
          'Approaching the limit for ' || r.res || '. New connections start' || CHR(10) ||
          'failing once it is reached. Check for a connection pool leaking' || CHR(10) ||
          'sessions before raising the limit.');
      ELSE
        clear_alert('RES_LIMIT_' || r.res);
      END IF;
    END LOOP;
  END evaluate_resource;

  PROCEDURE collect_resource IS
    l_t0     NUMBER := DBMS_UTILITY.GET_TIME;
    l_reason VARCHAR2(400) := inactive_reason;
    l_n      NUMBER;
  BEGIN
    IF l_reason IS NOT NULL THEN
      log_run('collect_resource', 'SKIP', NULL, l_reason);
      RETURN;
    END IF;

    demote;

    l_n := run_dml('SYSMETRIC');
    IF l_n <= 0 THEN
      l_n := run_dml('SYSMETRIC_CON');          -- PDB scoped fallback
    END IF;

    l_n := run_dml('RSRC_GROUPS');
    l_n := run_dml('STORAGE');
    l_n := run_dml('RESOURCE_LIMIT');
    l_n := run_dml('CPU_COUNT');
    COMMIT;

    evaluate_resource;

    log_run('collect_resource', 'OK', (DBMS_UTILITY.GET_TIME - l_t0) * 10);
  EXCEPTION WHEN OTHERS THEN
    ROLLBACK;
    log_run('collect_resource', 'ERROR', (DBMS_UTILITY.GET_TIME - l_t0) * 10, SQLERRM);
  END collect_resource;

  --=============================================================== slow SQL ==--

  PROCEDURE evaluate_slow_sql IS
    l_cur      SYS_REFCURSOR;
    l_sql_id   VARCHAR2(13);
    l_new_plan NUMBER;
    l_new_sec  NUMBER;
    l_old_plan NUMBER;
    l_old_sec  NUMBER;
    l_execs    NUMBER;
    l_stmt     VARCHAR2(32767);
  BEGIN
    ----------------------------------------------- statements running too long
    FOR r IN (SELECT sql_id,
                     MAX(elapsed_sec)              AS secs,
                     MAX(username)                 AS usr,
                     MAX(module)                   AS mdl,
                     MAX(SUBSTR(sql_text, 1, 400)) AS txt
                FROM mon_sql_slow
               WHERE source = 'RTSM'
                 AND captured_at > SYSTIMESTAMP - INTERVAL '10' MINUTE
                 AND sql_id IS NOT NULL
               GROUP BY sql_id) LOOP
      raise_alert('SQL_LONG_' || r.sql_id, 'WARNING',
        'Long running SQL ' || r.sql_id || ' (' || ROUND(r.secs / 60, 1) || ' min)',
        'User   : ' || NVL(r.usr, 'n/a') || CHR(10) ||
        'Module : ' || NVL(r.mdl, 'n/a') || CHR(10) ||
        'SQL    : ' || NVL(r.txt, 'n/a') || CHR(10) || CHR(10) ||
        'Execution plan and activity breakdown:' || CHR(10) ||
        '  SELECT DBMS_SQL_MONITOR.REPORT_SQL_MONITOR(sql_id => ''' ||
        r.sql_id || ''', type => ''TEXT'') FROM dual;');
    END LOOP;

    ----------------------------------------------------------- plan regression
    l_stmt := stmt_of('SQL_REGRESSION');
    BEGIN
      OPEN l_cur FOR l_stmt;
      LOOP
        FETCH l_cur INTO l_sql_id, l_new_plan, l_new_sec, l_old_plan, l_old_sec, l_execs;
        EXIT WHEN l_cur%NOTFOUND;

        raise_alert('SQL_REGRESS_' || l_sql_id, 'WARNING',
          'Plan regression on ' || l_sql_id || ': ' ||
          l_old_sec || 's to ' || l_new_sec || 's per execution',
          'Previous plan : ' || l_old_plan || '   avg ' || l_old_sec || ' s' || CHR(10) ||
          'Current plan  : ' || l_new_plan || '   avg ' || l_new_sec || ' s over ' ||
          l_execs || ' executions' || CHR(10) || CHR(10) ||
          'Most "the database got slow overnight" reports are exactly this.' || CHR(10) ||
          'To pin the previous plan while you investigate, load it from AWR' || CHR(10) ||
          'with DBMS_SPM.LOAD_PLANS_FROM_AWR for sql_id ' || l_sql_id || '.');
      END LOOP;
      CLOSE l_cur;
    EXCEPTION WHEN OTHERS THEN
      IF l_cur%ISOPEN THEN
        CLOSE l_cur;
      END IF;
      log_run('collect:SQL_REGRESSION', 'WARN', NULL, SQLERRM);
    END;
  END evaluate_slow_sql;

  PROCEDURE collect_slow_sql IS
    l_t0     NUMBER := DBMS_UTILITY.GET_TIME;
    l_reason VARCHAR2(400) := inactive_reason;
    l_n      NUMBER;
  BEGIN
    IF l_reason IS NOT NULL THEN
      log_run('collect_slow_sql', 'SKIP', NULL, l_reason);
      RETURN;
    END IF;

    demote;

    l_n := run_dml('RTSM_LONG');
    l_n := run_dml('ASH_TOP_SQL');
    COMMIT;

    evaluate_slow_sql;

    log_run('collect_slow_sql', 'OK', (DBMS_UTILITY.GET_TIME - l_t0) * 10);
  EXCEPTION WHEN OTHERS THEN
    ROLLBACK;
    log_run('collect_slow_sql', 'ERROR', (DBMS_UTILITY.GET_TIME - l_t0) * 10, SQLERRM);
  END collect_slow_sql;

  --================================================================= digest ==--

  PROCEDURE check_storage_forecast IS
    l_days_warn NUMBER := NVL(cfgn('STORAGE_DAYS_TO_FULL_WARN', 14), 14);
  BEGIN
    FOR r IN (SELECT tablespace_name, current_pct, pct_per_day, days_to_full
                FROM v_mon_storage_forecast
               WHERE days_to_full IS NOT NULL) LOOP
      IF r.days_to_full <= l_days_warn THEN
        raise_alert('STORAGE_FORECAST_' || r.tablespace_name, 'WARNING',
          'Tablespace ' || r.tablespace_name || ' projected full in ' ||
          ROUND(r.days_to_full) || ' days',
          'Growing at ' || ROUND(r.pct_per_day, 3) || ' percent per day, currently ' ||
          ROUND(r.current_pct, 1) || '% used.' || CHR(10) ||
          'A trend alert leaves time to act; a threshold alert usually does not.');
      ELSE
        clear_alert('STORAGE_FORECAST_' || r.tablespace_name);
      END IF;
    END LOOP;
  EXCEPTION WHEN OTHERS THEN
    log_run('check_storage_forecast', 'WARN', NULL, SQLERRM);
  END check_storage_forecast;

  PROCEDURE daily_digest IS
    l_t0     NUMBER := DBMS_UTILITY.GET_TIME;
    l_reason VARCHAR2(400) := inactive_reason;
    l_body   VARCHAR2(32767);
    l_line   VARCHAR2(4000);
  BEGIN
    IF l_reason IS NOT NULL THEN
      log_run('daily_digest', 'SKIP', NULL, l_reason);
      RETURN;
    END IF;

    demote;
    check_storage_forecast;

    l_body := 'Daily summary for ' || db_name || ' - ' ||
              TO_CHAR(SYSDATE, 'YYYY-MM-DD') || CHR(10) ||
              RPAD('=', 60, '=') || CHR(10) || CHR(10);

    --------------------------------------------------------------- alert recap
    l_body := l_body || 'ALERTS IN THE LAST 24 HOURS' || CHR(10);
    FOR r IN (SELECT severity, title, occurrences, state
                FROM mon_alert
               WHERE last_seen_at > SYSTIMESTAMP - INTERVAL '1' DAY
               ORDER BY DECODE(severity, 'CRITICAL', 1, 'WARNING', 2, 3), last_seen_at DESC
               FETCH FIRST 15 ROWS ONLY) LOOP
      l_body := l_body || '  ' || RPAD(r.severity, 9) || RPAD(r.state, 8) ||
                'x' || RPAD(TO_CHAR(r.occurrences), 5) ||
                SUBSTR(r.title, 1, 90) || CHR(10);
    END LOOP;

    ----------------------------------------------------------- top SQL by time
    l_body := l_body || CHR(10) || 'TOP SQL BY DATABASE TIME (24h, ASH samples)' || CHR(10);
    FOR r IN (SELECT sql_id,
                     SUM(elapsed_sec)            AS secs,
                     MAX(username)               AS usr,
                     MAX(top_event)              AS ev,
                     MAX(SUBSTR(sql_text, 1, 70)) AS txt
                FROM mon_sql_slow
               WHERE source = 'ASH'
                 AND captured_at > SYSTIMESTAMP - INTERVAL '1' DAY
               GROUP BY sql_id
               ORDER BY SUM(elapsed_sec) DESC
               FETCH FIRST 10 ROWS ONLY) LOOP
      l_body := l_body || '  ' || RPAD(r.sql_id, 15) ||
                LPAD(TO_CHAR(ROUND(r.secs)), 8) || 's  ' ||
                RPAD(NVL(r.usr, '?'), 14) || RPAD(NVL(r.ev, ' '), 22) ||
                NVL(r.txt, ' ') || CHR(10);
    END LOOP;

    ------------------------------------------------------------------ capacity
    l_body := l_body || CHR(10) || 'CAPACITY' || CHR(10);
    FOR r IN (SELECT tablespace_name, current_pct, days_to_full
                FROM v_mon_storage_forecast) LOOP
      l_body := l_body || '  ' || RPAD(r.tablespace_name, 24) ||
                LPAD(TO_CHAR(ROUND(r.current_pct, 1)), 6) || '% used, ' ||
                CASE WHEN r.days_to_full IS NULL
                     THEN 'no growth trend'
                     ELSE 'full in about ' || ROUND(r.days_to_full) || ' days' END || CHR(10);
    END LOOP;

    BEGIN
      SELECT '  peak active sessions ' || ROUND(MAX(metric_value), 1) ||
             ', average ' || ROUND(AVG(metric_value), 2)
        INTO l_line
        FROM mon_metric
       WHERE metric_name = 'Average Active Sessions'
         AND collected_at > SYSTIMESTAMP - INTERVAL '1' DAY;
      l_body := l_body || l_line || CHR(10);
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;

    -------------------------------------------------------------- backup state
    l_body := l_body || CHR(10) || 'BACKUPS (5 most recent known to the OCI API)' || CHR(10);
    FOR r IN (SELECT display_name, backup_type, lifecycle_state, time_ended, time_started
                FROM mon_backup
               ORDER BY NVL(time_ended, time_started) DESC
               FETCH FIRST 5 ROWS ONLY) LOOP
      l_body := l_body || '  ' || RPAD(NVL(r.lifecycle_state, '?'), 10) ||
                RPAD(NVL(r.backup_type, '?'), 14) ||
                NVL(TO_CHAR(r.time_ended, 'YYYY-MM-DD HH24:MI'), 'not finished') || '  ' ||
                SUBSTR(NVL(r.display_name, ' '), 1, 50) || CHR(10);
    END LOOP;

    ------------------------------------------------------------ pack self check
    BEGIN
      SELECT '  collector errors in 24h: ' || COUNT(*)
        INTO l_line
        FROM mon_job_log
       WHERE run_at > SYSTIMESTAMP - INTERVAL '1' DAY
         AND status IN ('ERROR', 'WARN');
      l_body := l_body || CHR(10) || 'MONITORING HEALTH' || CHR(10) || l_line || CHR(10);
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;

    notify('INFO', 'Daily database summary', l_body);
    autoclose_alerts;

    log_run('daily_digest', 'OK', (DBMS_UTILITY.GET_TIME - l_t0) * 10);
  EXCEPTION WHEN OTHERS THEN
    log_run('daily_digest', 'ERROR', (DBMS_UTILITY.GET_TIME - l_t0) * 10, SQLERRM);
  END daily_digest;

  --================================================================== purge ==--

  PROCEDURE purge (p_metric_days IN NUMBER DEFAULT NULL,
                   p_sql_days    IN NUMBER DEFAULT NULL,
                   p_alert_days  IN NUMBER DEFAULT NULL,
                   p_job_days    IN NUMBER DEFAULT NULL) IS
    l_t0 NUMBER := DBMS_UTILITY.GET_TIME;
    l_m  NUMBER := NVL(p_metric_days, NVL(cfgn('RETAIN_METRIC_DAYS', 35), 35));
    l_s  NUMBER := NVL(p_sql_days,    NVL(cfgn('RETAIN_SQL_DAYS', 90), 90));
    l_a  NUMBER := NVL(p_alert_days,  NVL(cfgn('RETAIN_ALERT_DAYS', 180), 180));
    l_j  NUMBER := NVL(p_job_days,    NVL(cfgn('RETAIN_JOBLOG_DAYS', 14), 14));
  BEGIN
    DELETE FROM mon_metric     WHERE collected_at < SYSTIMESTAMP - NUMTODSINTERVAL(l_m, 'DAY');
    COMMIT;
    DELETE FROM mon_sql_slow   WHERE captured_at  < SYSTIMESTAMP - NUMTODSINTERVAL(l_s, 'DAY');
    COMMIT;
    DELETE FROM mon_alert      WHERE state = 'CLOSED'
                                 AND closed_at    < SYSTIMESTAMP - NUMTODSINTERVAL(l_a, 'DAY');
    COMMIT;
    DELETE FROM mon_notify_log WHERE sent_at      < SYSTIMESTAMP - NUMTODSINTERVAL(l_a, 'DAY');
    COMMIT;
    DELETE FROM mon_job_log    WHERE run_at       < SYSTIMESTAMP - NUMTODSINTERVAL(l_j, 'DAY');
    COMMIT;
    DELETE FROM mon_backup     WHERE last_seen_at < SYSTIMESTAMP - NUMTODSINTERVAL(l_a, 'DAY');
    COMMIT;

    log_run('purge', 'OK', (DBMS_UTILITY.GET_TIME - l_t0) * 10);
  EXCEPTION WHEN OTHERS THEN
    log_run('purge', 'ERROR', (DBMS_UTILITY.GET_TIME - l_t0) * 10, SQLERRM);
  END purge;

  --============================================================== self test ==--

  PROCEDURE self_test IS
    l_n NUMBER;
  BEGIN
    DBMS_OUTPUT.PUT_LINE('pkg_mon ' || c_version);
    DBMS_OUTPUT.PUT_LINE('  database    : ' || NVL(db_name, '?'));
    DBMS_OUTPUT.PUT_LINE('  ocid        : ' || NVL(db_ocid, 'unknown (not an ADB?)'));
    DBMS_OUTPUT.PUT_LINE('  region      : ' || NVL(db_region, 'unknown'));
    DBMS_OUTPUT.PUT_LINE('  active      : ' || is_active ||
                         CASE WHEN is_active = 'N'
                              THEN '   reason: ' || inactive_reason END);
    DBMS_OUTPUT.PUT_LINE('  notify via  : ' || cfg('NOTIFY_PROVIDER', 'log'));

    SELECT COUNT(*) INTO l_n FROM mon_alert WHERE state = 'OPEN';
    DBMS_OUTPUT.PUT_LINE('  open alerts : ' || l_n);

    SELECT COUNT(*) INTO l_n FROM mon_metric
     WHERE collected_at > SYSTIMESTAMP - INTERVAL '10' MINUTE;
    DBMS_OUTPUT.PUT_LINE('  metrics/10m : ' || l_n);

    SELECT COUNT(*) INTO l_n FROM mon_job_log
     WHERE run_at > SYSTIMESTAMP - INTERVAL '1' DAY AND status IN ('ERROR', 'WARN');
    DBMS_OUTPUT.PUT_LINE('  job errors  : ' || l_n || ' in the last 24h');
  END self_test;

END pkg_mon;
/
SHOW ERRORS
