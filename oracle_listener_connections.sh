#!/usr/bin/env bash
# Report successful Oracle listener connections grouped by client machine.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: oracle_listener_connections.sh [LISTENER_NAME]

Discover the Oracle listener log with "lsnrctl status", then count
successful established connections grouped by client machine name.

LISTENER_NAME defaults to LISTENER.

Examples:
  oracle_listener_connections.sh
  oracle_listener_connections.sh LISTENER_ORCL
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

listener_name=${1:-LISTENER}

if ! command -v lsnrctl >/dev/null 2>&1; then
  echo "Error: lsnrctl is not installed or is not in PATH." >&2
  echo "Set the Oracle environment (for example, ORACLE_HOME and PATH) and retry." >&2
  exit 1
fi

if ! status_output=$(lsnrctl status "$listener_name" 2>&1); then
  echo "Error: could not obtain status for Oracle listener '$listener_name'." >&2
  printf '%s\n' "$status_output" >&2
  exit 1
fi

listener_log=$(
  printf '%s\n' "$status_output" |
    awk '
      /Listener Log File/ {
        sub(/^.*Listener Log File[[:space:]]*/, "")
        sub(/[[:space:]]+$/, "")
        print
        exit
      }
    '
)

if [[ -z "$listener_log" ]]; then
  echo "Error: listener log location was not found in lsnrctl output." >&2
  exit 1
fi

# Show the requested log location before all connection statistics.
printf 'Listener log: %s\n\n' "$listener_log"

if [[ ! -f "$listener_log" ]]; then
  echo "Error: listener log is not a regular file: $listener_log" >&2
  exit 1
fi

if [[ ! -r "$listener_log" ]]; then
  echo "Error: listener log is not readable: $listener_log" >&2
  echo "Run as the Oracle software owner or grant read permission." >&2
  exit 1
fi

awk '
  function trim(value) {
    sub(/^[[:space:]]+/, "", value)
    sub(/[[:space:]]+$/, "", value)
    return value
  }

  function process(entry, fields, field_count, i, clean_entry, upper_entry,
                   host_token, host) {
    clean_entry = entry
    gsub(/<[^>]*>/, "", clean_entry)

    field_count = split(clean_entry, fields, "*")
    if (field_count < 2 || trim(fields[field_count]) != "0") {
      return
    }

    for (i = 1; i <= field_count; i++) {
      if (tolower(trim(fields[i])) == "establish") {
        break
      }
    }
    if (i > field_count) {
      return
    }

    # The first HOST field is in CONNECT_DATA/CID and identifies the client.
    upper_entry = toupper(clean_entry)
    if (match(upper_entry, /\(HOST=[^)]*\)/)) {
      host_token = substr(clean_entry, RSTART, RLENGTH)
      host = substr(host_token, 7, length(host_token) - 7)
      host = trim(host)
      if (host == "") {
        host = "<unknown>"
      }
    } else {
      host = "<unknown>"
    }

    connections[host]++
  }

  {
    lower_line = tolower($0)

    # ADR XML logs normally keep <txt> on one line, but accumulating the
    # element also supports wrapped message text.
    if (in_text) {
      text_buffer = text_buffer " " $0
      if (index(lower_line, "</txt>")) {
        process(text_buffer)
        text_buffer = ""
        in_text = 0
      }
      next
    }

    if (index(lower_line, "<txt>")) {
      text_buffer = $0
      if (index(lower_line, "</txt>")) {
        process(text_buffer)
        text_buffer = ""
      } else {
        in_text = 1
      }
      next
    }

    process($0)
  }

  END {
    if (in_text && text_buffer != "") {
      process(text_buffer)
    }
    for (host in connections) {
      printf "%s\t%d\n", host, connections[host]
    }
  }
' "$listener_log" |
  sort -t $'\t' -k2,2nr -k1,1 |
  awk -F '\t' '
    BEGIN {
      printf "%-40s %12s\n", "CLIENT_MACHINE", "CONNECTIONS"
      printf "%-40s %12s\n", "----------------------------------------", "------------"
    }
    {
      printf "%-40s %12d\n", $1, $2
      total += $2
    }
    END {
      printf "%-40s %12s\n", "----------------------------------------", "------------"
      printf "%-40s %12d\n", "TOTAL", total
    }
  '
