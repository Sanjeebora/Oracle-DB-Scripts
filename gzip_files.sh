#!/usr/bin/env bash
# Compress one or more files with gzip on Linux.
# Usage: gzip_files.sh [--keep] FILE [FILE ...]

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: gzip_files.sh [--keep] FILE [FILE ...]

Compress one or more files with gzip. By default each FILE is replaced
with FILE.gz (same as the gzip command). Pass --keep to leave the
original files in place.

Examples:
  gzip_files.sh report.log
  gzip_files.sh --keep data1.csv data2.csv /tmp/export.txt
EOF
}

keep_original=0
files=()

for arg in "$@"; do
  case "$arg" in
    -h|--help)
      usage
      exit 0
      ;;
    -k|--keep)
      keep_original=1
      ;;
    -*)
      echo "Error: unknown option '$arg'." >&2
      usage >&2
      exit 1
      ;;
    *)
      files+=("$arg")
      ;;
  esac
done

if [[ ${#files[@]} -eq 0 ]]; then
  usage >&2
  exit 1
fi

if ! command -v gzip >/dev/null 2>&1; then
  echo "Error: gzip is not installed or not in PATH." >&2
  exit 1
fi

ok=0
fail=0
skipped=0

gzip_args=(-f)
if [[ "$keep_original" -eq 1 ]]; then
  gzip_args+=(-k)
fi

for file in "${files[@]}"; do
  if [[ ! -e "$file" ]]; then
    echo "Error: '$file' does not exist." >&2
    fail=$((fail + 1))
    continue
  fi

  if [[ -d "$file" ]]; then
    echo "Error: '$file' is a directory; skipping." >&2
    fail=$((fail + 1))
    continue
  fi

  if [[ ! -f "$file" ]]; then
    echo "Error: '$file' is not a regular file; skipping." >&2
    fail=$((fail + 1))
    continue
  fi

  if [[ "$file" == *.gz ]]; then
    echo "Skip: '$file' already has a .gz extension."
    skipped=$((skipped + 1))
    continue
  fi

  if gzip "${gzip_args[@]}" -- "$file"; then
    echo "Compressed: $file -> ${file}.gz"
    ok=$((ok + 1))
  else
    echo "Error: failed to compress '$file'." >&2
    fail=$((fail + 1))
  fi
done

echo "Done. compressed=$ok skipped=$skipped failed=$fail"

if [[ "$fail" -gt 0 ]]; then
  exit 1
fi
