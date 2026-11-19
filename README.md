# DatabaseUtilities

T-SQL utilities for Azure SQL Database.

| Path | What it is | Changes data? |
| --- | --- | --- |
| [`DBATools/`](DBATools/) | Stored procedure `DBATools.usp_GetDBStatus`: what is happening on one Azure SQL Database now (health summary and findings, blocking, requests, waits, resources, memory, tempdb, transactions, IO, top queries, sessions, configuration) | No. The script creates one procedure; the procedure only reads |

## Quickstart

1. Connect to the database itself, not to `master`. The schema `DBATools` must exist.
2. Execute [`DBATools/usp_GetDBStatus.sql`](DBATools/usp_GetDBStatus.sql). It uses `CREATE OR ALTER`, so you can run it again.
3. Run the procedure:

```sql
EXEC DBATools.usp_GetDBStatus;
```

```sql
EXEC DBATools.usp_GetDBStatus @help = 1;
```

`@help = 1` lists every parameter and every section. [`DBATools/README.md`](DBATools/README.md) has the parameters, the test to run after you deploy, and the known limits.

## Status

Versions 2.1.0 and 2.1.1 of `usp_GetDBStatus` ran on one Azure SQL Database (Hyperscale) on 2026-11-19 with no error. Version 2.1.2 adds one result; it parses without errors (Microsoft ScriptDom, TSql170) and has not yet run on Azure SQL Database. Run the test in [`DBATools/README.md`](DBATools/README.md) before you rely on it. Version 2.0.0 is the first commit of the file.

## How to test

- On a database: the four commands under "Test after deploy" in [`DBATools/README.md`](DBATools/README.md). They are also in the header comment of the procedure.
- Static syntax check, on macOS with the VS Code `mssql` extension:

```bash
cd DBATools && uv run --no-project --with pythonnet==3.0.5 python tsql_parse_check.py usp_GetDBStatus.sql
```

Expected output: `usp_GetDBStatus.sql: 0 parse error(s)`.

## Deploy

There is no pipeline. You deploy a script by hand in each database. Nothing in this repository runs on a schedule or connects to a database.

## Known limits

- Azure SQL Database only (engine edition 5).
- No licence file yet: all rights are reserved until one is added.
