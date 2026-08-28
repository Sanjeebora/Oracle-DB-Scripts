#!/usr/bin/env bash
# Report the top five Oracle sessions by cumulative CPU consumption.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: oracle_top_cpu_sessions.sh [CONNECT_STRING]

Show the five connected user sessions with the highest cumulative CPU
usage. Session details are followed by the SQL ID and SQL text associated
with each session.

Background processes and SYS, DBSNMP, and PUBLIC sessions are excluded.
CONNECT_STRING defaults to "/ as sysdba".

Examples:
  oracle_top_cpu_sessions.sh
  oracle_top_cpu_sessions.sh system/password@ORCL
  ORACLE_CONNECT='system/password@ORCL' oracle_top_cpu_sessions.sh

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

set +e
sqlplus_output=$(
  "$sqlplus_cmd" -s "$connect_string" <<'SQL'
WHENEVER SQLERROR EXIT FAILURE
SET ECHO OFF
SET FEEDBACK OFF
SET HEADING OFF
SET PAGESIZE 0
SET LINESIZE 2000
SET LONG 2000
SET LONGCHUNKSIZE 2000
SET TRIMSPOOL ON
SET TAB OFF

WITH ranked_sessions AS (
  SELECT
    ROW_NUMBER() OVER (
      ORDER BY ss.value DESC, s.inst_id, s.sid
    ) AS cpu_rank,
    s.inst_id,
    i.instance_name,
    s.sid,
    s.serial#,
    s.username,
    NVL(s.machine, 'UNKNOWN') AS machine,
    NVL(s.sql_id, s.prev_sql_id) AS sql_id,
    ss.value AS cpu_centiseconds
  FROM gv$session s
  JOIN gv$sesstat ss
    ON ss.inst_id = s.inst_id
   AND ss.sid = s.sid
  JOIN gv$statname sn
    ON sn.inst_id = ss.inst_id
   AND sn.statistic# = ss.statistic#
  JOIN gv$instance i
    ON i.inst_id = s.inst_id
  WHERE sn.name = 'CPU used by this session'
    AND s.type = 'USER'
    AND s.username NOT IN ('SYS', 'DBSNMP', 'PUBLIC')
),
top_sessions AS (
  SELECT *
  FROM ranked_sessions
  WHERE cpu_rank <= 5
),
sql_candidates AS (
  SELECT
    q.inst_id,
    q.sql_id,
    REPLACE(
      REPLACE(
        REPLACE(DBMS_LOB.SUBSTR(q.sql_fulltext, 1000, 1), CHR(10), ' '),
        CHR(13), ' '
      ),
      '~|~', ' | '
    ) AS sql_text,
    ROW_NUMBER() OVER (
      PARTITION BY q.inst_id, q.sql_id
      ORDER BY q.last_active_time DESC NULLS LAST, q.child_number DESC
    ) AS sql_rank
  FROM gv$sql q
  JOIN (
    SELECT DISTINCT inst_id, sql_id
    FROM top_sessions
    WHERE sql_id IS NOT NULL
  ) t
    ON t.inst_id = q.inst_id
   AND t.sql_id = q.sql_id
),
report_rows AS (
  SELECT
    'SESSION' AS record_type,
    t.cpu_rank AS display_order,
    t.cpu_rank,
    t.instance_name,
    t.sid,
    t.serial#,
    t.username,
    REPLACE(t.machine, '~|~', ' | ') AS machine,
    NVL(t.sql_id, '<none>') AS sql_id,
    TO_CHAR(t.cpu_centiseconds / 100, 'FM999999999990D00',
            'NLS_NUMERIC_CHARACTERS=''.,''') AS detail
  FROM top_sessions t

  UNION ALL

  SELECT
    'SQL' AS record_type,
    100 + t.cpu_rank AS display_order,
    t.cpu_rank,
    t.instance_name,
    t.sid,
    t.serial#,
    t.username,
    REPLACE(t.machine, '~|~', ' | ') AS machine,
    NVL(t.sql_id, '<none>') AS sql_id,
    NVL(q.sql_text, '<SQL text unavailable>') AS detail
  FROM top_sessions t
  LEFT JOIN sql_candidates q
    ON q.inst_id = t.inst_id
   AND q.sql_id = t.sql_id
   AND q.sql_rank = 1
)
SELECT
  record_type
  || '~|~' || cpu_rank
  || '~|~' || instance_name
  || '~|~' || sid
  || '~|~' || serial#
  || '~|~' || username
  || '~|~' || machine
  || '~|~' || sql_id
  || '~|~' || detail
FROM report_rows
ORDER BY display_order;

EXIT
SQL
)
sqlplus_status=$?
set -e

if [[ "$sqlplus_status" -ne 0 ]]; then
  echo "Error: sqlplus failed while querying top CPU sessions." >&2
  if [[ -n "$sqlplus_output" ]]; then
    printf '%s\n' "$sqlplus_output" >&2
  fi
  exit 1
fi

if [[ -z "${sqlplus_output//[[:space:]]/}" ]]; then
  echo "No matching user sessions were found." >&2
  exit 0
fi

if printf '%s\n' "$sqlplus_output" | grep -Eq 'ORA-[0-9]{5}|SP2-[0-9]{4}'; then
  echo "Error: sqlplus reported a failure while querying top CPU sessions." >&2
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
      printf "TOP 5 CPU-CONSUMING SESSIONS (CUMULATIVE)\n\n"
      printf "%-5s %-12s %8s %10s %-20s %-28s %-13s %12s\n",
             "RANK", "INSTANCE", "SID", "SERIAL#",
             "USERNAME", "MACHINE", "SQL_ID", "CPU_SECONDS"
      printf "%-5s %-12s %8s %10s %-20s %-28s %-13s %12s\n",
             "-----", "------------", "--------", "----------",
             "--------------------", "----------------------------",
             "-------------", "------------"
    }

    $1 == "SESSION" {
      printf "%-5s %-12s %8s %10s %-20s %-28s %-13s %12s\n",
             trim($2), trim($3), trim($4), trim($5),
             trim($6), trim($7), trim($8), trim($9)
      session_count++
      next
    }

    $1 == "SQL" {
      if (!sql_heading_printed) {
        printf "\nSQL DETAILS FOR TOP SESSIONS\n\n"
        printf "%-5s %-12s %8s %10s %-13s %s\n",
               "RANK", "INSTANCE", "SID", "SERIAL#", "SQL_ID", "SQL_TEXT"
        printf "%-5s %-12s %8s %10s %-13s %s\n",
               "-----", "------------", "--------", "----------",
               "-------------", "--------"
        sql_heading_printed = 1
      }
      printf "%-5s %-12s %8s %10s %-13s %s\n",
             trim($2), trim($3), trim($4), trim($5), trim($8), trim($9)
      sql_count++
      next
    }

    END {
      if (session_count == 0) {
        print "Error: sqlplus returned no parseable session rows." > "/dev/stderr"
        exit 1
      }
      if (sql_count == 0) {
        print "Error: sqlplus returned no parseable SQL detail rows." > "/dev/stderr"
        exit 1
      }
    }
  '
