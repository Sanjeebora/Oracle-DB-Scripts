--------------------------------------------------------------------------------
-- 05_pkg_mon_spec.sql
--
-- Run as DBMON. Core monitoring package: configuration, alerting, resource
-- consumption, and slow SQL.
--
-- This package deliberately has no compile-time dependency on DBMS_CLOUD or on
-- any V$ view. Every dictionary query runs through dynamic SQL so that a missing
-- grant disables one collector at runtime instead of invalidating the package.
-- Use pkg_mon.validate_sql to find out which collectors work on this instance.
--------------------------------------------------------------------------------
SET DEFINE OFF

CREATE OR REPLACE PACKAGE pkg_mon AUTHID DEFINER AS

  c_version CONSTANT VARCHAR2(10) := '1.0.0';

  ---------------------------------------------------------------- configuration
  FUNCTION  cfg     (p_key IN VARCHAR2, p_def IN VARCHAR2 DEFAULT NULL) RETURN VARCHAR2;
  FUNCTION  cfgn    (p_key IN VARCHAR2, p_def IN NUMBER   DEFAULT NULL) RETURN NUMBER;
  PROCEDURE set_cfg (p_key IN VARCHAR2, p_value IN VARCHAR2);

  -------------------------------------------------------------------- identity
  FUNCTION db_ocid      RETURN VARCHAR2;
  FUNCTION db_region    RETURN VARCHAR2;
  FUNCTION db_name      RETURN VARCHAR2;
  FUNCTION compartment  RETURN VARCHAR2;
  FUNCTION console_url  RETURN VARCHAR2;

  -- 'Y' when collectors may run: pack enabled and this is not a clone.
  FUNCTION is_active    RETURN VARCHAR2;
  FUNCTION inactive_reason RETURN VARCHAR2;

  -- Identity is resolved once per session and cached. Call this after changing
  -- the DB_OCID / REGION overrides, or after a clone operation, to re-resolve.
  PROCEDURE reset_identity;

  -------------------------------------------------------------------- alerting
  PROCEDURE notify      (p_sev   IN VARCHAR2,
                         p_title IN VARCHAR2,
                         p_body  IN CLOB);

  PROCEDURE raise_alert (p_key    IN VARCHAR2,
                         p_sev    IN VARCHAR2,
                         p_title  IN VARCHAR2,
                         p_detail IN CLOB);

  PROCEDURE clear_alert (p_key IN VARCHAR2);

  -- Closes alerts nothing has re-raised for ALERT_AUTOCLOSE_MIN minutes.
  PROCEDURE autoclose_alerts;

  ------------------------------------------------------------------ collectors
  PROCEDURE collect_resource;
  PROCEDURE collect_slow_sql;

  -- Threshold evaluation, split out from collection so it can be driven from
  -- fixtures in MON_METRIC / MON_SQL_SLOW during testing.
  PROCEDURE evaluate_resource;
  PROCEDURE evaluate_slow_sql;
  PROCEDURE daily_digest;
  PROCEDURE purge (p_metric_days IN NUMBER DEFAULT NULL,
                   p_sql_days    IN NUMBER DEFAULT NULL,
                   p_alert_days  IN NUMBER DEFAULT NULL,
                   p_job_days    IN NUMBER DEFAULT NULL);

  ----------------------------------------------------------------- diagnostics
  -- Parses every dynamic statement against the live dictionary and prints the
  -- result. Run this after install and after any ADB version upgrade.
  PROCEDURE validate_sql;

  -- Same parse, but returns only the count of genuine syntax errors. A view that
  -- is absent or not granted (ORA-00942, ORA-01031) is not counted, because that
  -- disables a collector rather than indicating a defect. Assert this is 0.
  FUNCTION syntax_errors RETURN PLS_INTEGER;

  -- One-line health summary of the pack itself.
  PROCEDURE self_test;

END pkg_mon;
/
SHOW ERRORS
