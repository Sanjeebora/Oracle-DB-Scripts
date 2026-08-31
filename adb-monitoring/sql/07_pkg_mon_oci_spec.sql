--------------------------------------------------------------------------------
-- 07_pkg_mon_oci_spec.sql
--
-- Run as DBMON. Everything that talks to the OCI control plane:
-- backup status and custom metric publishing.
--
-- Kept separate from PKG_MON on purpose. This package has a hard dependency on
-- DBMS_CLOUD, so if the EXECUTE grant or the resource principal is missing, only
-- the backup checks stop working. Resource and slow SQL monitoring carry on.
--
-- Why backups are monitored through a REST call rather than RMAN views:
-- on Autonomous Database Serverless the automatic backups are taken by the
-- service in the control plane. V$RMAN_STATUS and DBA_RMAN_BACKUP_JOB_DETAILS
-- are not populated for them, so the OCI Database API is the only in-database
-- way to see whether last night's backup actually succeeded.
--------------------------------------------------------------------------------
SET DEFINE OFF

CREATE OR REPLACE PACKAGE pkg_mon_oci AUTHID DEFINER AS

  c_version CONSTANT VARCHAR2(10) := '1.0.0';

  ------------------------------------------------------------------- helpers --
  -- Declared in the spec rather than the body because both are called from
  -- inside SQL statements, and PL/SQL only allows that for public functions.

  -- ISO 8601 from the OCI API to a real timestamp, with or without milliseconds.
  FUNCTION iso_ts   (p_txt  IN VARCHAR2) RETURN TIMESTAMP WITH TIME ZONE;

  -- OCI list endpoints return a bare JSON array; some return {"items":[...]}.
  -- Normalises so callers can always assume an array.
  FUNCTION as_array (p_json IN CLOB) RETURN CLOB;

  ------------------------------------------------------------------ retrieval --
  -- Raw responses, separated from parsing so the parsing can be unit tested
  -- offline with a captured payload.
  FUNCTION fetch_backups_json RETURN CLOB;
  FUNCTION fetch_database_json RETURN CLOB;

  ------------------------------------------------------------------- loading --
  -- Both accept a payload from anywhere: the live API, or a fixture in a test.
  PROCEDURE load_backups     (p_json IN CLOB);
  PROCEDURE load_db_details  (p_json IN CLOB);

  ----------------------------------------------------------------- evaluation --
  -- Reads MON_BACKUP only. Safe to run against loaded fixtures.
  PROCEDURE evaluate_backups;

  ---------------------------------------------------------------- orchestration --
  PROCEDURE check_backups;

  ------------------------------------------------------------ custom metrics --
  -- Publishes one datapoint to OCI Monitoring so you can alarm on in-database
  -- signals next to the service metrics.
  PROCEDURE publish_metric (p_name  IN VARCHAR2,
                            p_value IN NUMBER,
                            p_unit  IN VARCHAR2 DEFAULT NULL);

  -- Publishes MonitorHeartbeat plus a few headline values. Pair this with an
  -- OCI alarm on absence: it is the only way to be told the monitoring stopped.
  PROCEDURE publish_heartbeat;

  ----------------------------------------------------------------- diagnostics --
  PROCEDURE self_test;

END pkg_mon_oci;
/
SHOW ERRORS
