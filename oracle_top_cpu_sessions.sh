#!/usr/bin/env bash
# Report the top five Oracle sessions by cumulative CPU consumption.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: oracle_top_cpu_sessions.sh [CONNECT_STRING]

Show the five connected user sessions with the highest cumulative CPU
usage. Session details are followed by the SQL ID and SQL text associated
with each session. Instance and container names identify the CDB/PDB
where each session and SQL statement belongs.

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
  -h|--help) usage; exit 0 ;;
esac
if [[ $# -gt 1 ]]; then usage >&2; exit 2; fi

connect_string=${1:-${ORACLE_CONNECT:-/ as sysdba}}
sqlplus_cmd=${ORACLE_SQLPLUS:-sqlplus}
if ! command -v "$sqlplus_cmd" >/dev/null 2>&1; then
  echo "Error: $sqlplus_cmd is not installed or is not in PATH." >&2
  exit 1
fi

set +e
cdb_output=$("$sqlplus_cmd" -s "$connect_string" <<'SQL'
WHENEVER SQLERROR EXIT FAILURE
SET ECHO OFF FEEDBACK OFF HEADING OFF PAGESIZE 0 TRIMSPOOL ON
SELECT cdb FROM v$database;
EXIT
SQL
)
cdb_status=$?
set -e
if [[ "$cdb_status" -ne 0 ]] || printf '%s\n' "$cdb_output" | grep -Eq 'ORA-[0-9]{5}|SP2-[0-9]{4}'; then
  echo "Error: could not determine whether the database is multitenant." >&2
  printf '%s\n' "$cdb_output" >&2
  exit 1
fi
cdb_flag=$(printf '%s\n' "$cdb_output" | awk '{$1=$1; if ($0 != "") {print toupper($0); exit}}')
case "$cdb_flag" in
  YES) database_type=CDB ;;
  NO) database_type=NON_CDB ;;
  *) echo "Error: unexpected V\$DATABASE.CDB value: '${cdb_flag:-<empty>}'." >&2; exit 1 ;;
esac

