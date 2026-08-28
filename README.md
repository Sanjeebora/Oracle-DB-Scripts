# Oracle DB Scripts

Linux helper scripts for day-to-day file and database work.

## oracle_listener_connections.sh

Discover the Oracle listener log and count successful established connections grouped by client machine name.

### Requirements

- Linux or another Unix-like OS with Bash
- Oracle `lsnrctl` available in `PATH`
- Read permission for the listener log
- Standard `awk` and `sort` utilities

Set the Oracle environment before running the script if necessary:

```bash
export ORACLE_HOME=/path/to/oracle/home
export PATH="$ORACLE_HOME/bin:$PATH"
```

### Setup

```bash
chmod +x oracle_listener_connections.sh
```

### Usage

The default listener name is `LISTENER`:

```bash
./oracle_listener_connections.sh
```

Specify a different listener as the first argument:

```bash
./oracle_listener_connections.sh LISTENER_ORCL
```

Show help:

```bash
./oracle_listener_connections.sh --help
```

### Example output

```text
Listener log: /u01/app/oracle/diag/tnslsnr/dbserver/listener/alert/log.xml

CLIENT_MACHINE                            CONNECTIONS
---------------------------------------- ------------
appserver01                                         25
appserver02                                         12
---------------------------------------- ------------
TOTAL                                              37
```

### Behavior

- Runs `lsnrctl status LISTENER_NAME` to discover the listener log.
- Prints the listener log location before the connection statistics.
- Supports traditional text listener logs and Oracle ADR XML `log.xml` files.
- Counts only `establish` records whose Oracle listener status code is `0`.
- Uses the first `HOST` value in `CONNECT_DATA/CID` as the client machine.
- Displays `<unknown>` when a successful record does not contain a client `HOST`.
- Sorts machines by connection count, highest first.
- Reads the current listener log only; rotated listener logs are not included.
- Exits with an error if `lsnrctl` fails or the discovered log cannot be read.

Run the script as the Oracle software owner if the listener log is not readable by your current user.

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
