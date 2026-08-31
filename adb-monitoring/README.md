# ADB monitoring pack

In-database monitoring for Oracle Autonomous Database, covering the three things
that generate most of the pages: **resource consumption**, **slow queries**, and
**backup failures**.

Everything runs inside the database as `DBMS_SCHEDULER` jobs owned by a dedicated
`DBMON` schema. Alerts go out through `DBMS_CLOUD_NOTIFICATION` to OCI
Notifications, Slack, Teams, or email. Backup status is read from the OCI
Database API using the resource principal, so there are no stored credentials.

---

## Why in-database monitoring, when OCI already has metrics

OCI service metrics and the in-database pack answer different questions, and
neither is sufficient alone.

| Question | Answered by |
|---|---|
| Is the database up? | OCI alarm. The database cannot page you about its own outage. |
| Is CPU high? | Either. |
| **Which SQL** is burning the CPU? | In-database only. |
| Did the plan for that SQL change last night? | In-database only. |
| Are sessions queuing behind the resource manager? | In-database, per consumer group. |
| Did last night's backup succeed? | Either, but see below. |
| Did last night's backup **never start**? | In-database polling only. |

That last row is the one worth dwelling on. An OCI Events rule fires when a
backup *fails*. A backup that never begins produces no event at all, so an
event-driven alarm stays silent through exactly the failure you most need to
know about. This pack polls the current state and alerts on the **age of the
last successful backup**, which catches both.

Use both layers. This repository is the in-database layer; the OCI-side alarms
it expects are listed at the end.

---

## What it watches

**Resource consumption** — average active sessions per CPU, consumer group
activity and queue depth, tablespace usage plus a growth trend and projected
full date, session and process saturation, and the resource manager's own
eCPU wait metric.

The alert that matters here is *statements queuing*, not *CPU is high*. A
database sitting at 95% CPU with an empty queue is well used. A database at 60%
CPU with sessions queuing in `TP` has users waiting. Alerting on the second and
ignoring the first is the difference between a channel people read and a channel
people mute.

**Slow queries** — statements currently running longer than a threshold, top SQL
by sampled database time from ASH, and plan regressions detected from AWR by
comparing a statement's new plan against the plan it replaced. Every slow-SQL
alert carries the `sql_id`, the user, the module, and the exact
`DBMS_SQL_MONITOR.REPORT_SQL_MONITOR` call to get the execution plan.

**Backups** — failed backups with the reason the service reported, no successful
backup within a configurable window, backups that exist but are not restorable,
backup retention drifting below policy, and the database's own lifecycle state.

---

## Prerequisites

### 1. OCI dynamic group and policy

The backup checks call the OCI Database API as the database itself. Create a
dynamic group matching the ADB, then a policy granting it read access.

Dynamic group rule:

```
ALL {resource.type = 'autonomousdatabase', resource.id = '<your ADB OCID>'}
```

Policy, in the compartment containing the database:

```
Allow dynamic-group adb-monitors to read autonomous-database-family in compartment <name>
Allow dynamic-group adb-monitors to use ons-topics in compartment <name>
Allow dynamic-group adb-monitors to use metrics in compartment <name>
```

The second statement is only needed if you route alerts through OCI
Notifications; the third only if you enable the heartbeat job.

### 2. A notification target

Create an ONS topic and note its OCID, or create a Slack/Teams/email credential
with `DBMS_CLOUD.CREATE_CREDENTIAL`. The pack installs with notifications set to
`log`, so it records alerts without sending anything until you configure this.
That is deliberate: a fresh install should never page anyone.

---

## Installing

```bash
# 1. Find out what this instance actually exposes. Creates nothing.
sqlplus admin/<pw>@<alias> @sql/00_preflight.sql

# 2. Create the DBMON schema, grants, and the resource principal.
sqlplus admin/<pw>@<alias> @sql/01_admin_setup.sql "<dbmon password>"

# 3. Install the pack.
sqlplus -L dbmon/<pw>@<alias> @deploy.sql
```