emit_report_sql() {
  cat <<'SQL'
WHENEVER SQLERROR EXIT FAILURE
SET ECHO OFF FEEDBACK OFF HEADING OFF PAGESIZE 0
SET LINESIZE 2000 LONG 2000 LONGCHUNKSIZE 2000 TRIMSPOOL ON TAB OFF
WITH ranked_sessions AS (
  SELECT ROW_NUMBER() OVER (ORDER BY ss.value DESC, s.inst_id, s.sid) cpu_rank,
         s.inst_id,
SQL
  if [[ "$database_type" == CDB ]]; then
    printf '%s\n' '         s.con_id, i.instance_name, c.name container_name,'
  else
    printf '%s\n' "         i.instance_name, 'NON-CDB' container_name,"
  fi
  cat <<'SQL'
         s.sid, s.serial#, s.username, NVL(s.machine, 'UNKNOWN') machine,
         NVL(s.sql_id, s.prev_sql_id) sql_id, ss.value cpu_centiseconds
  FROM gv$session s
  JOIN gv$sesstat ss ON ss.inst_id=s.inst_id AND ss.sid=s.sid
  JOIN gv$statname sn ON sn.inst_id=ss.inst_id AND sn.statistic#=ss.statistic#
  JOIN gv$instance i ON i.inst_id=s.inst_id
SQL
  if [[ "$database_type" == CDB ]]; then
    printf '%s\n' '  JOIN gv$containers c ON c.inst_id=s.inst_id AND c.con_id=s.con_id'
  fi
  cat <<'SQL'
  WHERE sn.name='CPU used by this session'
    AND s.type='USER'
    AND s.username NOT IN ('SYS','DBSNMP','PUBLIC')
),
top_sessions AS (SELECT * FROM ranked_sessions WHERE cpu_rank <= 5),
sql_candidates AS (
  SELECT q.inst_id,
SQL
  if [[ "$database_type" == CDB ]]; then printf '%s\n' '         q.con_id,'; fi
  cat <<'SQL'
         q.sql_id,
         REPLACE(REPLACE(REPLACE(DBMS_LOB.SUBSTR(q.sql_fulltext,1000,1),CHR(10),' '),CHR(13),' '),'~|~',' | ') sql_text,
         ROW_NUMBER() OVER (
SQL
  if [[ "$database_type" == CDB ]]; then
    printf '%s\n' '           PARTITION BY q.inst_id,q.con_id,q.sql_id'
  else
    printf '%s\n' '           PARTITION BY q.inst_id,q.sql_id'
  fi
  cat <<'SQL'
           ORDER BY q.last_active_time DESC NULLS LAST,q.child_number DESC) sql_rank
  FROM gv$sql q JOIN (
SQL
  if [[ "$database_type" == CDB ]]; then
    printf '%s\n' '    SELECT DISTINCT inst_id,con_id,sql_id FROM top_sessions WHERE sql_id IS NOT NULL'
  else
    printf '%s\n' '    SELECT DISTINCT inst_id,sql_id FROM top_sessions WHERE sql_id IS NOT NULL'
  fi
  printf '%s\n' '  ) t ON t.inst_id=q.inst_id'
  if [[ "$database_type" == CDB ]]; then printf '%s\n' '     AND t.con_id=q.con_id'; fi
  cat <<'SQL'
     AND t.sql_id=q.sql_id
),
report_rows AS (
  SELECT 'SESSION' record_type,t.cpu_rank display_order,t.cpu_rank,t.instance_name,t.container_name,
         t.sid,t.serial#,t.username,REPLACE(t.machine,'~|~',' | ') machine,NVL(t.sql_id,'<none>') sql_id,
         TO_CHAR(t.cpu_centiseconds/100,'FM999999999990D00','NLS_NUMERIC_CHARACTERS=''.,''') detail
  FROM top_sessions t
  UNION ALL
  SELECT 'SQL',100+t.cpu_rank,t.cpu_rank,t.instance_name,t.container_name,t.sid,t.serial#,t.username,
         REPLACE(t.machine,'~|~',' | '),NVL(t.sql_id,'<none>'),NVL(q.sql_text,'<SQL text unavailable>')
  FROM top_sessions t LEFT JOIN sql_candidates q ON q.inst_id=t.inst_id
SQL
  if [[ "$database_type" == CDB ]]; then printf '%s\n' '   AND q.con_id=t.con_id'; fi
  cat <<'SQL'
   AND q.sql_id=t.sql_id AND q.sql_rank=1
)
SELECT record_type||'~|~'||cpu_rank||'~|~'||instance_name||'~|~'||container_name||'~|~'||sid||'~|~'||serial#||
       '~|~'||username||'~|~'||machine||'~|~'||sql_id||'~|~'||detail
FROM report_rows ORDER BY display_order;
EXIT
SQL
}

set +e
sqlplus_output=$(emit_report_sql | "$sqlplus_cmd" -s "$connect_string")
sqlplus_status=$?
set -e
if [[ "$sqlplus_status" -ne 0 ]]; then
  echo "Error: sqlplus failed while querying top CPU sessions." >&2
  printf '%s\n' "$sqlplus_output" >&2
  exit 1
fi
if [[ -z "${sqlplus_output//[[:space:]]/}" ]]; then echo "No matching user sessions were found." >&2; exit 0; fi
if printf '%s\n' "$sqlplus_output" | grep -Eq 'ORA-[0-9]{5}|SP2-[0-9]{4}'; then
  echo "Error: sqlplus reported a failure while querying top CPU sessions." >&2
  printf '%s\n' "$sqlplus_output" >&2
  exit 1
fi

printf '%s\n' "$sqlplus_output" | awk -F '~\\|~' -v database_type="$database_type" '
function trim(v){sub(/^[[:space:]]+/,"",v);sub(/[[:space:]]+$/,"",v);return v}
BEGIN {
  printf "DATABASE TYPE: %s\n\nTOP 5 CPU-CONSUMING SESSIONS (CUMULATIVE)\n\n",database_type
  printf "%-5s %-12s %-18s %8s %10s %-20s %-28s %-13s %12s\n","RANK","INSTANCE","CONTAINER","SID","SERIAL#","USERNAME","MACHINE","SQL_ID","CPU_SECONDS"
  printf "%-5s %-12s %-18s %8s %10s %-20s %-28s %-13s %12s\n","-----","------------","------------------","--------","----------","--------------------","----------------------------","-------------","------------"
}
$1=="SESSION" {printf "%-5s %-12s %-18s %8s %10s %-20s %-28s %-13s %12s\n",trim($2),trim($3),trim($4),trim($5),trim($6),trim($7),trim($8),trim($9),trim($10); sessions++; next}
$1=="SQL" {
  if(!sql_header){printf "\nSQL DETAILS FOR TOP SESSIONS\n\n%-5s %-12s %-18s %8s %10s %-13s %s\n","RANK","INSTANCE","CONTAINER","SID","SERIAL#","SQL_ID","SQL_TEXT"; sql_header=1}
  printf "%-5s %-12s %-18s %8s %10s %-13s %s\n",trim($2),trim($3),trim($4),trim($5),trim($6),trim($9),trim($10); sql_rows++
}
END {if(!sessions || !sql_rows){print "Error: sqlplus returned incomplete report data." > "/dev/stderr"; exit 1}}
'
