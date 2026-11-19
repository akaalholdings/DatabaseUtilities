# Database Status

`usp_GetDBStatus.sql` creates the stored procedure `DBATools.usp_GetDBStatus`. The procedure shows what is happening on one Azure SQL Database now: a health summary with findings, then blocking, requests, waits, resources, memory, tempdb, transactions, IO, top queries, sessions and configuration.

The procedure only reads. It writes to its own temp tables and to no other object.

Status:

- Version 2.1.0 ran on one Azure SQL Database (Hyperscale) on 2026-11-19. The four test commands below completed and MESSAGES held no `ERROR` row.
- That database had no blocking and no worker starvation at the time. The blocking tree and the THREADPOOL path have therefore not yet run with data.
- Version 2.1.1 fixed what that run showed (see the header of the script). It ran on the same database on the same day: the four test commands completed, MESSAGES held no `ERROR` row, and each fix was visible in the results.
- Version 2.1.2 added the result `session_waits_sampled`. One sampled run (`@section = 'summary,waits,requests', @sample_seconds = 60`) on the same database completed with no error. For one running parallel query the new result showed 884 seconds of parallelism waits in the 60 seconds; the database wait statistics showed 2.5 seconds in total. The other sections did not run again with 2.1.2.
- Version 2.1.3 added one finding (a large memory grant that is mostly unused). It has not run on Azure SQL Database.
- Version 2.2.0 adds plan forcing, blocking history, statements completed during a sample, several findings and a stable code per finding (see the header of the script). It parses without errors and has not yet run on Azure SQL Database. Run the test below before you rely on it.

## Deploy

1. Connect to the database itself, not to `master`.
2. The schema `DBATools` must exist. The script does not create it.
3. Script the current procedure out of the database and keep the file. That file is your rollback.
4. Execute `usp_GetDBStatus.sql`. It uses `CREATE OR ALTER`, so you can run it again.

Deploy it in each database that you want to inspect.

## Run

```sql
EXEC DBATools.usp_GetDBStatus;
```

```sql
EXEC DBATools.usp_GetDBStatus @help = 1;
```

`@help = 1` lists every parameter and every section. The main parameters:

| Parameter | Default | Use |
| --- | --- | --- |
| `@effort` | `fast` | `slow` adds Query Store, deadlocks, statistics and index usage |
| `@output` | `normal` | `json`, `text` or `textchunks` for tools that read JSON |
| `@section` | `all` | Comma-separated list of sections. `fragmentation` and `buffer` run only when you name them |
| `@sample_seconds` | `0` | 1 to 300: wait that long and report deltas for waits, file IO, counters and requests. For waits, read `session_waits_sampled`: the database wait statistics get the waits of a request only after it ends |
| `@lookback_minutes` | `60` | Window for the plan cache, Query Store and deadlocks |
| `@include_plans` | `0` | `1` adds query plans |

The caller needs `VIEW DATABASE STATE`. When the caller cannot read the source of a result, that result shows the error in MESSAGES and the other results still return.

## Test after deploy

Run these five commands in the database. The MESSAGES result (the last one) must hold no `ERROR` row. The same commands are in the header comment of the procedure.

```sql
EXEC DBATools.usp_GetDBStatus @debug = 1;
```

```sql
EXEC DBATools.usp_GetDBStatus @effort = 'slow', @sample_seconds = 10, @debug = 1;
```

```sql
EXEC DBATools.usp_GetDBStatus @section = 'blocking,waits,transactions', @output = 'json';
```

```sql
EXEC DBATools.usp_GetDBStatus @section = 'transactions';
```

```sql
EXEC DBATools.usp_GetDBStatus @section = 'requests,config', @include_plans = 1, @debug = 1;
```

- Command 3: to test the blocking tree, hold an open `UPDATE` in one session and block two other sessions behind it. `blocking_tree` must show one HEAD and each waiter once.
- Command 4: in `log_usage`, `log_max_mb` must be a plausible log limit for the service objective.
- Optional step 6 (in the header of the script): create the `blocking` Extended Events session, block one session behind another for 30 seconds or more, and run command 2. `blocking_tree` must show the blocker as HEAD, and `blocking_history` lists the block when the service has raised a report.
- When you report a problem, send the full output of commands 2 and 5, with real names removed.
- Command 5: `requests` has the columns `query_plan` and `plan_parameters`; `plan_forcing` lists forced plans and Query Store hints, or says there are none. MESSAGES shows `plan forcing collection: n ms`.

## Static check

`tsql_parse_check.py` parses the script with Microsoft ScriptDom (TSql170, Azure engine type). It proves the syntax only. It does not check object or column names; only a run on Azure SQL Database does that.

```bash
uv run --no-project --with pythonnet==3.0.5 python tsql_parse_check.py usp_GetDBStatus.sql
```

It needs macOS with the VS Code `mssql` extension and the VS Code .NET runtime. Expected output: `usp_GetDBStatus.sql: 0 parse error(s)`.

## Known limits

- Azure SQL Database only. The procedure stops on any other engine edition.
- Catalog views do not honour `READ UNCOMMITTED`. When a session holds a schema modification lock, each statement that reads the catalog can wait up to 5 seconds (`LOCK_TIMEOUT`) before it reports the error and continues.
- The blocking tree shows each session under one blocker. `also_blocked_by` lists the others.
- `holds_resources` in `open_transactions` looks at this database only. A transaction that wrote only to tempdb (temp tables) shows 0 there.
- Deadlocks and blocking history are read only from a running database Extended Events session with a `ring_buffer` target. The procedure prints the script to create one when none exists.
- `plan_cache_sampled` and the database wait statistics change only when a statement ends. For a statement that still runs, read `requests` and `session_waits_sampled`.
- The identity check covers `tinyint`, `smallint`, `int` and `bigint` columns that count up.
- Index usage counters cover only the time since the last restart, failover or change of service objective, and only this replica.