`deploy.sql` is re-runnable. Tables and existing configuration keys are left
alone so tuned thresholds survive an upgrade; packages, views, and jobs are
replaced.

Then point it at a notification channel:

```sql
EXEC pkg_mon.set_cfg('NOTIFY_TOPIC_OCID','ocid1.onstopic.oc1...');
EXEC pkg_mon.set_cfg('NOTIFY_PROVIDER','oci');
EXEC pkg_mon.notify('INFO','Delivery test','If you can read this, routing works.');
```

### One privilege detail that will otherwise waste your afternoon

`GRANT SELECT_CATALOG_ROLE TO dbmon` is **not** sufficient. Privileges granted
through a role are disabled inside definer's rights PL/SQL, which is what the
collectors run as. With only the role, every collector query works when you type
it in SQL\*Plus and fails with `ORA-00942` the moment the package runs it, and
the pack degrades quietly into collecting nothing.

`01_admin_setup.sql` grants `SELECT ANY DICTIONARY` (a system privilege, which
does apply) and falls back to direct object grants. If your site forbids both,
use the direct grants only.

To confirm what actually works after install:

```sql
SET SERVEROUTPUT ON
EXEC pkg_mon.validate_sql;
```

This parses every collector statement against the live dictionary and prints the
result. `ORA-00942` or `ORA-01031` means that one collector is unavailable here
and the rest carry on. Anything else is a defect.

---

## Files

| File | Run as | Purpose |
|---|---|---|
| `sql/00_preflight.sql` | ADMIN | Probe which views and packages exist. Creates nothing. |
| `sql/01_admin_setup.sql` | ADMIN | Create `DBMON`, grants, resource principal. |
| `sql/02_tables.sql` | DBMON | Repository tables. |
| `sql/03_config_seed.sql` | DBMON | Default thresholds. Never overwrites existing values. |
| `sql/04_views.sql` | DBMON | Reporting views. |
| `sql/05,06_pkg_mon*.sql` | DBMON | Core package: config, alerting, resource, slow SQL. |
| `sql/07,08_pkg_mon_oci*.sql` | DBMON | OCI package: backups, custom metrics. |
| `sql/09_jobs.sql` | DBMON | Scheduler jobs. |
| `sql/10_verify.sql` | DBMON | Arm the clone guard, validate, run one cycle. |
| `sql/99_uninstall.sql` | DBMON | Remove everything. |
| `deploy.sql` | DBMON | Runs steps 02 through 10 in order. |
| `test/` | DBMON | Test suite, see below. |
| `tools/local_test.sh` | shell | Compile and test against a throwaway Oracle container. |

### Jobs

| Job | Interval | Does |
|---|---|---|
| `MON_J_RESOURCE` | 1 min | Collect metrics, evaluate resource thresholds |
| `MON_J_SLOWSQL` | 5 min | Running statements, ASH top SQL, plan regressions |
| `MON_J_BACKUP` | 30 min | Poll the OCI Database API |
| `MON_J_DIGEST` | daily 07:00 | Morning summary, storage forecast, alert auto-close |
| `MON_J_PURGE` | daily 02:30 | Retention |
| `MON_J_HEARTBEAT` | 5 min, **disabled** | Publish custom metrics including a heartbeat |

Collectors run in the `LOW` consumer group so monitoring never competes with
user workload. Measured cost on an idle instance is roughly 10–20 ms per
one-minute run; `test/t07_overhead.sql` measures it on yours.

---

## Views a DBA actually uses

