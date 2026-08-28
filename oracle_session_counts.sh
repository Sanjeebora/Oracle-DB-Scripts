#!/usr/bin/env bash
# Report Oracle session counts grouped by instance, user, machine, and program.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: oracle_session_counts.sh [CONNECT_STRING]

Count Oracle sessions grouped by instance name, username, machine, and
program. For each group, report ACTIVE, INACTIVE, and total session
counts. Other statuses such as KILLED or SNIPED are included in TOTAL
but not in ACTIVE or INACTIVE.

CONNECT_STRING defaults to "/ as sysdba".

Examples:
  oracle_session_counts.sh
  oracle_session_counts.sh system/password@ORCL
  ORACLE_CONNECT='system/password@ORCL' oracle_session_counts.sh

Environment:
  ORACLE_CONNECT   Connect string used when no argument is given
  ORACLE_SQLPLUS   sqlplus command (default: sqlplus)
EOF
}

case ${1-} in
  -h|--help)
    usage
    exit 0
    ;;
esac

if [[ $# -gt 1 ]]; then
  usage >&2
  exit 2
fi

connect_string=${1:-${ORACLE_CONNECT:-/ as sysdba}}
sqlplus_cmd=${ORACLE_SQLPLUS:-sqlplus}

if ! command -v "$sqlplus_cmd" >/dev/null 2>&1; then
  echo "Error: $sqlplus_cmd is not installed or is not in PATH." >&2
  echo "Set the Oracle environment (for example, ORACLE_HOME and PATH) and retry." >&2
  exit 1
fi

# sqlplus treats a connect string with spaces (for example "/ as sysdba")
# as multiple arguments unless it is passed as one quoted token.
set +e
sqlplus_output=$(
  "$sqlplus_cmd" -s "$connect_string" <<'SQL'
WHENEVER SQLERROR EXIT FAILURE
SET ECHO OFF
SET FEEDBACK OFF
SET HEADING OFF
SET PAGESIZE 0
SET LINESIZE 400
SET TRIMSPOOL ON
SET TAB OFF
SELECT
  NVL(i.instance_name, 'UNKNOWN')
  || '~|~' || NVL(s.username, 'BACKGROUND')
  || '~|~' || NVL(s.machine, 'UNKNOWN')
  || '~|~' || NVL(s.program, 'UNKNOWN')
  || '~|~' || SUM(CASE WHEN s.status = 'ACTIVE' THEN 1 ELSE 0 END)
  || '~|~' || SUM(CASE WHEN s.status = 'INACTIVE' THEN 1 ELSE 0 END)
  || '~|~' || COUNT(*)
FROM gv$session s
JOIN gv$instance i ON s.inst_id = i.inst_id
GROUP BY
  NVL(i.instance_name, 'UNKNOWN'),
  NVL(s.username, 'BACKGROUND'),
  NVL(s.machine, 'UNKNOWN'),
  NVL(s.program, 'UNKNOWN')
ORDER BY
  NVL(i.instance_name, 'UNKNOWN'),
  NVL(s.username, 'BACKGROUND'),
  NVL(s.machine, 'UNKNOWN'),
  NVL(s.program, 'UNKNOWN');
EXIT
SQL
)
sqlplus_status=$?
set -e

if [[ "$sqlplus_status" -ne 0 ]]; then
  echo "Error: sqlplus failed while querying session counts." >&2
  if [[ -n "$sqlplus_output" ]]; then
    printf '%s\n' "$sqlplus_output" >&2
  fi
  exit 1
fi

if [[ -z "${sqlplus_output//[[:space:]]/}" ]]; then
  echo "Error: sqlplus returned no session data." >&2
  exit 1
fi

if printf '%s\n' "$sqlplus_output" | grep -Eq 'ORA-[0-9]{5}|SP2-[0-9]{4}'; then
  echo "Error: sqlplus reported a failure while querying session counts." >&2
  printf '%s\n' "$sqlplus_output" >&2
  exit 1
fi

printf '%s\n' "$sqlplus_output" |
  awk -F '~\\|~' '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }

    BEGIN {
      printf "%-16s  %-16s  %-24s  %-32s  %8s  %10s  %8s\n",
             "INSTANCE", "USERNAME", "MACHINE", "PROGRAM",
             "ACTIVE", "INACTIVE", "TOTAL"
      printf "%-16s  %-16s  %-24s  %-32s  %8s  %10s  %8s\n",
             "----------------", "----------------",
             "------------------------", "--------------------------------",
             "--------", "----------", "--------"
    }

    NF == 0 { next }
    {
      instance_name = trim($1)
      username = trim($2)
      machine = trim($3)
      program = trim($4)
      active_count = trim($5) + 0
      inactive_count = trim($6) + 0
      total_count = trim($7) + 0

      if (instance_name == "" || username == "" || machine == "" || program == "") {
        next
      }

      printf "%-16s  %-16s  %-24s  %-32s  %8d  %10d  %8d\n",
             instance_name, username, machine, program,
             active_count, inactive_count, total_count
      active_total += active_count
      inactive_total += inactive_count
      grand_total += total_count
      row_count++
    }

    END {
      if (row_count == 0) {
        print "Error: sqlplus returned no parseable session rows." > "/dev/stderr"
        exit 1
      }
      printf "%-16s  %-16s  %-24s  %-32s  %8s  %10s  %8s\n",
             "----------------", "----------------",
             "------------------------", "--------------------------------",
             "--------", "----------", "--------"
      printf "%-16s  %-16s  %-24s  %-32s  %8d  %10d  %8d\n",
             "", "", "", "TOTAL",
             active_total, inactive_total, grand_total
    }
  '
