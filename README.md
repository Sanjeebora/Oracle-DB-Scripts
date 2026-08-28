# Oracle DB Scripts

Linux helper scripts for day-to-day file and database work.

## oracle_session_counts.sh

Count Oracle sessions grouped by instance name, username, machine, and program. For each group, the report shows ACTIVE, INACTIVE, and TOTAL session counts. Background processes and SYS user sessions are omitted.

### Requirements

- Linux or another Unix-like OS with Bash
- Oracle `sqlplus` available in `PATH`
- Privilege to query `GV$SESSION` and `GV$INSTANCE` (typically a DBA account or `/ as sysdba` on the database host)
- Standard `awk` and `grep` utilities

Set the Oracle environment before running the script if necessary:

```bash
export ORACLE_HOME=/path/to/oracle/home
export PATH="$ORACLE_HOME/bin:$PATH"
export ORACLE_SID=ORCL
```

### Setup

```bash
chmod +x oracle_session_counts.sh
```

### Usage

Connect as SYSDBA with operating-system authentication (default):

```bash
./oracle_session_counts.sh
```

Connect with an explicit SQL*Plus connect string:

```bash
./oracle_session_counts.sh system/password@ORCL
```

Or set `ORACLE_CONNECT` so the connect string is not passed on the command line:

```bash
export ORACLE_CONNECT='system/password@ORCL'
./oracle_session_counts.sh
```

Show help:

```bash
./oracle_session_counts.sh --help
```

### Example output

```text
INSTANCE          USERNAME          MACHINE                   PROGRAM                             ACTIVE    INACTIVE     TOTAL
----------------  ----------------  ------------------------  --------------------------------  --------  ----------  --------
orcl1             APPUSER           appserver01               JDBC Thin Client                         4          12        16
orcl1             APPUSER           appserver02               sqlplus@appserver02 (TNS V1-V3)          1           0         1
----------------  ----------------  ------------------------  --------------------------------  --------  ----------  --------
                                                                  TOTAL                                5          12        17
```

### Behavior

- Queries `GV$SESSION` joined to `GV$INSTANCE`, so the report covers every instance in a RAC cluster as well as a single-instance database.
- Groups rows by instance name, username, client machine, and program.
- Counts `ACTIVE` and `INACTIVE` sessions separately. Other statuses such as `KILLED` or `SNIPED` are included in `TOTAL` only.
- Omits background processes (`GV$SESSION.TYPE = 'BACKGROUND'`) and sessions whose username is `SYS`.
- Null machine or program values are reported as `UNKNOWN`.
- Prints a grand total row for ACTIVE, INACTIVE, and TOTAL.
- Exits with an error if `sqlplus` is missing, the query fails, or no parseable session rows are returned.

## oracle_listener_connections.sh

Discover the Oracle listener log and count successful established connections grouped by hour and client machine name.

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

HOUR              CLIENT_MACHINE                    CONNECTIONS
----------------  -------------------------------- ------------
2026-08-28 10:00  appserver01                                 15
2026-08-28 10:00  appserver02                                  7
2026-08-28 11:00  appserver01                                 10
2026-08-28 11:00  appserver02                                  5
----------------  -------------------------------- ------------
                  TOTAL                                      37
```

### Behavior

- Runs `lsnrctl status LISTENER_NAME` to discover the listener log.
- Prints the listener log location before the connection statistics.
- Supports traditional text listener logs and Oracle ADR XML `log.xml` files.
- Counts only `establish` records whose Oracle listener status code is `0`.
- Uses the first `HOST` value in `CONNECT_DATA/CID` as the client machine.
- Groups each client machine's count into hourly buckets displayed as `YYYY-MM-DD HH:00`.
- Displays `<unknown>` when a successful record does not contain a client `HOST`.
- Sorts the report chronologically, with the busiest client first within each hour.
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
