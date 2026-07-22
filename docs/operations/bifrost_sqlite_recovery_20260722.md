# Bifrost SQLite Recovery Report (2026-07-22)

## Executive summary

The production Bifrost instance on `127.0.0.1:8081` had two independent SQLite integrity problems:

1. `config.db` contained inconsistent secondary indexes on `governance_rate_limits`. Bifrost's periodic rate-limit persistence consequently failed every ten seconds with `database disk image is malformed`.
2. `logs.db` contained damaged table/index B-trees. Reads that happened to use intact indexes could still succeed, while sequential scans, log inserts, payload-stripped retry inserts, and API log searches failed intermittently.

The repair preserved the original databases, rebuilt the log store with SQLite's recovery path, repaired the rate-limit indexes, switched the recovered log database into production during a 1.19-second stop window, and verified new structured log writes. The production service is healthy, both active databases pass their applicable integrity checks, and the recurring malformed/I/O/insert errors have stopped.

## Environment and safety constraints

| Item | Value |
| --- | --- |
| Production container | `bifrost` |
| Production endpoint | `http://localhost:8081` |
| Production data directory | `C:\bifrost\data` / `/mnt/c/bifrost/data` |
| Untouched canary | `127.0.0.1:8082` |
| Untouched Pro test instance | `127.0.0.1:8083` |
| Recovery workspace | `/home/lycorica/workspace/tmp/bifrost-db-recovery-20260721-233000` |

Every operation that stopped `bifrost` used an exit trap or PowerShell `try/finally` block that restarted the container on every exit path. Provider, key, routing, and model-alias configuration was not migrated or rewritten.

## Symptoms

The container repeatedly emitted the following classes of errors:

```text
failed to dump rate limits to database: ... database disk image is malformed
batch insert failed ... disk I/O error
individual insert failed ... disk I/O error
payload-stripped insert failed ... disk I/O error
```

Inference traffic could still return HTTP 200 because provider execution and SQLite observability persistence are separate paths. This produced a dangerous partial-failure state: requests could succeed while their model, provider, input, output, token usage, and fallback records were absent from `logs.db`.

## Backup inherited by the repair

The first recovery attempt had already installed SQLite 3.46.1 and created a complete cold backup. That backup was reused; no second 4.3 GB backup was created.

Backup directory:

```text
/home/lycorica/workspace/tmp/bifrost-db-recovery-20260721-233000/original
```

Contents:

```text
config.db                 26 MB
logs.db                   4.3 GB
logs.db-wal.MISSING       marker: WAL absent at backup time
logs.db-shm.MISSING       marker: SHM absent at backup time
SHA256SUMS                checksums for every backup artifact
```

All entries in `SHA256SUMS` were verified successfully before recovery continued.

A second immutable safety copy of the database replaced during cutover remains at:

```text
C:\bifrost\data\logs.db.corrupt-20260722-173134
```

This file is intentionally retained because it may contain requests from the damaged interval that SQLite recovery did not reconstruct.

## Diagnosis

### `config.db`

The main tables were readable. A bounded integrity check isolated the defect to missing entries in two rate-limit indexes:

```text
row 1 missing from index idx_governance_rate_limits_token_last_reset
row 1 missing from index idx_governance_rate_limits_request_last_reset
...
row 4 missing from index idx_governance_rate_limits_token_last_reset
row 4 missing from index idx_governance_rate_limits_request_last_reset
```

There were four readable `governance_rate_limits` rows. The failure aligned exactly with Bifrost's ten-second rate-limit dump loop. The table data did not need reconstruction; rebuilding the two affected secondary indexes was sufficient.

### `logs.db`

The damaged database displayed split behavior:

- Queries through some intact indexes returned records.
- `SELECT ... NOT INDEXED` could scan thousands of rows before reaching a malformed page.
- A direct row-copy rebuild stopped after approximately 3,500 rows with `database disk image is malformed`.
- Log writes and retry writes failed in the running service.

Before recovery, diagnostic scans identified 4,233 distinct readable IDs, but this count did not prove that all rows were continuously readable: the B-tree fault occurred later in sequential traversal. SQLite `.recover` was therefore used rather than trusting a normal dump.

## Recovery procedure

### 1. Recover the log database off the production path

SQLite's recovery pipeline reconstructed a standalone database in the Linux recovery workspace:

```text
/home/lycorica/workspace/tmp/bifrost-db-recovery-20260721-233000/rebuild/logs.db.recovered
```

Recovered baseline:

