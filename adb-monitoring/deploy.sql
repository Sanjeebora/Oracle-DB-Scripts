--------------------------------------------------------------------------------
-- deploy.sql
--
-- Installs the monitoring pack. Run as DBMON, after 01_admin_setup.sql has been
-- run as ADMIN.
--
--     sqlplus -L dbmon/<pw>@<tns_alias> @deploy.sql
--
-- Re-runnable. Tables and configuration keys that already exist are left alone,
-- so your tuned thresholds survive an upgrade; packages, views and jobs are
-- replaced.
--------------------------------------------------------------------------------
SET SERVEROUTPUT ON SIZE UNLIMITED
SET LINESIZE 200
SET DEFINE OFF
WHENEVER SQLERROR EXIT FAILURE

PROMPT
PROMPT ================================================================
PROMPT  Installing the ADB monitoring pack
PROMPT ================================================================

PROMPT
PROMPT [1/7] Repository tables
@@sql/02_tables.sql

PROMPT
PROMPT [2/7] Default configuration
@@sql/03_config_seed.sql

PROMPT
PROMPT [3/7] Reporting views
@@sql/04_views.sql

PROMPT
PROMPT [4/7] Core package
@@sql/05_pkg_mon_spec.sql
@@sql/06_pkg_mon_body.sql

PROMPT
PROMPT [5/7] OCI package
@@sql/07_pkg_mon_oci_spec.sql
@@sql/08_pkg_mon_oci_body.sql

PROMPT
PROMPT [6/7] Scheduler jobs
@@sql/09_jobs.sql

PROMPT
PROMPT [7/7] Verification
@@sql/10_verify.sql

PROMPT
PROMPT ================================================================
PROMPT  Installation complete
PROMPT ================================================================