```sql
SELECT * FROM v_mon_open_alerts;         -- everything currently wrong, worst first
SELECT * FROM v_mon_cpu_pressure;        -- demand vs allocated CPU, per minute
SELECT * FROM v_mon_service_pressure;    -- where the concurrency limits bite
SELECT * FROM v_mon_top_sql_24h;         -- top SQL by sampled database time
SELECT * FROM v_mon_plan_instability;    -- statements running under several plans
SELECT * FROM v_mon_storage_forecast;    -- growth trend and projected full date
SELECT * FROM v_mon_backup_summary;      -- one row: are the backups fine?
SELECT * FROM v_mon_health;              -- is the monitoring itself working?
```

`v_mon_health` deserves a place on the dashboard. Silence from a monitoring
system means either nothing is wrong or the monitoring is broken, and those look
identical until you check.

---

## Alert keys

Alerts are deduplicated on a key, re-notified at most once per
`ALERT_COOLDOWN_MIN`, and closed automatically when the condition clears or after
`ALERT_AUTOCLOSE_MIN` of silence. Closing sends a resolution message.

| Key | Severity | Means |
|---|---|---|
| `RES_AAS` | WARNING | Average active sessions per CPU above threshold |
| `RES_QUEUE_<group>` | WARNING | Statements queuing in that consumer group |
| `RES_TBS_<name>` | WARNING/CRITICAL | Tablespace usage above threshold |
| `RES_SESSION_LIMIT` | WARNING | Session limit percentage approaching the ceiling |
| `RES_LIMIT_<resource>` | WARNING | `V$RESOURCE_LIMIT` utilisation high |
| `STORAGE_FORECAST_<name>` | WARNING | Growth trend projects full within N days |
| `SQL_LONG_<sql_id>` | WARNING | Statement running longer than `SLOW_SQL_SEC` |
| `SQL_REGRESS_<sql_id>` | WARNING | New plan materially slower than the old one |
| `BKP_FAILED_<id>` | CRITICAL | A backup reported `FAILED` |
| `BKP_STALE` | CRITICAL | No successful backup within `BACKUP_MAX_AGE_HOURS` |
| `BKP_NONE` | CRITICAL | No backups exist at all |
| `BKP_UNRESTORABLE_<id>` | WARNING | Backup succeeded but `isRestorable` is false |
| `BKP_RETENTION` | WARNING | Retention below `BACKUP_MIN_RETENTION_DAYS` |
| `BKP_API` | CRITICAL | Cannot reach the OCI API, so backups are unmonitored |
| `BKP_CONFIG` | WARNING | Database OCID unknown, backups were never checked |
| `DB_LIFECYCLE` | CRITICAL | Control plane does not report the database as available |

---

## Tuning

Every threshold is a row in `MON_CONFIG`; nothing is hardcoded.

```sql
SELECT cfg_key, cfg_value, descr FROM mon_config ORDER BY cfg_key;
EXEC pkg_mon.set_cfg('AAS_PER_CPU_WARN','2');
```

Suggested approach: run for two weeks with notifications set to `log`, look at
what *would* have fired, then set thresholds so the remaining alerts are ones
you would genuinely act on at 3am. Thresholds that survive contact with a real
workload are worth more than defaults copied from a blog post.

Two switches worth knowing:

```sql
EXEC pkg_mon.set_cfg('ENABLED','N');              -- stop everything, keep the data
EXEC pkg_mon.set_cfg('NOTIFY_MIN_SEVERITY','CRITICAL');  -- quiet hours
```

### The clone guard

`10_verify.sql` records this database's OCID in `EXPECTED_DB_OCID`. If the live
OCID stops matching, the pack goes silent and logs `SKIP`.

This exists because cloning an ADB clones `DBMON`, the jobs, and the
notification configuration along with it. Without the guard, every test refresh
starts paging the production on-call about a database nobody is using, and the
fastest way to lose trust in an alerting channel is to fill it with alerts about
the wrong database.

---

## Testing

The suite is fixture-driven, so it exercises paths you cannot reproduce on
demand, such as a failed automatic backup:

```sql
EXEC pkg_mon.set_cfg('TEST_MODE','Y');   -- required; tests modify the repository
@test/t_framework.sql
@test/run_all_tests.sql
```

