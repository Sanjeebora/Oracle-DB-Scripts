--------------------------------------------------------------------------------
-- 04_views.sql
--
-- Run as DBMON. Reporting views. These are what a DBA actually queries day to
-- day; the tables underneath are an implementation detail.
--
-- Created before the packages because PKG_MON reads V_MON_STORAGE_FORECAST.
--------------------------------------------------------------------------------
SET DEFINE OFF

-- Everything currently wrong, worst first.
CREATE OR REPLACE VIEW v_mon_open_alerts AS
SELECT severity,
       alert_key,
       title,
       occurrences,
       first_seen_at,
       last_seen_at,
       notified_at,
       ROUND((CAST(last_seen_at AS DATE) - CAST(first_seen_at AS DATE)) * 24 * 60, 1)
         AS open_minutes,
       notify_error,
       detail
FROM   mon_alert
WHERE  state = 'OPEN'
ORDER  BY DECODE(severity, 'CRITICAL', 1, 'WARNING', 2, 3), last_seen_at DESC;

-- Resource picture for the last hour, one row per metric.
CREATE OR REPLACE VIEW v_mon_resource_1h AS
SELECT metric_group,
       metric_name,
       dim1,
       COUNT(*)                        AS samples,
       ROUND(MIN(metric_value), 2)     AS min_value,
       ROUND(AVG(metric_value), 2)     AS avg_value,
       ROUND(MAX(metric_value), 2)     AS max_value,
       MAX(metric_unit)                AS unit
FROM   mon_metric
WHERE  collected_at > SYSTIMESTAMP - INTERVAL '1' HOUR
GROUP  BY metric_group, metric_name, dim1;

-- Demand versus allocated CPU, per minute. The single most useful chart.
CREATE OR REPLACE VIEW v_mon_cpu_pressure AS
SELECT TRUNC(CAST(collected_at AS DATE), 'MI')  AS minute,
       ROUND(MAX(CASE WHEN metric_name = 'Average Active Sessions'
                      THEN metric_value END), 2) AS avg_active_sessions,
       MAX(CASE WHEN metric_name = 'cpu_count' THEN metric_value END) AS cpu_count,
       ROUND(MAX(CASE WHEN metric_name = 'Average Active Sessions' THEN metric_value END)
             / NULLIF(MAX(CASE WHEN metric_name = 'cpu_count' THEN metric_value END), 0),
             2)                                  AS aas_per_cpu,
       ROUND(MAX(CASE WHEN metric_name = 'Database CPU Time Ratio'
                      THEN metric_value END), 1) AS db_cpu_time_pct,
       ROUND(MAX(CASE WHEN metric_name = 'Database Wait Time Ratio'
                      THEN metric_value END), 1) AS db_wait_time_pct
FROM   mon_metric
WHERE  metric_group = 'SYS'
GROUP  BY TRUNC(CAST(collected_at AS DATE), 'MI');

-- Where the concurrency limits are biting, per consumer group.
CREATE OR REPLACE VIEW v_mon_service_pressure AS
SELECT dim1                                        AS consumer_group,
       ROUND(AVG(CASE WHEN metric_name = 'active_sessions'
                      THEN metric_value END), 2)   AS avg_active_sessions,
       MAX(CASE WHEN metric_name = 'active_sessions' THEN metric_value END)
                                                   AS peak_active_sessions,
       MAX(CASE WHEN metric_name = 'queue_length'   THEN metric_value END)
                                                   AS peak_queue_length,
       ROUND(MAX(CASE WHEN metric_name = 'cpu_wait_time'
                      THEN metric_value END) / 1000, 1) AS cpu_wait_sec
FROM   mon_metric
WHERE  metric_group = 'RSRC'
AND    collected_at > SYSTIMESTAMP - INTERVAL '1' HOUR
GROUP  BY dim1;

-- Top SQL by sampled database time over the last day.
CREATE OR REPLACE VIEW v_mon_top_sql_24h AS
SELECT sql_id,
       MAX(plan_hash)                   AS plan_hash,
       MAX(username)                    AS username,
       MAX(service_name)                AS service_name,
       MAX(module)                      AS module,
       MAX(top_event)                   AS top_wait_event,
       SUM(CASE WHEN source = 'ASH' THEN elapsed_sec END)  AS ash_db_time_sec,
       MAX(CASE WHEN source = 'RTSM' THEN elapsed_sec END) AS longest_run_sec,
       COUNT(DISTINCT plan_hash)        AS distinct_plans,
       MAX(SUBSTR(sql_text, 1, 200))    AS sql_text
FROM   mon_sql_slow
WHERE  captured_at > SYSTIMESTAMP - INTERVAL '1' DAY
GROUP  BY sql_id;

