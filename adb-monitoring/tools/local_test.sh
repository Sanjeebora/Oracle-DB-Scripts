#!/usr/bin/env bash
#-------------------------------------------------------------------------------
# local_test.sh
#
# Compiles and tests the monitoring pack against a throwaway Oracle Database Free
# container. This is not a substitute for testing on a real Autonomous Database:
# it cannot exercise DBMS_CLOUD, the resource principal, or the ADB-only views.
# What it does prove, cheaply and repeatably:
#
#   * every object compiles, with no invalid PL/SQL
#   * every dynamic collector statement parses
#   * alerting, dedupe, cooldown, resolve and auto-close behave
#   * threshold evaluation reaches the right verdict from known inputs
#   * backup payload parsing and the failed / stale / absent detection paths
#   * the clone guard actually silences the pack
#
# Usage:
#   tools/local_test.sh up      start the container and deploy the pack
#   tools/local_test.sh test    run the test suite
#   tools/local_test.sh sql     open a SQL*Plus session as DBMON
#   tools/local_test.sh down    remove the container
#-------------------------------------------------------------------------------
set -euo pipefail

CONTAINER="${CONTAINER:-oradb}"
IMAGE="${IMAGE:-docker.io/gvenzl/oracle-free:23-slim}"
PDB="${PDB:-FREEPDB1}"
SYS_PWD="${SYS_PWD:-Welcome1}"
DBMON_PWD="${DBMON_PWD:-Welcome1}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

runtime() { command -v podman >/dev/null 2>&1 && echo podman || echo docker; }
RT="$(runtime)"

sysdba() { $RT exec -i "$CONTAINER" sqlplus -S -L "sys/${SYS_PWD}@localhost:1521/${PDB} as sysdba"; }
dbmon()  { $RT exec -i "$CONTAINER" sqlplus -S -L "dbmon/${DBMON_PWD}@localhost:1521/${PDB}"; }

wait_ready() {
  echo "Waiting for the database to open..."
  for _ in $(seq 1 120); do
    if $RT logs "$CONTAINER" 2>&1 | grep -q "DATABASE IS READY TO USE"; then
      echo "Database is ready."
      return 0
    fi
    sleep 5
  done
  echo "Timed out waiting for the database." >&2
  return 1
}

cmd_up() {
  if ! $RT container exists "$CONTAINER" 2>/dev/null; then
    echo "Starting $IMAGE ..."
    $RT run -d --name "$CONTAINER" -e ORACLE_PASSWORD="$SYS_PWD" "$IMAGE" >/dev/null
  fi
  wait_ready

  echo "Creating the DBMON schema ..."
  sysdba <<SQL
SET ECHO OFF FEEDBACK OFF
WHENEVER SQLERROR CONTINUE
DROP USER dbmon CASCADE;
CREATE USER dbmon IDENTIFIED BY "${DBMON_PWD}";
ALTER USER dbmon QUOTA UNLIMITED ON USERS;
GRANT CREATE SESSION, CREATE TABLE, CREATE VIEW, CREATE PROCEDURE,
      CREATE SEQUENCE, CREATE JOB TO dbmon;
-- SELECT ANY DICTIONARY, not SELECT_CATALOG_ROLE: roles are disabled inside
-- definer's rights PL/SQL, which is what the collectors run as.
GRANT SELECT ANY DICTIONARY TO dbmon;
GRANT SELECT_CATALOG_ROLE   TO dbmon;
GRANT EXECUTE ON DBMS_SQL   TO dbmon;
EXIT
SQL

  echo "Copying sources into the container ..."
  $RT exec "$CONTAINER" rm -rf /tmp/pack
  $RT cp "$HERE" "$CONTAINER":/tmp/pack

  echo "Installing offline stubs (DBMS_CLOUD) ..."
  dbmon <<'SQL'
WHENEVER SQLERROR EXIT FAILURE
@/tmp/pack/tools/stubs/dbms_cloud_stub.sql
EXIT
SQL

  echo "Deploying the pack ..."
  dbmon <<'SQL'
SET ECHO OFF
WHENEVER SQLERROR EXIT FAILURE
@/tmp/pack/sql/02_tables.sql
@/tmp/pack/sql/03_config_seed.sql
@/tmp/pack/sql/04_views.sql
@/tmp/pack/sql/05_pkg_mon_spec.sql
@/tmp/pack/sql/06_pkg_mon_body.sql
@/tmp/pack/sql/07_pkg_mon_oci_spec.sql
@/tmp/pack/sql/08_pkg_mon_oci_body.sql
@/tmp/pack/test/t_framework.sql
EXIT
SQL

  echo
  echo "Checking for invalid objects ..."
  dbmon <<'SQL'
SET PAGESIZE 50 LINESIZE 150
COLUMN object_name FORMAT A24
COLUMN text        FORMAT A96
SELECT object_type, object_name, status FROM user_objects WHERE status <> 'VALID';
SELECT name, type, line, position, SUBSTR(text,1,96) AS text
FROM   user_errors ORDER BY name, sequence;
EXIT
SQL
  echo "Deployment complete."
}

cmd_test() {
  $RT exec "$CONTAINER" rm -rf /tmp/pack
  $RT cp "$HERE" "$CONTAINER":/tmp/pack
  dbmon <<'SQL'
SET ECHO OFF
WHENEVER SQLERROR EXIT FAILURE
@/tmp/pack/sql/05_pkg_mon_spec.sql
@/tmp/pack/sql/06_pkg_mon_body.sql
@/tmp/pack/sql/07_pkg_mon_oci_spec.sql
@/tmp/pack/sql/08_pkg_mon_oci_body.sql
@/tmp/pack/test/t_framework.sql
EXEC pkg_mon.set_cfg('TEST_MODE','Y');
EXIT
SQL
  $RT exec -i "$CONTAINER" bash -c \
    "cd /tmp/pack/test && sqlplus -S -L dbmon/${DBMON_PWD}@localhost:1521/${PDB} @run_all_tests.sql"
}

cmd_sql()  { $RT exec -it "$CONTAINER" sqlplus -L "dbmon/${DBMON_PWD}@localhost:1521/${PDB}"; }
cmd_down() { $RT rm -f "$CONTAINER" >/dev/null && echo "Container removed."; }

case "${1:-}" in
  up)   cmd_up ;;
  test) cmd_test ;;
  sql)  cmd_sql ;;
  down) cmd_down ;;
  *)    sed -n '3,25p' "${BASH_SOURCE[0]}"; exit 1 ;;
esac