`run_all_tests.sql` exits non-zero on failure, so it drops straight into a
pipeline. Individual scripts:

| Script | Covers |
|---|---|
| `t00_validate.sql` | Objects valid, config seeded, every collector parses |
| `t01_notify.sql` | Routing, severity filtering, audit trail |
| `t02_alerts.sql` | Dedupe, cooldown, resolve, reopen, auto-close |
| `t03_resource.sql` | Each threshold, including high CPU that must stay quiet |
| `t04_slow_sql.sql` | Long-running SQL, top SQL and plan instability views |
| `t05_backup.sql` | Ten backup scenarios from captured API payloads |
| `t06_clone_guard.sql` | Clone detection and the kill switch |
| `t07_overhead.sql` | What the monitoring costs, and purge behaviour |
| `t99_cleanup.sql` | Removes fixtures, restores thresholds |

The tests refuse to run unless `TEST_MODE` is `Y`. Run them on a test database
or a clone, not on the production instance you are monitoring.

### Testing without a tenancy

`tools/local_test.sh` compiles and tests the whole pack against a throwaway
Oracle Database Free container:

```bash
tools/local_test.sh up      # start the container, deploy the pack
tools/local_test.sh test    # run the suite
tools/local_test.sh down    # remove the container
```

It cannot exercise `DBMS_CLOUD`, the resource principal, or the ADB-only views,
and it installs stubs in `tools/stubs/` that **must never be run on a real ADB**
(local packages named `DBMS_CLOUD` would shadow the genuine ones for that
schema). What it does prove: everything compiles, every collector parses,
alerting behaves, thresholds reach the right verdicts, backup payload parsing
and all the detection paths work, and the clone guard silences the pack.

---

## The OCI side

Three things this pack structurally cannot do for you, because they require
something outside the database:

**1. Tell you the database is down.** Create an OCI alarm on
`oci_autonomous_database` / `DatabaseAvailability`:

```
DatabaseAvailability[1m].mean() < 1
```

**2. Tell you the monitoring stopped.** Enable `MON_J_HEARTBEAT`, then alarm on
the *absence* of `custom_adb_monitor` / `MonitorHeartbeat`. Without this, a
broken collector and a healthy database look the same from the outside.

```sql
EXEC DBMS_SCHEDULER.ENABLE('MON_J_HEARTBEAT');
```

**3. Catch backup failure events immediately.** An OCI Events rule on
`com.oraclecloud.databaseservice.autonomous.database.backup.end` with a
lifecycle filter gives you a failure notification in seconds, where the poller
takes up to 30 minutes. Keep both: events for speed, polling for the backups
that never start and therefore never emit an event.

Useful companion alarms on the `oci_autonomous_database` namespace:
`CpuUtilization`, `StorageUtilization`, `SessionUtilization`,
`QueuedStatements`, `FailedConnections`.

---

## Limitations

- ADB Serverless automatic backups are taken by the control plane, so
  `V$RMAN_STATUS` and `DBA_RMAN_BACKUP_JOB_DETAILS` are empty for them. The OCI
  API is the only in-database way to see them. Preflight reports these as
  unavailable by design, not as a misconfiguration.
- Plan regression detection reads AWR, which needs the Diagnostics Pack. It is
  included on Autonomous Database; on other platforms check your licensing.
  The collector disables itself if the views are not readable.
- `V$SYSMETRIC` is usually empty inside a PDB. The pack falls back to
  `V$CON_SYSMETRIC` automatically and does not filter on `GROUP_ID`, because the
  group numbering differs between the two views.
- A database cannot alert on its own unavailability. See the OCI side above.

---

## Uninstalling

```sql
@sql/99_uninstall.sql          -- drops jobs, packages, views, tables
```

To stop monitoring while keeping the history, use the kill switch instead:

```sql
EXEC pkg_mon.set_cfg('ENABLED','N');
```