-- Any SQL that has run under more than one plan recently, with the spread.
-- A wide spread between best and worst plan is a plan-stability problem.
CREATE OR REPLACE VIEW v_mon_plan_instability AS
SELECT sql_id,
       COUNT(DISTINCT plan_hash)                 AS plans_seen,
       ROUND(MIN(elapsed_sec), 2)                AS best_sec,
       ROUND(MAX(elapsed_sec), 2)                AS worst_sec,
       ROUND(MAX(elapsed_sec) / NULLIF(MIN(elapsed_sec), 0), 1) AS spread_factor,
       MAX(SUBSTR(sql_text, 1, 120))             AS sql_text
FROM   mon_sql_slow
WHERE  captured_at > SYSTIMESTAMP - INTERVAL '7' DAY
AND    plan_hash IS NOT NULL
AND    elapsed_sec > 0
GROUP  BY sql_id
HAVING COUNT(DISTINCT plan_hash) > 1;

-- Linear growth trend per tablespace and the projected date it fills.
-- Needs a few days of history before the projection means anything.
CREATE OR REPLACE VIEW v_mon_storage_forecast AS
SELECT tablespace_name,
       current_pct,
       samples,
       pct_per_day,
       CASE WHEN pct_per_day > 0.001
            THEN (100 - current_pct) / pct_per_day
       END                                                     AS days_to_full,
       CASE WHEN pct_per_day > 0.001
            THEN SYSDATE + (100 - current_pct) / pct_per_day
       END                                                     AS projected_full_date
FROM (
  SELECT dim1                                                  AS tablespace_name,
         COUNT(*)                                              AS samples,
         MAX(metric_value) KEEP (DENSE_RANK LAST ORDER BY collected_at) AS current_pct,
         ROUND(REGR_SLOPE(metric_value,
                          CAST(collected_at AS DATE) - DATE '2000-01-01'), 4) AS pct_per_day
  FROM   mon_metric
  WHERE  metric_group = 'STORAGE'
  AND    collected_at > SYSTIMESTAMP - INTERVAL '30' DAY
  GROUP  BY dim1
);

-- Backup posture at a glance. Age is what matters, not the last row's status.
CREATE OR REPLACE VIEW v_mon_backup_status AS
SELECT backup_id,
       display_name,
       backup_type,
       is_automatic,
       lifecycle_state,
       time_started,
       time_ended,
       is_restorable,
       ROUND((CAST(SYSTIMESTAMP AS DATE) - CAST(NVL(time_ended, time_started) AS DATE)) * 24, 1)
         AS age_hours,
       lifecycle_details
FROM   mon_backup;

CREATE OR REPLACE VIEW v_mon_backup_summary AS
SELECT (SELECT COUNT(*) FROM mon_backup)                                AS backups_known,
       (SELECT COUNT(*) FROM mon_backup WHERE lifecycle_state = 'FAILED')
                                                                        AS failed_total,
       (SELECT COUNT(*) FROM mon_backup
         WHERE lifecycle_state = 'FAILED'
           AND NVL(time_ended, time_started) > SYSTIMESTAMP - INTERVAL '7' DAY)
                                                                        AS failed_last_7d,
       (SELECT MAX(NVL(time_ended, time_started)) FROM mon_backup
         WHERE lifecycle_state = 'ACTIVE')                              AS last_good_backup,
       (SELECT ROUND((CAST(SYSTIMESTAMP AS DATE) -
                      CAST(MAX(NVL(time_ended, time_started)) AS DATE)) * 24, 1)
          FROM mon_backup WHERE lifecycle_state = 'ACTIVE')             AS hours_since_good
FROM   dual;

-- Is the monitoring itself healthy? Check this before trusting silence.
CREATE OR REPLACE VIEW v_mon_health AS
SELECT proc_name,
       COUNT(*)                                                  AS runs_24h,
       SUM(CASE WHEN status = 'OK'    THEN 1 ELSE 0 END)         AS ok_runs,
       SUM(CASE WHEN status = 'WARN'  THEN 1 ELSE 0 END)         AS warn_runs,
       SUM(CASE WHEN status = 'ERROR' THEN 1 ELSE 0 END)         AS error_runs,
       SUM(CASE WHEN status = 'SKIP'  THEN 1 ELSE 0 END)         AS skipped_runs,
       ROUND(AVG(ms_elapsed), 1)                                 AS avg_ms,
       MAX(ms_elapsed)                                           AS max_ms,
       MAX(run_at)                                               AS last_run,
       MAX(CASE WHEN status IN ('ERROR', 'WARN') THEN SUBSTR(err, 1, 200) END) AS last_error
FROM   mon_job_log
WHERE  run_at > SYSTIMESTAMP - INTERVAL '1' DAY
GROUP  BY proc_name;

PROMPT
PROMPT --- Views created
SELECT view_name FROM user_views WHERE view_name LIKE 'V!_MON!_%' ESCAPE '!' ORDER BY 1;
