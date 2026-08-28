#!/usr/bin/env bash
# Compress files with gzip, or directories as tar then gzip.
# Usage: gzip_files.sh [--keep] [-f FILE ...] [-d DIR ...]

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: gzip_files.sh [--keep] [-f FILE ...] [-d DIR ...]

Compress files with gzip, or pack directories into a tar archive and
then gzip that archive.

  -f, --file FILE          Compress FILE to FILE.gz. May be repeated, or
                           followed by several files until the next flag.
  -d, --directory DIR      Create DIR.tar, then gzip it to DIR.tar.gz.
                           May be repeated, or followed by several
                           directories until the next flag.
  -k, --keep               Keep original files when gzipping. Directories
                           are never removed.
  -h, --help               Show this help and exit.

Examples:
  gzip_files.sh -f report.log
  gzip_files.sh --keep -f data1.csv data2.csv
  gzip_files.sh -d /var/log/app
  gzip_files.sh -f export.txt -d backups logs
EOF
}

keep_original=0
files=()
directories=()
mode=""

for arg in "$@"; do
  case "$arg" in
    -h|--help)
      usage
      exit 0
      ;;
    -k|--keep)
      keep_original=1
      ;;
    -f|--file)
      mode=file
      ;;
    -d|--directory|--dir)
      mode=directory
      ;;
    -*)
      echo "Error: unknown option '$arg'." >&2
      usage >&2
      exit 1
      ;;
    *)
      if [[ "$mode" == "file" ]]; then
        files+=("$arg")
      elif [[ "$mode" == "directory" ]]; then
        directories+=("$arg")
      else
        echo "Error: specify -f/--file or -d/--directory before '$arg'." >&2
        usage >&2
        exit 1
      fi
      ;;
  esac
done

if [[ ${#files[@]} -eq 0 && ${#directories[@]} -eq 0 ]]; then
  usage >&2
  exit 1
fi

if ! command -v gzip >/dev/null 2>&1; then
  echo "Error: gzip is not installed or not in PATH." >&2
  exit 1
fi

if [[ ${#directories[@]} -gt 0 ]] && ! command -v tar >/dev/null 2>&1; then
  echo "Error: tar is not installed or not in PATH." >&2
  exit 1
fi

ok=0
fail=0
skipped=0

gzip_args=(-f)
if [[ "$keep_original" -eq 1 ]]; then
  gzip_args+=(-k)
fi

compress_file() {
  local file=$1

  if [[ ! -e "$file" ]]; then
    echo "Error: file '$file' does not exist." >&2
    return 1
  fi

  if [[ -d "$file" ]]; then
    echo "Error: '$file' is a directory; use -d/--directory." >&2
    return 1
  fi

  if [[ ! -f "$file" ]]; then
    echo "Error: '$file' is not a regular file; skipping." >&2
    return 1
  fi

  if [[ "$file" == *.gz ]]; then
    echo "Skip: '$file' already has a .gz extension."
    skipped=$((skipped + 1))
    return 0
  fi

  if gzip "${gzip_args[@]}" -- "$file"; then
    echo "Compressed: $file -> ${file}.gz"
    ok=$((ok + 1))
    return 0
  fi

  echo "Error: failed to compress file '$file'." >&2
  return 1
}

archive_directory() {
  local dir=$1
  local parent base tarfile

  if [[ ! -e "$dir" ]]; then
    echo "Error: directory '$dir' does not exist." >&2
    return 1
  fi

  if [[ -f "$dir" ]]; then
    echo "Error: '$dir' is a file; use -f/--file." >&2
    return 1
  fi

  if [[ ! -d "$dir" ]]; then
    echo "Error: '$dir' is not a directory; skipping." >&2
    return 1
  fi

  dir=${dir%/}
  parent=$(dirname -- "$dir")
  base=$(basename -- "$dir")

  if [[ "$base" == "." || "$base" == ".." ]]; then
    echo "Error: cannot archive '$dir' (basename is '$base')." >&2
    return 1
  fi

  tarfile="${dir}.tar"

  if tar -cf "$tarfile" -C "$parent" -- "$base"; then
    :
  else
    echo "Error: failed to create tar archive for '$dir'." >&2
    rm -f -- "$tarfile"
    return 1
  fi

  if gzip -f -- "$tarfile"; then
    echo "Archived: $dir -> ${tarfile}.gz"
    ok=$((ok + 1))
    return 0
  fi

  echo "Error: failed to gzip tar archive '${tarfile}'." >&2
  rm -f -- "$tarfile"
  return 1
}

for file in "${files[@]+"${files[@]}"}"; do
  if ! compress_file "$file"; then
    fail=$((fail + 1))
  fi
done

for dir in "${directories[@]+"${directories[@]}"}"; do
  if ! archive_directory "$dir"; then
    fail=$((fail + 1))
  fi
done

echo "Done. compressed=$ok skipped=$skipped failed=$fail"

if [[ "$fail" -gt 0 ]]; then
  exit 1
fi