```text
logs rows:       4,196
unique log IDs:  4,196
oldest:          2026-07-02 20:05:18.785405431+00:00
newest:          2026-07-22 03:26:20.293311332+00:00
migration rows:  62
```

The recovered database contained the four required tables (`logs`, `migrations`, `async_jobs`, and `mcp_tool_logs`) and 47 indexes. Its offline `PRAGMA quick_check` returned `ok`.

### 2. Stage the recovered file on the Windows volume

The validated recovered database was copied to:

```text
C:\bifrost\data\logs.db.repaired.new
```

Staging occurred while production continued running. This kept the final outage limited to index repair and atomic file renames.

### 3. Repair the rate-limit indexes and switch databases

During one guarded stop window, the repair script performed:

```sql
REINDEX idx_governance_rate_limits_token_last_reset;
REINDEX idx_governance_rate_limits_request_last_reset;
PRAGMA wal_checkpoint(TRUNCATE);
```

It then renamed the active damaged log database to `logs.db.corrupt-20260722-173134`, removed stale log WAL/SHM files, renamed `logs.db.repaired.new` to `logs.db`, and restarted `bifrost` in `finally`.

Measured production stop time:

```text
1.19 seconds
```

## End-to-end validation

### Service health

```text
GET http://localhost:8081/health
{"components":{"db_pings":"ok"},"status":"ok"}
```

The container returned to `running | healthy` with restart count zero.

### Database checks

`config.db`:

```text
PRAGMA integrity_check(30);
ok
```

`logs.db` was checked offline while the container was guarded by automatic restart:

```text
PRAGMA quick_check;
ok
```

### Runtime error observation

After cutover and restart, a 35-second observation window contained none of:

```text
database disk image is malformed
disk I/O error
batch insert failed
individual insert failed
payload-stripped insert failed
failed to dump rate limits
```

This also confirms that the repaired rate-limit indexes work under Bifrost's periodic writer, rather than merely passing a static SQLite check.

### Structured log write

A valid production request was sent through the same Cursor-compatible endpoint used by normal traffic:

```text
POST /cursor/chat/completions
model: cpa/gpt-5.4
response: HTTP 200, output "OK"
```

The new `logs.db` persisted the corresponding structured record:

```text
id:                73091b30-ddd7-461e-a5d6-0c5210afae3c
provider:          cpa
model:             gpt-5.4
status:            success
selected_key_name: cpa-key-1
prompt_tokens:     316
completion_tokens: 5
total_tokens:      321
```

Subsequent Cursor requests also appeared with provider, model, status, selected key, and token usage, proving that log insertion continued after the synthetic verification request.

### Current record count

At final report generation:

```text
logs rows:       4,314
unique log IDs:  4,314
oldest:          2026-07-02 20:05:18.785405431+00:00
newest:          2026-07-22 23:20:37.954638186+00:00
migration rows:  62
```

## Data preservation and known gap

The active repaired database began with 4,196 recovered historical rows and now accepts new writes. A diagnostic view of the damaged live database had previously found 4,233 distinct readable IDs, but a sequential copy failed on a malformed page and could not establish a complete, transactionally consistent total.

Consequently, this repair does not claim zero historical loss. Requests written after the recovered database's newest baseline timestamp and before the cutover may be absent from the repaired store. The replaced 4.4 GB database remains at `logs.db.corrupt-20260722-173134` for a future targeted salvage pass. It must not be deleted until retention requirements are reviewed.

## Root-cause assessment

The direct technical causes were secondary-index inconsistency in `config.db` and B-tree corruption in `logs.db`. The evidence does not identify a single initiating event. Plausible contributors include abrupt container/database interruption, inconsistent WAL handling across Docker Desktop and the Windows-mounted SQLite files, or prior concurrent access from WSL while the database was active.

Operationally, the important condition was running high-write SQLite databases on a Windows bind mount while inspecting and copying them from WSL. Future backups should stop the database writer or use SQLite's online backup API from the same filesystem/runtime context.

## Follow-up recommendations

1. Keep both the cold backup and `logs.db.corrupt-20260722-173134` until the missing interval is no longer needed.
2. Add a scheduled `PRAGMA quick_check` against a snapshot, not the active files.
3. Alert on the first `database disk image is malformed`, `disk I/O error`, or log insert retry; inference HTTP status alone is insufficient.
4. Rotate or archive `logs.db` before it again grows beyond several gigabytes.
5. Avoid direct WSL SQLite reads of an active Windows-mounted WAL database when an API query or stopped snapshot is available.
