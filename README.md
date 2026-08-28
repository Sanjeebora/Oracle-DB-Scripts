# Oracle DB Scripts

Linux helper scripts for day-to-day file and database work.

## gzip_files.sh

Compress files with `gzip`, or pack directories into a tar archive and then gzip that archive. Use separate flags so files and directories are handled correctly.

### Requirements

- Linux (or another Unix-like OS with Bash)
- `gzip` in `PATH`
- `tar` in `PATH` when using `-d` / `--directory`

### Setup

```bash
chmod +x gzip_files.sh
```

### Usage

```bash
./gzip_files.sh [--keep] [-f FILE ...] [-d DIR ...]
```

| Option | Description |
| --- | --- |
| `-f`, `--file FILE` | Compress each `FILE` to `FILE.gz`. You can pass several files after one `-f`, or repeat the flag. |
| `-d`, `--directory DIR` | Create `DIR.tar`, then gzip it to `DIR.tar.gz`. You can pass several directories after one `-d`, or repeat the flag. The original directory is not removed. |
| `-k`, `--keep` | Leave original files in place when gzipping. Without this flag, each input file is replaced by `FILE.gz`. Directories are never removed. |
| `-h`, `--help` | Print usage and exit. |

Paths must come after `-f` or `-d`. Mixing both flags in one run is supported.

### Examples

Compress a single file (original is replaced by `report.log.gz`):

```bash
./gzip_files.sh -f report.log
```

Compress several files and keep the originals:

```bash
./gzip_files.sh --keep -f data1.csv data2.csv /tmp/export.txt
```

Archive a directory: tar first, then gzip (`/var/log/app.tar.gz`):

```bash
./gzip_files.sh -d /var/log/app
```

Compress a file and archive directories in one run:

```bash
./gzip_files.sh -f export.txt -d backups logs
```

### Behavior

- Files: regular files are compressed to `FILE.gz`. Files that already end in `.gz` are skipped. Directories passed with `-f` are rejected.
- Directories: the script runs `tar` to create `DIR.tar`, then `gzip` to produce `DIR.tar.gz`. Files passed with `-d` are rejected.
- Missing paths and non-regular files are reported as errors and skipped.
- After processing, the script prints a summary: `compressed`, `skipped`, and `failed`.
- Exit code is `0` when every path succeeds or is skipped as already compressed; exit code is `1` if any path fails.
