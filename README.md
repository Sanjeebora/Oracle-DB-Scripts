# Oracle DB Scripts

Linux helper scripts for day-to-day file and database work.

## gzip_files.sh

Compress one or more files with `gzip` on Linux. The script accepts multiple file paths as arguments.

### Requirements

- Linux (or another Unix-like OS with Bash)
- `gzip` installed and available in `PATH`

### Setup

```bash
chmod +x gzip_files.sh
```

### Usage

```bash
./gzip_files.sh [--keep] FILE [FILE ...]
```

| Option | Description |
| --- | --- |
| `-k`, `--keep` | Leave the original files in place. Without this flag, each input file is replaced by `FILE.gz` (same as the `gzip` command). |
| `-h`, `--help` | Print usage and exit. |

### Examples

Compress a single file (original is replaced by `report.log.gz`):

```bash
./gzip_files.sh report.log
```

Compress several files and keep the originals:

```bash
./gzip_files.sh --keep data1.csv data2.csv /tmp/export.txt
```

### Behavior

- Regular files are compressed to `FILE.gz`.
- Paths that do not exist, directories, and non-regular files are reported as errors and skipped.
- Files that already end in `.gz` are skipped.
- After processing, the script prints a summary: `compressed`, `skipped`, and `failed`.
- Exit code is `0` when every file succeeds or is skipped as already compressed; exit code is `1` if any file fails.
