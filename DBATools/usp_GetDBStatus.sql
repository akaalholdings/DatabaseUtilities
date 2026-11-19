SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

/*
    DBATools.usp_GetDBStatus 2.2.0 (2026-11-19)

    Purpose        Shows what is happening on one Azure SQL Database now: health summary and
                   findings, blocking, requests, waits, resources, memory, tempdb, transactions,
                   IO, top queries, sessions and configuration.
    Target         Azure SQL Database (EngineEdition 5). Deploy it in each database to inspect and
                   run it there.
    Class          Idempotent (CREATE OR ALTER). The procedure only reads; it writes to its own
                   temp tables.
    Prerequisites  The schema DBATools exists. The caller can read the DMVs (VIEW DATABASE STATE).
                   A result whose source the caller cannot read shows the error in MESSAGES; the
                   other results still return.
    Rollback       Deploy version 2.0.0. Script the current procedure out of the database before
                   you deploy this one, so that you have it.
    Help           EXEC DBATools.usp_GetDBStatus @help = 1;

    Test after deploy
    Run these five commands in the database. The MESSAGES result (the last one) must hold no
    ERROR row.

        -- 1. Default run. @debug = 1 adds the time of each result to MESSAGES.
        EXEC DBATools.usp_GetDBStatus @debug = 1;

        -- 2. Every slow section, with deltas measured over 10 seconds.
        EXEC DBATools.usp_GetDBStatus @effort = 'slow', @sample_seconds = 10, @debug = 1;

        -- 3. JSON output. Each result is one JSON document. To test the blocking tree, hold an
        --    open UPDATE in one session and block two other sessions behind it: blocking_tree
        --    must show one HEAD and each waiter once.
        EXEC DBATools.usp_GetDBStatus @section = 'blocking,waits,transactions', @output = 'json';

        -- 4. log_usage: log_max_mb must be a plausible log limit for the service objective.
        EXEC DBATools.usp_GetDBStatus @section = 'transactions';

        -- 5. Plans and plan forcing: requests gets query_plan and plan_parameters, and plan_forcing
        --    lists forced plans and Query Store hints.
        EXEC DBATools.usp_GetDBStatus @section = 'requests,config', @include_plans = 1, @debug = 1;

        -- 6. Optional: blocking_history and the blocking tree with real blocking.
        --    Create the session once (up to 4 MB of memory, it keeps the most recent events):
        --        CREATE EVENT SESSION [blocking] ON DATABASE
        --            ADD EVENT sqlserver.blocked_process_report
        --            ADD TARGET package0.ring_buffer
        --            WITH (STARTUP_STATE = ON, MAX_MEMORY = 4 MB);
        --        ALTER EVENT SESSION [blocking] ON DATABASE STATE = START;
        --    Session A: BEGIN TRANSACTION, then UPDATE one row of a test table. Do not commit.
        --    Session B: UPDATE the same row. It waits.
        --    After 30 seconds or more, run command 2 in a third session: blocking_tree must show
        --    session A as HEAD and session B under it, and blocking_history must list the block
        --    when the service has raised a report. Then ROLLBACK in session A.
        --    To remove the session: DROP EVENT SESSION [blocking] ON DATABASE;

    When you report a problem, send the full output of commands 2 and 5 (all results and the
    Messages tab). Remove real names first.

    Changes in 2.2.0
    Ideas for these checks come from the First Responder Kit (Brent Ozar Unlimited), DarlingData
    (Erik Darling) and FreeSQLServerScripts (Kendra Little). No code was copied.
    - plan_forcing (config section): forced plans and Query Store hints, those that failed to
      apply first, with the command that unforces the plan or clears the hint. Finding
      PLAN_FORCING_FAILED.
    - New findings: a request that is rolling back; identity columns at 90 % or more of their
      range; client cancellations during the sample; slow data file reads; waits for compile
      memory; IO retries; recompilation rate; engine started in the last 60 minutes; statistics
      updated in the last 15 minutes (stats section).
    - Idle transactions: the evidence counts implicit transactions.
    - requests: plan_parameters (compiled and runtime parameter values) with @include_plans = 1.
    - blocking_tree: notes column with the likely cause (compile lock, schema lock, range lock,
      reader blocked by writer, isolation level of the blocker, implicit transactions).
    - blocking_history (blocking section, slow effort): blocks reported by blocked_process_report
      events in a database Extended Events session, including blocks that have ended.
    - plan_cache_sampled (queries section, with @sample_seconds): statements that completed during
      the sample, by CPU and by executions.
    - query_store_top: note when the CPU of one plan differs widely between executions.
    - findings: a stable code for each finding (column code).

    Changes in 2.1.3 (from the run of 2.1.2 on Azure SQL Database)
    - New finding: a query that has held a memory grant of 1 GB or more for at least 60 seconds
      and has used less than 10 % of it. MEDIUM when the grant is 20 % or more of the memory the
      user pool can grant, LOW from 5 %. The run showed one query with a 60 GB grant (24 % of
      the pool) that used 1.2 GB, and no finding.

    Changes in 2.1.2 (from the run of 2.1.1 on Azure SQL Database)
    - New result session_waits_sampled (with @sample_seconds): the waits of the sessions in this
      database during the sample, from sys.dm_exec_session_wait_stats. The database wait
      statistics (wait_stats) showed 38 ms of waits in a 10-second sample while 33 tasks of
      running parallel queries were waiting: a request's waits reached them only after the
      request ended. The summary and the governance finding now use the larger of the two
      sources for each wait type.

    Changes in 2.1.1 (from the first run of 2.1.0 on Azure SQL Database)
    - Idle transactions: a session that is idle with an open transaction is a HIGH or MEDIUM
      finding only when the transaction wrote log, reads under SNAPSHOT, keeps shared locks
      (REPEATABLE READ, SERIALIZABLE) or blocks others. A driver with autocommit off leaves
      transactions open that have done no work; they are now one LOW finding, and they no longer
      count as the oldest transaction. open_transactions has the new column holds_resources.
    - tempdb by session: pages of dropped temp tables whose deallocation is deferred are no
      longer counted as in use.
    - Wait catalog: HTBUILD_*, HTDELETE_*, BMP* (batch mode) and SOS_PHYS_PAGE_CACHE (memory)
      have a category and an explanation. They were "Other".
    - waits_now: a parallel query that waits on its own threads no longer shows itself as blocker.
    - replicas: the text no longer says that only the local replica is visible when a secondary
      is listed, and it says that the role of a geo-replication link is the role of this database.

    Changes in 2.1.0
    - Blocking tree: built breadth-first, so each session appears once. 2.0.0 followed every
      path, which grows exponentially when sessions have several blockers (latch convoys), and
      it reported chains deeper than 50 levels as a blocking cycle. New column also_blocked_by.
    - THREADPOOL: tasks that wait for a worker thread have no session yet. 2.0.0 dropped them, so
      the worker starvation finding could not see them. They are now counted and shown in waits_now.
    - Log space: findings compare used log with the maximum log size, not with the current size
      of a log file that still can grow. log_usage has log_max_mb and log_used_pct_of_max.
    - Sessions: sys.dm_exec_connections is read once, not once per session.
    - Stale statistics: the 20 % threshold applies below compatibility level 130.
    - The lookback window ends when the live snapshot is taken, not before the sampling wait.
*/
CREATE OR ALTER PROCEDURE [DBATools].[usp_GetDBStatus]
    @effort nvarchar(10) = N'fast',             /* fast | slow                                           */
    @output nvarchar(10) = N'normal',           /* normal | json | text | textchunks                     */
    @section nvarchar(400) = N'all',            /* comma-separated list, see @help = 1                   */
    @sample_seconds int = 0,                    /* 0 = point in time; 1-300 = also measure deltas        */
    @top_n int = 25,                            /* rows per top-N list (1-1000)                          */
    @long_running_seconds int = 30,             /* request age that counts as long running              */
    @lookback_minutes int = 60,                 /* plan cache / Query Store / deadlock window (1-1440)   */
    @include_plans bit = 0,                     /* 1 = add query plans (live plan when available)        */
    @help bit = 0,
    @debug bit = 0,
    @version varchar(30) = NULL OUTPUT,
    @version_date datetime = NULL OUTPUT
WITH RECOMPILE
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;
    SET ANSI_WARNINGS ON;
    SET ARITHABORT ON;
    SET CONCAT_NULL_YIELDS_NULL ON;
    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
    SET LOCK_TIMEOUT 5000;
    SET DEADLOCK_PRIORITY LOW;

    SELECT
        @version = '2.2.0',
        @version_date = '20261119';

    /* ============================================================================================
       Help
       ============================================================================================ */
    IF @help = 1
    BEGIN
        PRINT N'DBATools.usp_GetDBStatus v2.2.0 - what is happening on this Azure SQL Database right now.';
        PRINT N'Run it in the database you want to inspect. Everything it does is read-only.';

        SELECT
            parameter_name = p.parameter_name,
            data_type = p.data_type,
            default_value = p.default_value,
            description = p.description
        FROM
        (
            VALUES
                (1, N'@effort', N'nvarchar(10)', N'fast', N'fast = live snapshot sections. slow = also Query Store, deadlocks (XE ring buffer), statistics, index usage and raw resource samples.'),
                (2, N'@output', N'nvarchar(10)', N'normal', N'normal = one grid per result. json = one JSON document per result. text = one row per result with JSON. textchunks = JSON split into 3,900-character chunks.'),
                (3, N'@section', N'nvarchar(400)', N'all', N'Comma-separated sections (see next result). all = every fast section, plus slow sections when @effort = slow. Explicit-only sections (buffer, fragmentation) must be named.'),
                (4, N'@sample_seconds', N'int', N'0', N'0 = point-in-time snapshot. 1-300 = wait N seconds and report deltas for wait stats, file IO, perf counters and per-request CPU/reads.'),
                (5, N'@top_n', N'int', N'25', N'Rows returned by each top-N list (1-1000).'),
                (6, N'@long_running_seconds', N'int', N'30', N'Requests running at least this long are flagged as long running.'),
                (7, N'@lookback_minutes', N'int', N'60', N'Window used for plan cache, Query Store and deadlock history (1-1440).'),
                (8, N'@include_plans', N'bit', N'0', N'1 = return query plans for requests and top queries (live in-flight plan when available), and the compiled and runtime parameter values of running requests. Adds overhead.'),
                (9, N'@help', N'bit', N'0', N'1 = show this help and exit.'),
                (10, N'@debug', N'bit', N'0', N'1 = print generated SQL and report the timing of every result in MESSAGES.'),
                (11, N'@version', N'varchar(30) OUTPUT', N'NULL', N'Returns the procedure version.'),
                (12, N'@version_date', N'datetime OUTPUT', N'NULL', N'Returns the procedure version date.')
        ) AS p (sort_order, parameter_name, data_type, default_value, description)
        ORDER BY
            p.sort_order;

        SELECT
            section_name = s.section_name,
            runs_when = s.runs_when,
            results = s.results,
            description = s.description
        FROM
        (
            VALUES
                (1, N'summary', N'fast', N'summary, findings', N'Health rollup (CRITICAL / WARNING / ATTENTION / OK) and prioritized findings with evidence, next steps and a stable code. Alias: findings.'),
                (2, N'blocking', N'fast', N'blocking_tree, blocking_history (slow)', N'Who blocks whom: head blockers first, sleeping blockers with open transactions, decoded wait resources, locks held by head blockers, likely cause. With @effort = slow: blocks that the service reported in a database XE session (blocked_process_report, ring_buffer target), including blocks that have ended.'),
                (3, N'requests', N'fast', N'requests', N'Active requests: elapsed, waits, CPU/reads (and deltas when sampled), memory grant, tempdb, transaction, statement and input buffer.'),
                (4, N'waits', N'fast', N'waits_now, wait_stats, session_waits_sampled (sampled), index_lock_waits', N'Current waits, database wait stats (cumulative or sampled delta) with categories and explanations, session waits during the sample (requests that still run included), and lock/latch waits by index.'),
                (5, N'resources', N'fast', N'resource_stats, resource_samples (slow), governance, schedulers, workload_group, perf_counters', N'Service-objective utilization (dm_db_resource_stats), resource governance limits, workers, schedulers and key performance counters.'),
                (6, N'memory', N'fast', N'memory_overview, memory_grants, resource_semaphores, memory_clerks, memory_health', N'Memory grants (pending first), grant semaphores, top memory clerks and memory health history.'),
                (7, N'tempdb', N'fast', N'tempdb_space, tempdb_sessions', N'tempdb space by consumer type and the sessions using the most tempdb.'),
                (8, N'transactions', N'fast', N'open_transactions, version_store, log_usage, replicas', N'Open transactions (oldest first), version store health (ADR persistent version store and tempdb) and what holds cleanup back, transaction log usage and truncation holdups, HA replica state and geo-replication links.'),
                (9, N'io', N'fast', N'file_io', N'File IO latency for data, log and tempdb (Hyperscale: page servers and local SSD cache), including Azure IO governance queuing (cumulative or sampled delta).'),
                (10, N'queries', N'fast', N'plan_cache_top, plan_cache_sampled (sampled)', N'Top statements in the plan cache by CPU and by reads, aggregated by query_hash, executed within @lookback_minutes. With @sample_seconds: the statements that completed during the sample. Alias: plancache.'),
                (11, N'sessions', N'fast', N'sessions_by_app', N'User sessions grouped by program, host and login: running, sleeping, blocked, blocking and idle-in-transaction counts.'),
                (12, N'config', N'fast', N'configuration, tuning_recommendations, plan_forcing', N'Service objective, database options, database scoped configurations, automatic tuning and Query Store options, automatic tuning recommendations (plan regressions and index suggestions), and forced plans and Query Store hints with those that failed to apply.'),
                (13, N'querystore', N'slow', N'query_store_top, query_store_waits', N'Query Store top queries (aggregated per query) and wait categories within @lookback_minutes. Alias: qs.'),
                (14, N'deadlocks', N'slow', N'deadlocks', N'Deadlock graphs from a running database XE session with a ring_buffer target. Prints a setup script when none exists.'),
                (15, N'stats', N'slow', N'stale_statistics', N'Statistics with the most modifications relative to their auto-update threshold.'),
                (16, N'indexes', N'slow', N'index_usage', N'Most read, most written and unused (written, never read) indexes.'),
                (17, N'fragmentation', N'explicit only', N'index_fragmentation', N'Index fragmentation (LIMITED scan, > 2,500 pages). Expensive on large databases.'),
                (18, N'buffer', N'explicit only', N'buffer_usage', N'Buffer pool usage by object. Expensive with a large buffer pool.')
        ) AS s (sort_order, section_name, runs_when, results, description)
        ORDER BY
            s.sort_order;

        RETURN;
    END;

    /* ============================================================================================
       Validation
       ============================================================================================ */
    DECLARE
        @effort_l nvarchar(10) = LOWER(LTRIM(RTRIM(ISNULL(@effort, N'fast')))),
        @output_l nvarchar(10) = LOWER(LTRIM(RTRIM(ISNULL(@output, N'normal')))),
        @engine_edition int = CONVERT(int, SERVERPROPERTY('EngineEdition'));

    IF @engine_edition <> 5
    BEGIN
        RAISERROR(N'usp_GetDBStatus supports Azure SQL Database only (EngineEdition 5). This server reports EngineEdition %d.', 16, 1, @engine_edition);
        RETURN;
    END;

    IF @effort_l NOT IN (N'fast', N'slow')
    BEGIN
        RAISERROR(N'Invalid @effort value. Use ''fast'' or ''slow''.', 16, 1);
        RETURN;
    END;

    IF @output_l NOT IN (N'normal', N'json', N'text', N'textchunks')
    BEGIN
        RAISERROR(N'Invalid @output value. Use ''normal'', ''json'', ''text'', or ''textchunks''.', 16, 1);
        RETURN;
    END;

    SET @sample_seconds = ISNULL(@sample_seconds, 0);

    IF @sample_seconds < 0 OR @sample_seconds > 300
    BEGIN
        RAISERROR(N'Invalid @sample_seconds value. Use 0 (no sampling) to 300.', 16, 1);
        RETURN;
    END;

    SELECT
        @top_n =
            CASE
                WHEN @top_n IS NULL THEN 25
                WHEN @top_n < 1 THEN 1
                WHEN @top_n > 1000 THEN 1000
                ELSE @top_n
            END,
        @long_running_seconds =
            CASE
                WHEN @long_running_seconds IS NULL OR @long_running_seconds < 0 THEN 30
                ELSE @long_running_seconds
            END,
        @lookback_minutes =
            CASE
                WHEN @lookback_minutes IS NULL THEN 60
                WHEN @lookback_minutes < 1 THEN 1
                WHEN @lookback_minutes > 1440 THEN 1440
                ELSE @lookback_minutes
            END,
        @include_plans = ISNULL(@include_plans, 0),
        @debug = ISNULL(@debug, 0);

    /* Section list: comma (or ; |) separated, case and space insensitive, with a few aliases */
    DECLARE @sections table
    (
        section_name nvarchar(50) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY
    );

    DECLARE
        @section_list nvarchar(500),
        @comma int,
        @token nvarchar(500),
        @bad_sections nvarchar(500);

    SET @section_list =
        LOWER
        (
            REPLACE(REPLACE(REPLACE(REPLACE(
                ISNULL(NULLIF(LTRIM(RTRIM(@section)), N''), N'all'),
            N' ', N''), NCHAR(9), N''), N';', N','), N'|', N',')
        ) + N',';

    WHILE LEN(@section_list) > 0
    BEGIN
        SET @comma = CHARINDEX(N',', @section_list);
        SET @token = LEFT(@section_list, @comma - 1);
        SET @section_list = SUBSTRING(@section_list, @comma + 1, 500);

        SET @token =
            CASE @token
                WHEN N'findings' THEN N'summary'
                WHEN N'qs' THEN N'querystore'
                WHEN N'plancache' THEN N'queries'
                WHEN N'deadlock' THEN N'deadlocks'
                WHEN N'index' THEN N'indexes'
                WHEN N'statistics' THEN N'stats'
                WHEN N'transaction' THEN N'transactions'
                WHEN N'wait' THEN N'waits'
                WHEN N'request' THEN N'requests'
                WHEN N'session' THEN N'sessions'
                WHEN N'resource' THEN N'resources'
                ELSE @token
            END;

        IF  @token <> N''
        AND NOT EXISTS (SELECT 1/0 FROM @sections AS s WHERE s.section_name = LEFT(@token, 50))
        BEGIN
            INSERT @sections (section_name) VALUES (LEFT(@token, 50));
        END;
    END;

    SELECT
        @bad_sections = STRING_AGG(s.section_name, N', ')
    FROM @sections AS s
    WHERE s.section_name NOT IN
    (
        N'all', N'summary', N'blocking', N'requests', N'waits', N'resources', N'memory', N'tempdb',
        N'transactions', N'io', N'queries', N'sessions', N'config', N'querystore', N'deadlocks',
        N'stats', N'indexes', N'fragmentation', N'buffer'
    );

    IF @bad_sections IS NOT NULL
    BEGIN
        RAISERROR(N'Unknown @section value(s): %s. Valid values: all, summary, blocking, requests, waits, resources, memory, tempdb, transactions, io, queries, sessions, config, querystore, deadlocks, stats, indexes, fragmentation, buffer.', 16, 1, @bad_sections);
        RETURN;
    END;

    DECLARE
        @slow bit = CASE WHEN @effort_l = N'slow' THEN 1 ELSE 0 END,
        @do_summary bit,
        @do_blocking bit,
        @do_requests bit,
        @do_waits bit,
        @do_resources bit,
        @do_memory bit,
        @do_tempdb bit,
        @do_transactions bit,
        @do_io bit,
        @do_queries bit,
        @do_sessions bit,
        @do_config bit,
        @do_querystore bit,
        @do_deadlocks bit,
        @do_stats bit,
        @do_indexes bit,
        @do_fragmentation bit,
        @do_buffer bit;

    SELECT
        @do_summary = MAX(CASE WHEN s.section_name IN (N'all', N'summary') THEN 1 ELSE 0 END),
        @do_blocking = MAX(CASE WHEN s.section_name IN (N'all', N'blocking') THEN 1 ELSE 0 END),
        @do_requests = MAX(CASE WHEN s.section_name IN (N'all', N'requests') THEN 1 ELSE 0 END),
        @do_waits = MAX(CASE WHEN s.section_name IN (N'all', N'waits') THEN 1 ELSE 0 END),
        @do_resources = MAX(CASE WHEN s.section_name IN (N'all', N'resources') THEN 1 ELSE 0 END),
        @do_memory = MAX(CASE WHEN s.section_name IN (N'all', N'memory') THEN 1 ELSE 0 END),
        @do_tempdb = MAX(CASE WHEN s.section_name IN (N'all', N'tempdb') THEN 1 ELSE 0 END),
        @do_transactions = MAX(CASE WHEN s.section_name IN (N'all', N'transactions') THEN 1 ELSE 0 END),
        @do_io = MAX(CASE WHEN s.section_name IN (N'all', N'io') THEN 1 ELSE 0 END),
        @do_queries = MAX(CASE WHEN s.section_name IN (N'all', N'queries') THEN 1 ELSE 0 END),
        @do_sessions = MAX(CASE WHEN s.section_name IN (N'all', N'sessions') THEN 1 ELSE 0 END),
        @do_config = MAX(CASE WHEN s.section_name IN (N'all', N'config') THEN 1 ELSE 0 END),
        @do_querystore = MAX(CASE WHEN s.section_name = N'querystore' OR (s.section_name = N'all' AND @slow = 1) THEN 1 ELSE 0 END),
        @do_deadlocks = MAX(CASE WHEN s.section_name = N'deadlocks' OR (s.section_name = N'all' AND @slow = 1) THEN 1 ELSE 0 END),
        @do_stats = MAX(CASE WHEN s.section_name = N'stats' OR (s.section_name = N'all' AND @slow = 1) THEN 1 ELSE 0 END),
        @do_indexes = MAX(CASE WHEN s.section_name = N'indexes' OR (s.section_name = N'all' AND @slow = 1) THEN 1 ELSE 0 END),
        @do_fragmentation = MAX(CASE WHEN s.section_name = N'fragmentation' THEN 1 ELSE 0 END),
        @do_buffer = MAX(CASE WHEN s.section_name = N'buffer' THEN 1 ELSE 0 END)
    FROM @sections AS s;

    IF @effort_l = N'fast'
        PRINT 'EFFORT_MODE=FAST';
    ELSE
        PRINT 'EFFORT_MODE=SLOW';

    /* ============================================================================================
       Variables
       ============================================================================================ */
    DECLARE
        @db_id int = DB_ID(),
        @db_name sysname = DB_NAME(),
        @run_start datetime2(7) = SYSDATETIME(),
        @now datetime = GETDATE(),
        @now_utc datetime = GETUTCDATE(),
        @window_start datetime,
        @window_start_dto datetimeoffset(7),
        @t0 datetime2(7),
        @rk nvarchar(60),
        @sql nvarchar(max),
        @msg nvarchar(4000),
        @delay char(8),
        @sample_start datetime2(7),
        @sample_end datetime2(7),
        @sample_s decimal(18, 3),
        @is_sampled bit = CASE WHEN @sample_seconds > 0 THEN 1 ELSE 0 END,
        @edition sysname,
        @service_objective sysname,
        @is_hyperscale bit = 0,
        @physical_db_name nvarchar(128),
        @rcsi bit,
        @primary_group_id int,
        @rg_max_workers int,
        @rg_max_sessions int,
        @rg_cpu_limit decimal(9, 2),
        @rg_max_log_rate_mbps decimal(18, 2),
        @rg_log_size_mb decimal(19, 1),
        @log_file_max_mb decimal(19, 1),
        @log_max_mb decimal(19, 1),
        @compat_level int,
        @blk_lvl int = 0,
        @blk_rows int = 0,
        @blk_max_lvl int = 990, /* sort_path is varchar(8000): 7 characters for the head + 8 per level */
        @instance_max_workers int,
        @instance_start datetime;

    /* ============================================================================================
       Working tables (all created up front so that every later reference resolves)
       ============================================================================================ */
    CREATE TABLE #messages
    (
        id int IDENTITY(1, 1) NOT NULL PRIMARY KEY,
        msg_type varchar(10) NOT NULL,
        section nvarchar(60) COLLATE DATABASE_DEFAULT NULL,
        message nvarchar(4000) COLLATE DATABASE_DEFAULT NOT NULL
    );

    CREATE TABLE #findings
    (
        id int IDENTITY(1, 1) NOT NULL PRIMARY KEY,
        severity_rank tinyint NOT NULL, /* 1 critical, 2 high, 3 medium, 4 low, 5 info */
        area nvarchar(40) COLLATE DATABASE_DEFAULT NOT NULL,
        finding nvarchar(400) COLLATE DATABASE_DEFAULT NOT NULL,
        evidence nvarchar(2000) COLLATE DATABASE_DEFAULT NULL,
        recommended_action nvarchar(2000) COLLATE DATABASE_DEFAULT NULL,
        see_section nvarchar(100) COLLATE DATABASE_DEFAULT NULL,
        code nvarchar(40) COLLATE DATABASE_DEFAULT NULL /* stable id of the check: the text of a finding changes, the code does not */
    );

    CREATE TABLE #emit
    (
        section_order int NOT NULL,
        section_key nvarchar(40) COLLATE DATABASE_DEFAULT NOT NULL,
        result_key nvarchar(60) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY,
        result_name nvarchar(300) COLLATE DATABASE_DEFAULT NOT NULL,
        table_name nvarchar(128) COLLATE DATABASE_DEFAULT NULL,
        empty_message nvarchar(400) COLLATE DATABASE_DEFAULT NULL,
        error_message nvarchar(4000) COLLATE DATABASE_DEFAULT NULL,
        duration_ms bigint NULL
    );

    CREATE TABLE #emit_cols
    (
        column_id int NOT NULL,
        column_name nvarchar(128) COLLATE DATABASE_DEFAULT NOT NULL,
        system_type_id int NOT NULL
    );

    CREATE TABLE #textout
    (
        id int IDENTITY(1, 1) NOT NULL PRIMARY KEY,
        section_name nvarchar(300) COLLATE DATABASE_DEFAULT NOT NULL,
        payload nvarchar(max) COLLATE DATABASE_DEFAULT NOT NULL
    );

    CREATE TABLE #sess
    (
        session_id int NOT NULL PRIMARY KEY,
        database_id int NULL,
        is_user_process bit NULL,
        status nvarchar(30) COLLATE DATABASE_DEFAULT NULL,
        login_name nvarchar(128) COLLATE DATABASE_DEFAULT NULL,
        host_name nvarchar(128) COLLATE DATABASE_DEFAULT NULL,
        program_name nvarchar(128) COLLATE DATABASE_DEFAULT NULL,
        client_interface_name nvarchar(32) COLLATE DATABASE_DEFAULT NULL,
        client_net_address nvarchar(48) COLLATE DATABASE_DEFAULT NULL,
        login_time datetime NULL,
        connect_time datetime NULL,
        last_request_start_time datetime NULL,
        last_request_end_time datetime NULL,
        cpu_time bigint NULL,
        memory_usage_pages bigint NULL,
        reads bigint NULL,
        writes bigint NULL,
        logical_reads bigint NULL,
        page_server_reads bigint NULL,
        open_transaction_count int NULL,
        transaction_isolation_level smallint NULL,
        lock_timeout int NULL,
        deadlock_priority int NULL,
        group_id int NULL,
        most_recent_sql_handle varbinary(64) NULL
    );

    CREATE TABLE #conn
    (
        session_id int NOT NULL PRIMARY KEY,
        client_net_address nvarchar(48) COLLATE DATABASE_DEFAULT NULL,
        connect_time datetime NULL,
        most_recent_sql_handle varbinary(64) NULL
    );

    CREATE TABLE #req
    (
        session_id int NOT NULL,
        request_id int NOT NULL,
        start_time datetime NULL,
        status nvarchar(30) COLLATE DATABASE_DEFAULT NULL,
        command nvarchar(32) COLLATE DATABASE_DEFAULT NULL,
        database_id int NULL,
        blocking_session_id int NULL,
        wait_type nvarchar(60) COLLATE DATABASE_DEFAULT NULL,
        wait_time_ms bigint NULL,
        last_wait_type nvarchar(60) COLLATE DATABASE_DEFAULT NULL,
        wait_resource nvarchar(256) COLLATE DATABASE_DEFAULT NULL,
        open_transaction_count int NULL,
        transaction_id bigint NULL,
        percent_complete real NULL,
        estimated_completion_time bigint NULL,
        cpu_time bigint NULL,
        total_elapsed_time bigint NULL,
        scheduler_id int NULL,
        reads bigint NULL,
        writes bigint NULL,
        logical_reads bigint NULL,
        page_server_reads bigint NULL,
        row_count bigint NULL,
        granted_query_memory_pages bigint NULL,
        transaction_isolation_level smallint NULL,
        nest_level int NULL,
        dop int NULL,
        parallel_worker_count int NULL,
        group_id int NULL,
        sql_handle varbinary(64) NULL,
        statement_start_offset int NULL,
        statement_end_offset int NULL,
        plan_handle varbinary(64) NULL,
        query_hash binary(8) NULL,
        query_plan_hash binary(8) NULL
    );

    CREATE TABLE #wt
    (
        waiting_task_address varbinary(8) NULL,
        session_id int NULL,
        exec_context_id int NULL,
        wait_duration_ms bigint NULL,
        wait_type nvarchar(60) COLLATE DATABASE_DEFAULT NULL,
        blocking_session_id int NULL,
        resource_description nvarchar(3072) COLLATE DATABASE_DEFAULT NULL,
        task_rank bigint NULL
    );

    CREATE TABLE #trn
    (
        session_id int NULL,
        transaction_id bigint NOT NULL,
        transaction_name nvarchar(32) COLLATE DATABASE_DEFAULT NULL,
        transaction_begin_time datetime NULL,
        transaction_type int NULL,
        transaction_state int NULL,
        dtc_state int NULL,
        is_user_transaction bit NULL,
        is_local bit NULL,
        db_tran_begin_time datetime NULL,
        db_tran_state int NULL,
        log_record_count bigint NULL,
        log_bytes_used bigint NULL,
        log_bytes_reserved bigint NULL,
        is_snapshot bit NULL,
        snapshot_elapsed_s bigint NULL,
        max_version_chain int NULL,
        holds_resources bit NULL
    );

    CREATE TABLE #grants
    (
        session_id int NULL,
        request_id int NULL,
        dop int NULL,
        request_time datetime NULL,
        grant_time datetime NULL,
        requested_memory_kb bigint NULL,
        granted_memory_kb bigint NULL,
        required_memory_kb bigint NULL,
        used_memory_kb bigint NULL,
        max_used_memory_kb bigint NULL,
        ideal_memory_kb bigint NULL,
        query_cost float NULL,
        timeout_sec int NULL,
        resource_semaphore_id int NULL,
        queue_id int NULL,
        wait_order int NULL,
        is_next_candidate bit NULL,
        wait_time_ms bigint NULL,
        pool_id int NULL,
        is_small bit NULL,
        reserved_worker_count int NULL,
        used_worker_count int NULL,
        sql_handle varbinary(64) NULL,
        plan_handle varbinary(64) NULL
    );

    CREATE TABLE #tsu
    (
        session_id int NOT NULL PRIMARY KEY,
        session_user_pages bigint NULL,
        session_internal_pages bigint NULL,
        task_user_pages bigint NULL,
        task_internal_pages bigint NULL
    );

    CREATE TABLE #waits_snap
    (
        sample_no tinyint NOT NULL,
        wait_type nvarchar(128) COLLATE DATABASE_DEFAULT NOT NULL,
        waiting_tasks_count bigint NULL,
        wait_time_ms bigint NULL,
        max_wait_time_ms bigint NULL,
        signal_wait_time_ms bigint NULL
    );

    CREATE TABLE #sess_waits_snap
    (
        sample_no tinyint NOT NULL,
        session_id int NOT NULL,
        wait_type nvarchar(128) COLLATE DATABASE_DEFAULT NOT NULL,
        waiting_tasks_count bigint NULL,
        wait_time_ms bigint NULL,
        signal_wait_time_ms bigint NULL
    );

    CREATE TABLE #file_snap
    (
        sample_no tinyint NOT NULL,
        database_id int NOT NULL,
        file_id int NOT NULL,
        num_of_reads bigint NULL,
        num_of_bytes_read bigint NULL,
        io_stall_read_ms bigint NULL,
        io_stall_queued_read_ms bigint NULL,
        num_of_writes bigint NULL,
        num_of_bytes_written bigint NULL,
        io_stall_write_ms bigint NULL,
        io_stall_queued_write_ms bigint NULL,
        size_on_disk_bytes bigint NULL
    );

    CREATE TABLE #perf_snap
    (
        sample_no tinyint NOT NULL,
        object_name nvarchar(128) COLLATE DATABASE_DEFAULT NOT NULL,
        counter_name nvarchar(128) COLLATE DATABASE_DEFAULT NOT NULL,
        instance_name nvarchar(128) COLLATE DATABASE_DEFAULT NULL,
        cntr_value bigint NULL,
        cntr_type int NULL
    );

    CREATE TABLE #qs_s1
    (
        plan_handle varbinary(64) NOT NULL,
        statement_start_offset int NOT NULL,
        statement_end_offset int NOT NULL,
        creation_time datetime NULL,
        execution_count bigint NULL,
        total_worker_time bigint NULL,
        total_elapsed_time bigint NULL,
        total_logical_reads bigint NULL
    );

    CREATE TABLE #req_sample1
    (
        session_id int NOT NULL,
        request_id int NOT NULL,
        start_time datetime NULL,
        cpu_time bigint NULL,
        logical_reads bigint NULL,
        reads bigint NULL,
        writes bigint NULL,
        page_server_reads bigint NULL
    );

    CREATE TABLE #blk_edges
    (
        waiter int NOT NULL,
        blocker int NOT NULL,
        wait_ms bigint NULL
    );

    CREATE TABLE #blk_nodes
    (
        node_order int NOT NULL,
        session_id int NOT NULL,
        blocked_by int NULL,
        head_session_id int NULL,
        lvl int NOT NULL,
        is_head bit NOT NULL,
        in_cycle bit NOT NULL,
        sort_path varchar(8000) NOT NULL
    );

    CREATE TABLE #blk_counts
    (
        session_id int NOT NULL PRIMARY KEY,
        direct_blocked int NOT NULL,
        total_blocked int NOT NULL,
        max_wait_ms bigint NULL
    );

    CREATE TABLE #wr
    (
        resource_text nvarchar(3072) COLLATE DATABASE_DEFAULT NOT NULL,
        resource_kind nvarchar(60) COLLATE DATABASE_DEFAULT NULL,
        res_db_id int NULL,
        res_object_id bigint NULL,
        res_hobt_id bigint NULL,
        res_alloc_unit_id bigint NULL,
        res_assoc_id bigint NULL,
        res_file_id int NULL,
        res_page_id bigint NULL,
        object_id int NULL,
        index_id int NULL,
        page_type nvarchar(64) COLLATE DATABASE_DEFAULT NULL,
        decoded nvarchar(1000) COLLATE DATABASE_DEFAULT NULL
    );

    CREATE TABLE #head_locks
    (
        session_id int NOT NULL PRIMARY KEY,
        locks_held nvarchar(4000) COLLATE DATABASE_DEFAULT NULL
    );

    CREATE TABLE #benign_waits
    (
        wait_type nvarchar(128) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY
    );

    CREATE TABLE #wait_cat
    (
        pattern nvarchar(128) COLLATE DATABASE_DEFAULT NOT NULL,
        priority tinyint NOT NULL,
        category nvarchar(60) COLLATE DATABASE_DEFAULT NOT NULL,
        explanation nvarchar(1000) COLLATE DATABASE_DEFAULT NOT NULL
    );

    /* ============================================================================================
       Reference data: benign waits and the wait catalog
       ============================================================================================ */
    INSERT #benign_waits (wait_type)
    SELECT DISTINCT
        v.wait_type
    FROM
    (
        VALUES
            (N'BROKER_EVENTHANDLER'), (N'BROKER_RECEIVE_WAITFOR'), (N'BROKER_TASK_STOP'), (N'BROKER_TO_FLUSH'),
            (N'BROKER_TRANSMITTER'), (N'CHECKPOINT_QUEUE'), (N'CHKPT'), (N'CLR_AUTO_EVENT'), (N'CLR_MANUAL_EVENT'),
            (N'CLR_SEMAPHORE'), (N'DBMIRROR_DBM_EVENT'), (N'DBMIRROR_EVENTS_QUEUE'), (N'DBMIRROR_WORKER_QUEUE'),
            (N'DBMIRRORING_CMD'), (N'DIRTY_PAGE_POLL'), (N'DISPATCHER_QUEUE_SEMAPHORE'), (N'EXECSYNC'), (N'FSAGENT'),
            (N'FT_IFTS_SCHEDULER_IDLE_WAIT'), (N'FT_IFTSHC_MUTEX'), (N'HADR_CLUSAPI_CALL'),
            (N'HADR_FILESTREAM_IOMGR_IOCOMPLETION'), (N'HADR_LOGCAPTURE_WAIT'), (N'HADR_NOTIFICATION_DEQUEUE'),
            (N'HADR_TIMER_TASK'), (N'HADR_WORK_QUEUE'), (N'HADR_FABRIC_CALLBACK'), (N'KSOURCE_WAKEUP'),
            (N'LAZYWRITER_SLEEP'), (N'LOGMGR_QUEUE'), (N'MEMORY_ALLOCATION_EXT'), (N'ONDEMAND_TASK_QUEUE'),
            (N'PARALLEL_REDO_DRAIN_WORKER'), (N'PARALLEL_REDO_LOG_CACHE'), (N'PARALLEL_REDO_TRAN_LIST'),
            (N'PARALLEL_REDO_WORKER_SYNC'), (N'PARALLEL_REDO_WORKER_WAIT_WORK'), (N'REDO_THREAD_PENDING_WORK'),
            (N'PREEMPTIVE_HADR_LEASE_MECHANISM'), (N'PREEMPTIVE_SP_SERVER_DIAGNOSTICS'), (N'PREEMPTIVE_ODBCOPS'),
            (N'PREEMPTIVE_OS_LIBRARYOPS'), (N'PREEMPTIVE_OS_COMOPS'), (N'PREEMPTIVE_OS_CRYPTOPS'),
            (N'PREEMPTIVE_OS_PIPEOPS'), (N'PREEMPTIVE_OS_AUTHENTICATIONOPS'), (N'PREEMPTIVE_OS_GENERICOPS'),
            (N'PREEMPTIVE_OS_VERIFYTRUST'), (N'PREEMPTIVE_OS_FILEOPS'), (N'PREEMPTIVE_OS_DEVICEOPS'),
            (N'PREEMPTIVE_OS_QUERYREGISTRY'), (N'PREEMPTIVE_OS_WRITEFILE'), (N'PREEMPTIVE_OS_FLUSHFILEBUFFERS'),
            (N'PREEMPTIVE_XE_CALLBACKEXECUTE'), (N'PREEMPTIVE_XE_DISPATCHER'), (N'PREEMPTIVE_XE_GETTARGETSTATE'),
            (N'PREEMPTIVE_XE_SESSIONCOMMIT'), (N'PREEMPTIVE_XE_TARGETINIT'), (N'PREEMPTIVE_XE_TARGETFINALIZE'),
            (N'PREEMPTIVE_XHTTP'), (N'PVS_PREALLOCATE'), (N'PWAIT_ALL_COMPONENTS_INITIALIZED'),
            (N'PWAIT_DIRECTLOGCONSUMER_GETNEXT'), (N'PWAIT_EXTENSIBILITY_CLEANUP_TASK'),
            (N'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP'), (N'QDS_ASYNC_QUEUE'),
            (N'QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP'), (N'QDS_SHUTDOWN_QUEUE'),
            (N'REQUEST_FOR_DEADLOCK_SEARCH'), (N'RESOURCE_QUEUE'), (N'SERVER_IDLE_CHECK'), (N'SLEEP_BPOOL_FLUSH'),
            (N'SLEEP_DBSTARTUP'), (N'SLEEP_DCOMSTARTUP'), (N'SLEEP_MASTERDBREADY'), (N'SLEEP_MASTERMDREADY'),
            (N'SLEEP_MASTERUPGRADED'), (N'SLEEP_MSDBSTARTUP'), (N'SLEEP_SYSTEMTASK'), (N'SLEEP_TASK'),
            (N'SLEEP_TEMPDBSTARTUP'), (N'SNI_HTTP_ACCEPT'), (N'SOS_WORK_DISPATCHER'), (N'SP_SERVER_DIAGNOSTICS_SLEEP'),
            (N'SQLTRACE_BUFFER_FLUSH'), (N'SQLTRACE_INCREMENTAL_FLUSH_SLEEP'), (N'SQLTRACE_WAIT_ENTRIES'),
            (N'UCS_SESSION_REGISTRATION'), (N'VDI_CLIENT_OTHER'), (N'WAIT_FOR_RESULTS'), (N'WAITFOR'),
            (N'WAITFOR_TASKSHUTDOWN'), (N'WAIT_XTP_HOST_WAIT'), (N'WAIT_XTP_OFFLINE_CKPT_NEW_LOG'),
            (N'WAIT_XTP_CKPT_CLOSE'), (N'WAIT_XTP_RECOVERY'), (N'XE_BUFFERMGR_ALLPROCESSED_EVENT'),
            (N'XE_DISPATCHER_JOIN'), (N'XE_DISPATCHER_WAIT'), (N'XE_LIVE_TARGET_TVF'), (N'XE_TIMER_EVENT'),
            (N'XE_FILE_TARGET_TVF')
    ) AS v (wait_type);

    /* Most specific pattern (lowest priority) wins */
    INSERT #wait_cat (pattern, priority, category, explanation)
    VALUES
        (N'THREADPOOL', 10, N'Worker threads', N'Tasks are waiting for a worker thread: the worker limit of the service objective is exhausted. Usually a long blocking chain or too much parallelism. Critical.'),
        (N'SOS_SCHEDULER_YIELD', 10, N'CPU', N'Runnable tasks giving up the scheduler after their quantum: CPU pressure or CPU-heavy queries.'),
        (N'RESOURCE_GOVERNOR_IDLE', 10, N'CPU governance', N'Tasks held back by the CPU cap of the service objective or elastic pool.'),
        (N'CXPACKET', 10, N'Parallelism', N'Parallel query thread synchronization (producers). Look for skewed parallel plans, MAXDOP and cost threshold.'),
        (N'CXCONSUMER', 10, N'Parallelism', N'Parallel consumer threads waiting for rows. Usually harmless on its own.'),
        (N'CXSYNC_PORT', 10, N'Parallelism', N'Parallel exchange port synchronization, often large parallel scans or skewed plans.'),
        (N'CXSYNC_CONSUMER', 10, N'Parallelism', N'Parallel exchange consumer synchronization.'),
        (N'CXROWSET_SYNC', 10, N'Parallelism', N'Parallel range scan synchronization.'),
        (N'EXCHANGE', 10, N'Parallelism', N'Parallel exchange operator synchronization.'),
        (N'HTBUILD', 10, N'Batch mode', N'Batch mode hash table build synchronization.'),
        (N'HTDELETE', 10, N'Batch mode', N'Batch mode hash table cleanup synchronization.'),
        (N'HTMEMO', 10, N'Batch mode', N'Batch mode hash table synchronization.'),
        (N'HTREINIT', 10, N'Batch mode', N'Batch mode hash table reinitialization.'),
        (N'HTREPARTITION', 10, N'Batch mode', N'Batch mode hash table repartitioning.'),
        (N'BPSORT', 10, N'Batch mode', N'Batch mode sort synchronization.'),
        (N'HTBUILD%', 40, N'Batch mode', N'Batch mode hash table build synchronization between parallel threads (hash join or hash aggregate).'),
        (N'HTDELETE%', 40, N'Batch mode', N'Batch mode hash table cleanup synchronization between parallel threads (hash join or hash aggregate).'),
        (N'HTMEMO%', 40, N'Batch mode', N'Batch mode hash table synchronization between parallel threads.'),
        (N'HTREINIT%', 40, N'Batch mode', N'Batch mode hash table reinitialization between parallel threads.'),
        (N'HTREPARTITION%', 40, N'Batch mode', N'Batch mode hash table repartitioning between parallel threads.'),
        (N'BMP%', 40, N'Batch mode', N'Batch mode bitmap filter synchronization between parallel threads.'),
        (N'SOS_PHYS_PAGE_CACHE', 10, N'Memory', N'Waiting for the lock on physical page allocation: memory is being allocated or released, for example when the buffer pool grows or shrinks.'),
        (N'PWAIT_QRY_BPMEMORY', 10, N'Batch mode', N'Batch mode memory synchronization.'),
        (N'RESOURCE_SEMAPHORE', 10, N'Memory grants', N'Queries waiting for a workspace memory grant: large sorts or hashes, bad estimates or too many concurrent grants.'),
        (N'RESOURCE_SEMAPHORE_QUERY_COMPILE', 10, N'Compilation', N'Queries waiting for compile memory: many concurrent large compilations.'),
        (N'WAIT_ON_SYNC_STATISTICS_REFRESH', 10, N'Compilation', N'Compilation waiting for a synchronous statistics update. Consider AUTO_UPDATE_STATISTICS_ASYNC.'),
        (N'CMEMTHREAD', 10, N'Memory', N'Contention on a thread-safe memory object, often heavy ad hoc compilation.'),
        (N'SLEEP_BPOOL_STEAL', 10, N'Memory', N'Buffer pool pages are being stolen for other memory consumers.'),
        (N'RESERVED_MEMORY_ALLOCATION_EXT', 10, N'Memory', N'Memory allocations for IO buffers such as read-ahead.'),
        (N'MEMORY_GRANT_UPDATE', 10, N'Memory grants', N'Memory grant feedback or grant size adjustment.'),
        (N'SOS_RESERVEDMEMBLOCKLIST', 10, N'Memory', N'Memory allocations for very large IN lists or parameter counts.'),
        (N'SOS_VIRTUALMEMORY_LOW', 10, N'Memory', N'Memory allocations waiting for virtual memory.'),
        (N'WRITELOG', 10, N'Tran log IO', N'Commits waiting for the log flush: many small transactions or the log write limit.'),
        (N'LOGBUFFER', 10, N'Tran log IO', N'Waiting for space in the log buffer: log writes cannot keep up.'),
        (N'LOGMGR_RESERVE_APPEND', 10, N'Tran log IO', N'Waiting for log space: the log is full or growing.'),
        (N'LOG_RATE_GOVERNOR', 10, N'Log rate governance', N'The log rate limit of the service objective is reached. Batch or spread out writes, or scale up.'),
        (N'POOL_LOG_RATE_GOVERNOR', 10, N'Log rate governance', N'The elastic pool log rate limit is reached.'),
        (N'INSTANCE_LOG_RATE_GOVERNOR', 10, N'Log rate governance', N'The instance-level log rate limit is reached.'),
        (N'HADR_THROTTLE_LOG_RATE_GOVERNOR', 10, N'Log rate governance', N'Log generation throttled by the replication log rate governor.'),
        (N'HADR_THROTTLE_LOG_RATE%', 40, N'Log rate governance', N'Log generation throttled because a secondary replica is falling behind.'),
        (N'RBIO_RG_STORAGE', 10, N'Hyperscale log throttling', N'Log generation throttled because page servers are behind applying log.'),
        (N'RBIO_RG_DESTAGE', 10, N'Hyperscale log throttling', N'Log generation throttled because long-term log storage is behind.'),
        (N'RBIO_RG_LOCALDESTAGE', 10, N'Hyperscale log throttling', N'Log generation throttled because the log service is behind.'),
        (N'RBIO_RG_REPLICA', 10, N'Hyperscale log throttling', N'Log generation throttled because a readable secondary replica is behind.'),
        (N'RBIO_RG_GEOREPLICA', 10, N'Hyperscale log throttling', N'Log generation throttled because the geo-secondary replica is behind.'),
        (N'RBIO_RG%', 40, N'Hyperscale log throttling', N'Hyperscale log rate governance.'),
        (N'RBIO%', 60, N'Hyperscale storage', N'Hyperscale remote IO to page servers or the log service.'),
        (N'IO_QUEUE_LIMIT', 10, N'IO governance', N'The data IO (IOPS) limit of the service objective is reached.'),
        (N'RESMGR_THROTTLED', 10, N'IO governance', N'Requests throttled by Azure resource governance.'),
        (N'IO_RETRY', 10, N'Other disk IO', N'IO operations that failed and were retried: transient storage errors.'),
        (N'IO_COMPLETION', 10, N'Other disk IO', N'Non-data-page IO, often sort or hash spills to tempdb.'),
        (N'ASYNC_IO_COMPLETION', 10, N'Other disk IO', N'Asynchronous IO such as file growth, backup or checkpoint.'),
        (N'BACKUPIO', 10, N'Backup', N'Automated backup IO.'),
        (N'BACKUPBUFFER', 10, N'Backup', N'Automated backup buffers.'),
        (N'ASYNC_NETWORK_IO', 10, N'Network IO', N'The client is not consuming results fast enough: row-by-row processing, large result sets or a slow network.'),
        (N'HADR_SYNC_COMMIT', 10, N'Replication', N'Commits waiting for a synchronous secondary replica (Premium / Business Critical).'),
        (N'HADR_GROUP_COMMIT', 10, N'Replication', N'Group commit to high-availability replicas.'),
        (N'SE_REPL%', 50, N'Replication', N'Azure replication to secondary replicas is slow or throttled.'),
        (N'HADR%', 90, N'Replication', N'High-availability or geo-replication wait.'),
        (N'BTREE_INSERT_FLOW_CONTROL', 10, N'Buffer latch', N'OPTIMIZE_FOR_SEQUENTIAL_KEY flow control on a hot last-page insert pattern.'),
        (N'LCK_M_SCH_M', 10, N'Lock', N'Waiting for a schema modification lock: DDL, index rebuild, partition switch or statistics change is queued behind (or blocking) queries.'),
        (N'LCK_M_SCH_S', 10, N'Lock', N'Waiting for a schema stability lock: a schema modification holds or is queued on the object.'),
        (N'LCK%', 50, N'Lock', N'Blocked by another session''s lock. See blocking_tree.'),
        (N'PAGELATCH%', 50, N'Buffer latch', N'In-memory page contention: hot pages (last-page inserts) or tempdb allocation pages (PFS / GAM / SGAM).'),
        (N'PAGEIOLATCH%', 50, N'Buffer IO', N'Reading data pages from storage into memory (Hyperscale: from page servers). Large scans, missing indexes or the data IO limit.'),
        (N'LATCH%', 60, N'Latch', N'Non-buffer latch contention, for example ACCESS_METHODS_DATASET_PARENT from parallel scans.'),
        (N'TRANSACTION_MUTEX', 10, N'Transaction', N'Contention on a transaction shared by several requests (MARS or bound sessions).'),
        (N'XACT%', 70, N'Transaction', N'Transaction management wait.'),
        (N'DTC%', 70, N'Transaction', N'Distributed transaction wait.'),
        (N'WAIT_XTP%', 70, N'In-memory OLTP', N'In-memory OLTP wait.'),
        (N'XTP%', 70, N'In-memory OLTP', N'In-memory OLTP wait.'),
        (N'QDS%', 70, N'Query Store', N'Query Store internal wait. Sustained waits can point at Query Store size or capture settings.'),
        (N'OLEDB', 10, N'Other', N'OLE DB calls, including DMV and remote data access.'),
        (N'PREEMPTIVE%', 80, N'Preemptive', N'Calls outside the SQL scheduler (OS, network, external endpoints).'),
        (N'%', 255, N'Other', N'See the wait type documentation.');

    /* ============================================================================================
       Database, service objective and governance facts
       ============================================================================================ */
    BEGIN TRY
        SELECT
            @edition = CONVERT(sysname, DATABASEPROPERTYEX(@db_name, 'Edition')),
            @service_objective = CONVERT(sysname, DATABASEPROPERTYEX(@db_name, 'ServiceObjective'));

        SELECT
            @rcsi = d.is_read_committed_snapshot_on,
            @physical_db_name = d.physical_database_name,
            @compat_level = d.compatibility_level
        FROM sys.databases AS d
        WHERE d.database_id = @db_id;
    END TRY
    BEGIN CATCH
        INSERT #messages (msg_type, section, message)
        VALUES ('ERROR', N'setup', LEFT(N'Database properties: ' + ERROR_MESSAGE(), 4000));
    END CATCH;

    SET @is_hyperscale = CASE WHEN @edition = N'Hyperscale' THEN 1 ELSE 0 END;

    BEGIN TRY
        SELECT TOP (1)
            @primary_group_id = g.primary_group_id,
            @rg_max_workers = g.primary_group_max_workers,
            @rg_max_sessions = g.max_sessions,
            @rg_cpu_limit = g.cpu_limit,
            @rg_max_log_rate_mbps = CONVERT(decimal(18, 2), g.primary_max_log_rate / 1048576.0),
            @rg_log_size_mb = g.log_size_in_mb
        FROM sys.dm_user_db_resource_governance AS g
        WHERE g.database_id = @db_id;
    END TRY
    BEGIN CATCH
        INSERT #messages (msg_type, section, message)
        VALUES ('ERROR', N'setup', LEFT(N'sys.dm_user_db_resource_governance: ' + ERROR_MESSAGE(), 4000));
    END CATCH;

    /* Maximum log size: the smaller of the governance limit and the log file growth limit that
       are known. A log file grows on demand, so "percent of the current file" says little. */
    BEGIN TRY
        SELECT
            @log_file_max_mb =
                CASE
                    WHEN MIN(df.max_size) = -1 THEN NULL
                    ELSE SUM(CONVERT(bigint, CASE WHEN df.max_size = 0 THEN df.size ELSE df.max_size END)) / 128.0
                END
        FROM sys.database_files AS df
        WHERE df.type = 1;
    END TRY
    BEGIN CATCH
        INSERT #messages (msg_type, section, message)
        VALUES ('INFO', N'setup', LEFT(N'sys.database_files (log): ' + ERROR_MESSAGE(), 4000));
    END CATCH;

    SET @log_max_mb =
        CASE
            WHEN @rg_log_size_mb > 0 AND (@log_file_max_mb IS NULL OR @rg_log_size_mb < @log_file_max_mb) THEN @rg_log_size_mb
            WHEN @log_file_max_mb > 0 THEN @log_file_max_mb
        END;

    BEGIN TRY
        SELECT
            @instance_start = i.sqlserver_start_time,
            @instance_max_workers = i.max_workers_count
        FROM sys.dm_os_sys_info AS i;
    END TRY
    BEGIN CATCH
        INSERT #messages (msg_type, section, message)
        VALUES ('INFO', N'setup', LEFT(N'sys.dm_os_sys_info: ' + ERROR_MESSAGE(), 4000));
    END CATCH;

    /* ============================================================================================
       Counter sampling. Without @sample_seconds only sample 2 is taken and values are cumulative.
       ============================================================================================ */
    DECLARE @sample_no tinyint = CASE WHEN @is_sampled = 1 THEN 1 ELSE 2 END;

    WHILE @sample_no <= 2
    BEGIN
        IF @sample_no = 2 AND @is_sampled = 1
        BEGIN
            SET @delay = CONVERT(char(8), DATEADD(SECOND, @sample_seconds, CONVERT(datetime, '19000101', 112)), 108);
            RAISERROR(N'Sampling for %d seconds...', 0, 1, @sample_seconds) WITH NOWAIT;
            WAITFOR DELAY @delay;
        END;

        IF @sample_no = 1
            SET @sample_start = SYSDATETIME();
        ELSE
            SET @sample_end = SYSDATETIME();

        BEGIN TRY
            INSERT #waits_snap (sample_no, wait_type, waiting_tasks_count, wait_time_ms, max_wait_time_ms, signal_wait_time_ms)
            SELECT
                @sample_no,
                ws.wait_type,
                ws.waiting_tasks_count,
                ws.wait_time_ms,
                ws.max_wait_time_ms,
                ws.signal_wait_time_ms
            FROM sys.dm_db_wait_stats AS ws
            WHERE ws.waiting_tasks_count > 0
            OR    ws.wait_time_ms > 0;
        END TRY
        BEGIN CATCH
            INSERT #messages (msg_type, section, message)
            VALUES ('ERROR', N'snapshot', LEFT(N'sys.dm_db_wait_stats: ' + ERROR_MESSAGE(), 4000));
        END CATCH;

        BEGIN TRY
            INSERT #file_snap (sample_no, database_id, file_id, num_of_reads, num_of_bytes_read, io_stall_read_ms, io_stall_queued_read_ms, num_of_writes, num_of_bytes_written, io_stall_write_ms, io_stall_queued_write_ms, size_on_disk_bytes)
            SELECT
                @sample_no,
                vfs.database_id,
                vfs.file_id,
                vfs.num_of_reads,
                vfs.num_of_bytes_read,
                vfs.io_stall_read_ms,
                vfs.io_stall_queued_read_ms,
                vfs.num_of_writes,
                vfs.num_of_bytes_written,
                vfs.io_stall_write_ms,
                vfs.io_stall_queued_write_ms,
                vfs.size_on_disk_bytes
            FROM sys.dm_io_virtual_file_stats(@db_id, NULL) AS vfs;
        END TRY
        BEGIN CATCH
            INSERT #messages (msg_type, section, message)
            VALUES ('ERROR', N'snapshot', LEFT(N'sys.dm_io_virtual_file_stats (database): ' + ERROR_MESSAGE(), 4000));
        END CATCH;

        BEGIN TRY
            INSERT #file_snap (sample_no, database_id, file_id, num_of_reads, num_of_bytes_read, io_stall_read_ms, io_stall_queued_read_ms, num_of_writes, num_of_bytes_written, io_stall_write_ms, io_stall_queued_write_ms, size_on_disk_bytes)
            SELECT
                @sample_no,
                vfs.database_id,
                vfs.file_id,
                vfs.num_of_reads,
                vfs.num_of_bytes_read,
                vfs.io_stall_read_ms,
                vfs.io_stall_queued_read_ms,
                vfs.num_of_writes,
                vfs.num_of_bytes_written,
                vfs.io_stall_write_ms,
                vfs.io_stall_queued_write_ms,
                vfs.size_on_disk_bytes
            FROM sys.dm_io_virtual_file_stats(2, NULL) AS vfs
            WHERE @db_id <> 2;
        END TRY
        BEGIN CATCH
            INSERT #messages (msg_type, section, message)
            VALUES ('INFO', N'snapshot', LEFT(N'sys.dm_io_virtual_file_stats (tempdb): ' + ERROR_MESSAGE(), 4000));
        END CATCH;

        /* Hyperscale reports the local SSD cache (RBPEX) as database_id 0; data file reads are then page server reads */
        IF @is_hyperscale = 1
        BEGIN
            BEGIN TRY
                INSERT #file_snap (sample_no, database_id, file_id, num_of_reads, num_of_bytes_read, io_stall_read_ms, io_stall_queued_read_ms, num_of_writes, num_of_bytes_written, io_stall_write_ms, io_stall_queued_write_ms, size_on_disk_bytes)
                SELECT
                    @sample_no,
                    vfs.database_id,
                    vfs.file_id,
                    vfs.num_of_reads,
                    vfs.num_of_bytes_read,
                    vfs.io_stall_read_ms,
                    vfs.io_stall_queued_read_ms,
                    vfs.num_of_writes,
                    vfs.num_of_bytes_written,
                    vfs.io_stall_write_ms,
                    vfs.io_stall_queued_write_ms,
                    vfs.size_on_disk_bytes
                FROM sys.dm_io_virtual_file_stats(0, NULL) AS vfs
                WHERE vfs.database_id = 0;
            END TRY
            BEGIN CATCH
                INSERT #messages (msg_type, section, message)
                VALUES ('INFO', N'snapshot', LEFT(N'sys.dm_io_virtual_file_stats (Hyperscale local cache): ' + ERROR_MESSAGE(), 4000));
            END CATCH;
        END;

        BEGIN TRY
            INSERT #perf_snap (sample_no, object_name, counter_name, instance_name, cntr_value, cntr_type)
            SELECT
                @sample_no,
                LTRIM(RTRIM(SUBSTRING(pc.object_name, CHARINDEX(N':', pc.object_name) + 1, 128))),
                LTRIM(RTRIM(pc.counter_name)),
                LTRIM(RTRIM(pc.instance_name)),
                pc.cntr_value,
                pc.cntr_type
            FROM sys.dm_os_performance_counters AS pc
            WHERE pc.cntr_type IN (65792, 272696576)
            AND   pc.object_name NOT LIKE N'%Buffer Node%'
            AND
            (
                pc.counter_name IN
                (
                    N'Batch Requests/sec', N'SQL Compilations/sec', N'SQL Re-Compilations/sec', N'User Connections',
                    N'Logins/sec', N'Processes blocked', N'Page life expectancy', N'Page reads/sec', N'Page writes/sec',
                    N'Lazy writes/sec', N'Readahead pages/sec', N'Memory Grants Pending', N'Memory Grants Outstanding',
                    N'Target Server Memory (KB)', N'Total Server Memory (KB)', N'Full Scans/sec', N'Index Searches/sec',
                    N'Page Splits/sec', N'Forwarded Records/sec', N'Workfiles Created/sec', N'Worktables Created/sec',
                    N'Free Space in tempdb (KB)', N'Version Store Size (KB)', N'Longest Transaction Running Time',
                    N'SQL Attention rate'
                )
                OR
                (
                    pc.counter_name IN (N'Lock Waits/sec', N'Number of Deadlocks/sec', N'Lock Timeouts (timeout > 0)/sec', N'Errors/sec')
                    AND pc.instance_name = N'_Total'
                )
                OR
                (
                    pc.counter_name IN (N'Transactions/sec', N'Write Transactions/sec', N'Log Bytes Flushed/sec', N'Log Flushes/sec', N'Log Flush Waits/sec', N'Active Transactions')
                    AND pc.instance_name IN (@physical_db_name, @db_name)
                )
            );
        END TRY
        BEGIN CATCH
            INSERT #messages (msg_type, section, message)
            VALUES ('INFO', N'snapshot', LEFT(N'sys.dm_os_performance_counters: ' + ERROR_MESSAGE(), 4000));
        END CATCH;

        /* Waits per session. The database wait statistics get the waits of a request only after
           the request ends, so over a short sample they miss the long requests that matter. The
           session counters do not have that delay. Dynamic SQL on purpose: a problem with this
           DMV becomes a message and the procedure continues. */
        IF @is_sampled = 1
        BEGIN
            BEGIN TRY
                EXEC sys.sp_executesql
                    N'
INSERT #sess_waits_snap (sample_no, session_id, wait_type, waiting_tasks_count, wait_time_ms, signal_wait_time_ms)
SELECT
    @sample_no,
    sw.session_id,
    sw.wait_type,
    sw.waiting_tasks_count,
    sw.wait_time_ms,
    sw.signal_wait_time_ms
FROM sys.dm_exec_session_wait_stats AS sw
JOIN sys.dm_exec_sessions AS s
  ON s.session_id = sw.session_id
WHERE s.database_id = @db_id
AND   s.is_user_process = 1
AND   sw.session_id <> @@SPID
AND   sw.wait_time_ms > 0;',
                    N'@sample_no tinyint, @db_id int',
                    @sample_no,
                    @db_id;
            END TRY
            BEGIN CATCH
                INSERT #messages (msg_type, section, message)
                VALUES ('INFO', N'snapshot', LEFT(N'sys.dm_exec_session_wait_stats: ' + ERROR_MESSAGE(), 4000));
            END CATCH;
        END;

        IF @sample_no = 1
        BEGIN
            BEGIN TRY
                INSERT #req_sample1 (session_id, request_id, start_time, cpu_time, logical_reads, reads, writes, page_server_reads)
                SELECT
                    r.session_id,
                    r.request_id,
                    r.start_time,
                    r.cpu_time,
                    r.logical_reads,
                    r.reads,
                    r.writes,
                    r.page_server_reads
                FROM sys.dm_exec_requests AS r
                WHERE r.database_id = @db_id;
            END TRY
            BEGIN CATCH
                INSERT #messages (msg_type, section, message)
                VALUES ('ERROR', N'snapshot', LEFT(N'sys.dm_exec_requests (sample 1): ' + ERROR_MESSAGE(), 4000));
            END CATCH;

            /* Plan cache counters at the start of the sample, for plan_cache_sampled */
            IF @is_sampled = 1 AND @do_queries = 1
            BEGIN
                BEGIN TRY
                    INSERT #qs_s1
                    (
                        plan_handle, statement_start_offset, statement_end_offset, creation_time,
                        execution_count, total_worker_time, total_elapsed_time, total_logical_reads
                    )
                    SELECT
                        qs.plan_handle,
                        qs.statement_start_offset,
                        qs.statement_end_offset,
                        qs.creation_time,
                        qs.execution_count,
                        qs.total_worker_time,
                        qs.total_elapsed_time,
                        qs.total_logical_reads
                    FROM sys.dm_exec_query_stats AS qs;
                END TRY
                BEGIN CATCH
                    INSERT #messages (msg_type, section, message)
                    VALUES ('INFO', N'snapshot', LEFT(N'sys.dm_exec_query_stats (sample 1): ' + ERROR_MESSAGE(), 4000));
                END CATCH;
            END;
        END;

        SET @sample_no += 1;
    END;

    SET @sample_s =
        CASE
            WHEN @is_sampled = 1
            THEN CONVERT(decimal(18, 3), DATEDIFF(MILLISECOND, @sample_start, @sample_end) / 1000.0)
        END;

    /* Live snapshots are taken after the sampling wait, so ages and the lookback window are
       measured from here */
    SELECT
        @now = GETDATE(),
        @now_utc = GETUTCDATE();

    SET @window_start = DATEADD(MINUTE, -@lookback_minutes, @now);
    SET @window_start_dto = TODATETIMEOFFSET(DATEADD(MINUTE, -@lookback_minutes, SYSUTCDATETIME()), 0);

    /* ============================================================================================
       Live snapshots. Requests and waiting tasks first, so they line up as closely as possible.
       ============================================================================================ */
    BEGIN TRY
        INSERT #req
        (
            session_id, request_id, start_time, status, command, database_id, blocking_session_id, wait_type,
            wait_time_ms, last_wait_type, wait_resource, open_transaction_count, transaction_id, percent_complete,
            estimated_completion_time, cpu_time, total_elapsed_time, scheduler_id, reads, writes, logical_reads,
            page_server_reads, row_count, granted_query_memory_pages, transaction_isolation_level, nest_level, dop,
            parallel_worker_count, group_id, sql_handle, statement_start_offset, statement_end_offset, plan_handle,
            query_hash, query_plan_hash
        )
        SELECT
            r.session_id,
            r.request_id,
            r.start_time,
            r.status,
            r.command,
            r.database_id,
            r.blocking_session_id,
            r.wait_type,
            r.wait_time,
            r.last_wait_type,
            r.wait_resource,
            r.open_transaction_count,
            r.transaction_id,
            r.percent_complete,
            r.estimated_completion_time,
            r.cpu_time,
            r.total_elapsed_time,
            r.scheduler_id,
            r.reads,
            r.writes,
            r.logical_reads,
            r.page_server_reads,
            r.row_count,
            r.granted_query_memory,
            r.transaction_isolation_level,
            r.nest_level,
            r.dop,
            r.parallel_worker_count,
            r.group_id,
            r.sql_handle,
            r.statement_start_offset,
            r.statement_end_offset,
            r.plan_handle,
            r.query_hash,
            r.query_plan_hash
        FROM sys.dm_exec_requests AS r
        WHERE r.session_id <> @@SPID;
    END TRY
    BEGIN CATCH
        INSERT #messages (msg_type, section, message)
        VALUES ('ERROR', N'snapshot', LEFT(N'sys.dm_exec_requests: ' + ERROR_MESSAGE(), 4000));
    END CATCH;

    BEGIN TRY
        INSERT #wt (waiting_task_address, session_id, exec_context_id, wait_duration_ms, wait_type, blocking_session_id, resource_description, task_rank)
        SELECT
            wt.waiting_task_address,
            wt.session_id,
            wt.exec_context_id,
            wt.wait_duration_ms,
            wt.wait_type,
            wt.blocking_session_id,
            wt.resource_description,
            ROW_NUMBER() OVER
            (
                PARTITION BY
                    wt.waiting_task_address
                ORDER BY
                    CASE WHEN wt.blocking_session_id IS NOT NULL THEN 0 ELSE 1 END,
                    wt.wait_duration_ms DESC
            )
        FROM sys.dm_os_waiting_tasks AS wt
        /* Tasks that wait for a worker thread (THREADPOOL) have no session yet: keep them */
        WHERE wt.session_id <> @@SPID
        OR    (wt.session_id IS NULL AND wt.wait_type = N'THREADPOOL');
    END TRY
    BEGIN CATCH
        INSERT #messages (msg_type, section, message)
        VALUES ('ERROR', N'snapshot', LEFT(N'sys.dm_os_waiting_tasks: ' + ERROR_MESSAGE(), 4000));
    END CATCH;

    /* One row per session, read once. A correlated lookup re-reads the DMV for every session,
       which is slow when thousands of sessions are connected. */
    BEGIN TRY
        INSERT #conn (session_id, client_net_address, connect_time, most_recent_sql_handle)
        SELECT
            x.session_id,
            x.client_net_address,
            x.connect_time,
            x.most_recent_sql_handle
        FROM
        (
            SELECT
                ec.session_id,
                ec.client_net_address,
                ec.connect_time,
                ec.most_recent_sql_handle,
                conn_rank =
                    ROW_NUMBER() OVER
                    (
                        PARTITION BY
                            ec.session_id
                        ORDER BY
                            CASE WHEN ec.parent_connection_id IS NULL THEN 0 ELSE 1 END,
                            ec.connect_time
                    )
            FROM sys.dm_exec_connections AS ec
            WHERE ec.session_id IS NOT NULL
        ) AS x
        WHERE x.conn_rank = 1;
    END TRY
    BEGIN CATCH
        INSERT #messages (msg_type, section, message)
        VALUES ('INFO', N'snapshot', LEFT(N'sys.dm_exec_connections unavailable, client addresses omitted: ' + ERROR_MESSAGE(), 4000));
    END CATCH;

    BEGIN TRY
        INSERT #sess
        (
            session_id, database_id, is_user_process, status, login_name, host_name, program_name,
            client_interface_name, client_net_address, login_time, connect_time, last_request_start_time,
            last_request_end_time, cpu_time, memory_usage_pages, reads, writes, logical_reads, page_server_reads,
            open_transaction_count, transaction_isolation_level, lock_timeout, deadlock_priority, group_id,
            most_recent_sql_handle
        )
        SELECT
            s.session_id,
            s.database_id,
            s.is_user_process,
            s.status,
            s.login_name,
            s.host_name,
            s.program_name,
            s.client_interface_name,
            c.client_net_address,
            s.login_time,
            c.connect_time,
            s.last_request_start_time,
            s.last_request_end_time,
            s.cpu_time,
            s.memory_usage,
            s.reads,
            s.writes,
            s.logical_reads,
            s.page_server_reads,
            s.open_transaction_count,
            s.transaction_isolation_level,
            s.lock_timeout,
            s.deadlock_priority,
            s.group_id,
            c.most_recent_sql_handle
        FROM sys.dm_exec_sessions AS s
        LEFT JOIN #conn AS c
          ON c.session_id = s.session_id
        WHERE s.session_id <> @@SPID;
    END TRY
    BEGIN CATCH
        INSERT #messages (msg_type, section, message)
        VALUES ('ERROR', N'snapshot', LEFT(N'sys.dm_exec_sessions: ' + ERROR_MESSAGE(), 4000));
    END CATCH;

    BEGIN TRY
        INSERT #trn
        (
            session_id, transaction_id, transaction_name, transaction_begin_time, transaction_type, transaction_state,
            dtc_state, is_user_transaction, is_local, db_tran_begin_time, db_tran_state, log_record_count,
            log_bytes_used, log_bytes_reserved, is_snapshot, snapshot_elapsed_s, max_version_chain
        )
        SELECT
            st.session_id,
            at.transaction_id,
            at.name,
            at.transaction_begin_time,
            at.transaction_type,
            at.transaction_state,
            at.dtc_state,
            st.is_user_transaction,
            st.is_local,
            dt.database_transaction_begin_time,
            dt.database_transaction_state,
            dt.database_transaction_log_record_count,
            dt.database_transaction_log_bytes_used,
            dt.database_transaction_log_bytes_reserved,
            ss.is_snapshot,
            ss.elapsed_time_seconds,
            ss.max_version_chain_traversed
        FROM sys.dm_tran_active_transactions AS at
        LEFT JOIN sys.dm_tran_session_transactions AS st
          ON st.transaction_id = at.transaction_id
        LEFT JOIN sys.dm_tran_database_transactions AS dt
          ON  dt.transaction_id = at.transaction_id
          AND dt.database_id = @db_id
        LEFT JOIN sys.dm_tran_active_snapshot_database_transactions AS ss
          ON ss.transaction_id = at.transaction_id
        WHERE (st.session_id IS NOT NULL OR dt.transaction_id IS NOT NULL)
        AND   ISNULL(st.session_id, 0) <> @@SPID;
    END TRY
    BEGIN CATCH
        INSERT #messages (msg_type, section, message)
        VALUES ('ERROR', N'snapshot', LEFT(N'Transaction DMVs: ' + ERROR_MESSAGE(), 4000));
    END CATCH;

    /* A transaction holds resources when it wrote log, reads under SNAPSHOT, or runs at an
       isolation level that keeps its shared locks until it ends. A driver with autocommit off
       (pyodbc, JDBC) leaves transactions open that have done none of these: they hold no locks,
       no log and no row versions, so they are not a problem while they stay like that. */
    UPDATE t
    SET t.holds_resources =
        CASE
            WHEN t.log_record_count > 0 OR t.log_bytes_used > 0 THEN 1
            WHEN t.is_snapshot = 1 THEN 1
            WHEN t.db_tran_state IS NOT NULL AND s.transaction_isolation_level IN (3, 4) THEN 1
            ELSE 0
        END
    FROM #trn AS t
    LEFT JOIN #sess AS s
      ON s.session_id = t.session_id;

    BEGIN TRY
        INSERT #grants
        (
            session_id, request_id, dop, request_time, grant_time, requested_memory_kb, granted_memory_kb,
            required_memory_kb, used_memory_kb, max_used_memory_kb, ideal_memory_kb, query_cost, timeout_sec,
            resource_semaphore_id, queue_id, wait_order, is_next_candidate, wait_time_ms, pool_id, is_small,
            reserved_worker_count, used_worker_count, sql_handle, plan_handle
        )
        SELECT
            g.session_id,
            g.request_id,
            g.dop,
            g.request_time,
            g.grant_time,
            g.requested_memory_kb,
            g.granted_memory_kb,
            g.required_memory_kb,
            g.used_memory_kb,
            g.max_used_memory_kb,
            g.ideal_memory_kb,
            g.query_cost,
            g.timeout_sec,
            g.resource_semaphore_id,
            g.queue_id,
            g.wait_order,
            g.is_next_candidate,
            g.wait_time_ms,
            g.pool_id,
            g.is_small,
            g.reserved_worker_count,
            g.used_worker_count,
            g.sql_handle,
            g.plan_handle
        FROM sys.dm_exec_query_memory_grants AS g
        WHERE g.session_id <> @@SPID;
    END TRY
    BEGIN CATCH
        INSERT #messages (msg_type, section, message)
        VALUES ('ERROR', N'snapshot', LEFT(N'sys.dm_exec_query_memory_grants: ' + ERROR_MESSAGE(), 4000));
    END CATCH;

    IF @do_tempdb = 1 OR @do_requests = 1 OR @do_summary = 1 OR @do_blocking = 1
    BEGIN
        BEGIN TRY
            INSERT #tsu (session_id, session_user_pages, session_internal_pages, task_user_pages, task_internal_pages)
            SELECT
                x.session_id,
                SUM(x.su),
                SUM(x.si),
                SUM(x.tu),
                SUM(x.ti)
            FROM
            (
                SELECT
                    ssu.session_id,
                    su = CASE WHEN ssu.user_objects_alloc_page_count > ssu.user_objects_dealloc_page_count THEN ssu.user_objects_alloc_page_count - ssu.user_objects_dealloc_page_count ELSE 0 END,
                    si = CASE WHEN ssu.internal_objects_alloc_page_count > ssu.internal_objects_dealloc_page_count THEN ssu.internal_objects_alloc_page_count - ssu.internal_objects_dealloc_page_count ELSE 0 END,
                    tu = CONVERT(bigint, 0),
                    ti = CONVERT(bigint, 0)
                FROM sys.dm_db_session_space_usage AS ssu

                UNION ALL

                SELECT
                    tsu.session_id,
                    CONVERT(bigint, 0),
                    CONVERT(bigint, 0),
                    CASE WHEN tsu.user_objects_alloc_page_count > tsu.user_objects_dealloc_page_count THEN tsu.user_objects_alloc_page_count - tsu.user_objects_dealloc_page_count ELSE 0 END,
                    CASE WHEN tsu.internal_objects_alloc_page_count > tsu.internal_objects_dealloc_page_count THEN tsu.internal_objects_alloc_page_count - tsu.internal_objects_dealloc_page_count ELSE 0 END
                FROM sys.dm_db_task_space_usage AS tsu
            ) AS x
            WHERE x.session_id IS NOT NULL
            GROUP BY
                x.session_id;
        END TRY
        BEGIN CATCH
            INSERT #messages (msg_type, section, message)
            VALUES ('INFO', N'snapshot', LEFT(N'tempdb space usage DMVs: ' + ERROR_MESSAGE(), 4000));
        END CATCH;

        /* A dropped temp table whose deallocation is deferred no longer uses space, but the session
           counters above still count its pages (seen: one sleeping session shown with 1.4 GB while
           all of tempdb held 33 MB of user objects). Dynamic SQL on purpose: if the column is not
           there, this correction becomes a message and the procedure continues. */
        SET @sql = N'
UPDATE t
SET t.session_user_pages = CASE WHEN t.session_user_pages > d.deferred_pages THEN t.session_user_pages - d.deferred_pages ELSE 0 END
FROM #tsu AS t
JOIN
(
    SELECT
        ssu.session_id,
        deferred_pages = SUM(CONVERT(bigint, ssu.user_objects_deferred_dealloc_page_count))
    FROM sys.dm_db_session_space_usage AS ssu
    GROUP BY
        ssu.session_id
) AS d
  ON d.session_id = t.session_id
WHERE d.deferred_pages > 0;';

        BEGIN TRY
            IF @debug = 1 PRINT @sql;
            EXEC sys.sp_executesql @sql;
        END TRY
        BEGIN CATCH
            INSERT #messages (msg_type, section, message)
            VALUES ('INFO', N'snapshot', LEFT(N'tempdb deferred deallocation: ' + ERROR_MESSAGE(), 4000));
        END CATCH;
    END;

    /* ============================================================================================
       Blocking analysis: edges -> tree (heads first) -> counts -> locks held by head blockers
       ============================================================================================ */
    IF @do_blocking = 1 OR @do_summary = 1 OR @do_requests = 1
    BEGIN
        BEGIN TRY
            INSERT #blk_edges (waiter, blocker, wait_ms)
            SELECT
                x.waiter,
                x.blocker,
                MAX(x.wait_ms)
            FROM
            (
                SELECT
                    waiter = r.session_id,
                    blocker = r.blocking_session_id,
                    wait_ms = r.wait_time_ms
                FROM #req AS r
                WHERE r.blocking_session_id IS NOT NULL
                AND   r.blocking_session_id <> 0
                AND   r.blocking_session_id <> r.session_id

                UNION ALL

                SELECT
                    w.session_id,
                    w.blocking_session_id,
                    w.wait_duration_ms
                FROM #wt AS w
                WHERE w.session_id IS NOT NULL
                AND   w.blocking_session_id IS NOT NULL
                AND   w.blocking_session_id <> 0
                AND   w.blocking_session_id <> w.session_id
            ) AS x
            WHERE EXISTS
            (
                SELECT
                    1/0
                FROM #sess AS s
                WHERE s.session_id IN (x.waiter, x.blocker)
                AND   s.database_id = @db_id
            )
            OR EXISTS
            (
                SELECT
                    1/0
                FROM #req AS r2
                WHERE r2.session_id IN (x.waiter, x.blocker)
                AND   r2.database_id = @db_id
            )
            GROUP BY
                x.waiter,
                x.blocker;

            IF EXISTS (SELECT 1/0 FROM #blk_edges)
            BEGIN
                /* Breadth-first from the head blockers. Each session appears once, under the blocker
                   it has waited on longest among those placed one level up. Following every edge
                   would list every path, and the number of paths grows exponentially when sessions
                   have several blockers (latch convoys, parallel queries). */
                INSERT #blk_nodes (node_order, session_id, blocked_by, head_session_id, lvl, is_head, in_cycle, sort_path)
                SELECT
                    0,
                    h.session_id,
                    NULL,
                    h.session_id,
                    0,
                    1,
                    0,
                    RIGHT('0000000' + CONVERT(varchar(12), h.session_id + 100000), 7)
                FROM
                (
                    SELECT DISTINCT
                        session_id = e.blocker
                    FROM #blk_edges AS e
                    WHERE NOT EXISTS
                    (
                        SELECT
                            1/0
                        FROM #blk_edges AS e2
                        WHERE e2.waiter = e.blocker
                    )
                ) AS h;

                SET @blk_rows = @@ROWCOUNT;

                WHILE @blk_rows > 0 AND @blk_lvl < @blk_max_lvl
                BEGIN
                    INSERT #blk_nodes (node_order, session_id, blocked_by, head_session_id, lvl, is_head, in_cycle, sort_path)
                    SELECT
                        0,
                        x.waiter,
                        x.blocker,
                        x.head_session_id,
                        @blk_lvl + 1,
                        0,
                        0,
                        x.sort_path + '/' + RIGHT('0000000' + CONVERT(varchar(12), x.waiter + 100000), 7)
                    FROM
                    (
                        SELECT
                            e.waiter,
                            e.blocker,
                            p.head_session_id,
                            p.sort_path,
                            pick = ROW_NUMBER() OVER (PARTITION BY e.waiter ORDER BY e.wait_ms DESC, e.blocker)
                        FROM #blk_edges AS e
                        JOIN #blk_nodes AS p
                          ON  p.session_id = e.blocker
                          AND p.lvl = @blk_lvl
                        WHERE NOT EXISTS
                        (
                            SELECT
                                1/0
                            FROM #blk_nodes AS n
                            WHERE n.session_id = e.waiter
                        )
                    ) AS x
                    WHERE x.pick = 1;

                    SELECT
                        @blk_rows = @@ROWCOUNT,
                        @blk_lvl += 1;
                END;

                IF @blk_rows > 0
                    INSERT #messages (msg_type, section, message)
                    VALUES
                    (
                        'INFO', N'blocking',
                        CONCAT(N'The blocking chain is deeper than ', @blk_max_lvl, N' levels. Sessions below that level are listed as CYCLE? at the end of blocking_tree.')
                    );

                /* Sessions that are blocked but not reachable from a head blocker: in a blocking cycle or behind one */
                INSERT #blk_nodes (node_order, session_id, blocked_by, head_session_id, lvl, is_head, in_cycle, sort_path)
                SELECT
                    0,
                    e.waiter,
                    MIN(e.blocker),
                    NULL,
                    0,
                    0,
                    1,
                    '9999999/' + RIGHT('0000000' + CONVERT(varchar(12), e.waiter + 100000), 7)
                FROM #blk_edges AS e
                WHERE NOT EXISTS
                (
                    SELECT
                        1/0
                    FROM #blk_nodes AS n
                    WHERE n.session_id = e.waiter
                )
                GROUP BY
                    e.waiter;

                INSERT #blk_counts (session_id, direct_blocked, total_blocked, max_wait_ms)
                SELECT
                    n.session_id,
                    (
                        SELECT
                            COUNT(*)
                        FROM #blk_nodes AS c
                        WHERE c.blocked_by = n.session_id
                    ),
                    ISNULL(d.total_blocked, 0),
                    d.max_wait_ms
                FROM
                (
                    SELECT DISTINCT
                        bn.session_id
                    FROM #blk_nodes AS bn
                ) AS n
                OUTER APPLY
                (
                    SELECT
                        total_blocked = COUNT(DISTINCT dn.session_id),
                        max_wait_ms = MAX(e.wait_ms)
                    FROM #blk_nodes AS an
                    JOIN #blk_nodes AS dn
                      ON dn.sort_path LIKE an.sort_path + '/%'
                    LEFT JOIN #blk_edges AS e
                      ON  e.waiter = dn.session_id
                      AND e.blocker = dn.blocked_by
                    WHERE an.session_id = n.session_id
                    AND   dn.session_id <> n.session_id
                ) AS d;

                WITH
                    hr AS
                    (
                        SELECT
                            c.session_id,
                            head_rank = ROW_NUMBER() OVER (ORDER BY c.total_blocked DESC, c.max_wait_ms DESC, c.session_id)
                        FROM #blk_counts AS c
                        WHERE EXISTS
                        (
                            SELECT
                                1/0
                            FROM #blk_nodes AS n
                            WHERE n.session_id = c.session_id
                            AND   n.is_head = 1
                        )
                    ),
                    o AS
                    (
                        SELECT
                            n.sort_path,
                            new_order = ROW_NUMBER() OVER (ORDER BY ISNULL(hr.head_rank, 2147483647), n.in_cycle, n.sort_path)
                        FROM #blk_nodes AS n
                        LEFT JOIN hr
                          ON hr.session_id = n.head_session_id
                    )
                UPDATE n
                SET n.node_order = o.new_order
                FROM #blk_nodes AS n
                JOIN o
                  ON o.sort_path = n.sort_path;
            END;
        END TRY
        BEGIN CATCH
            INSERT #messages (msg_type, section, message)
            VALUES ('ERROR', N'blocking', LEFT(N'Blocking analysis: ' + ERROR_MESSAGE(), 4000));
        END CATCH;

        IF EXISTS (SELECT 1/0 FROM #blk_nodes AS n WHERE n.is_head = 1 OR n.in_cycle = 1)
        BEGIN
            BEGIN TRY
                INSERT #head_locks (session_id, locks_held)
                SELECT
                    x.session_id,
                    LEFT(STRING_AGG(CONVERT(nvarchar(max), x.lock_desc), N'; ') WITHIN GROUP (ORDER BY x.lock_count DESC), 4000)
                FROM
                (
                    SELECT
                        session_id = l.request_session_id,
                        lock_desc =
                            CONCAT
                            (
                                l.resource_type COLLATE DATABASE_DEFAULT,
                                CASE
                                    WHEN o.name IS NOT NULL
                                    THEN N' ' + QUOTENAME(s.name COLLATE DATABASE_DEFAULT) + N'.' + QUOTENAME(o.name COLLATE DATABASE_DEFAULT)
                                    ELSE N''
                                END,
                                N' ',
                                l.request_mode COLLATE DATABASE_DEFAULT,
                                CASE
                                    WHEN l.request_status = N'GRANT'
                                    THEN N''
                                    ELSE N' (' + l.request_status COLLATE DATABASE_DEFAULT + N')'
                                END,
                                N' x',
                                COUNT_BIG(*)
                            ),
                        lock_count = COUNT_BIG(*)
                    FROM sys.dm_tran_locks AS l
                    LEFT JOIN sys.partitions AS p
                      ON  p.hobt_id = l.resource_associated_entity_id
                      AND l.resource_type IN (N'KEY', N'PAGE', N'RID', N'HOBT')
                    LEFT JOIN sys.objects AS o
                      ON o.object_id =
                         CASE
                             WHEN l.resource_type = N'OBJECT'
                             THEN l.resource_associated_entity_id
                             ELSE p.object_id
                         END
                    LEFT JOIN sys.schemas AS s
                      ON s.schema_id = o.schema_id
                    WHERE l.resource_database_id = @db_id
                    AND   l.resource_type <> N'DATABASE'
                    AND   l.request_session_id IN
                          (
                              SELECT
                                  bn.session_id
                              FROM #blk_nodes AS bn
                              WHERE bn.is_head = 1
                              OR    bn.in_cycle = 1
                          )
                    GROUP BY
                        l.request_session_id,
                        l.resource_type,
                        s.name,
                        o.name,
                        l.request_mode,
                        l.request_status
                ) AS x
                GROUP BY
                    x.session_id;
            END TRY
            BEGIN CATCH
                INSERT #messages (msg_type, section, message)
                VALUES ('INFO', N'blocking', LEFT(N'Locks held by head blockers: ' + ERROR_MESSAGE(), 4000));
            END CATCH;
        END;
    END;

    /* ============================================================================================
       Wait resource decoder: KEY / PAGE / RID / OBJECT / HOBT / ALLOCATION_UNIT, d:f:p latches and
       dm_os_waiting_tasks token format (hobtid= dbid= objid= fileid= pageid= associatedObjectId=)
       ============================================================================================ */
    IF @do_blocking = 1 OR @do_requests = 1 OR @do_waits = 1
    BEGIN
        BEGIN TRY
            INSERT #wr (resource_text)
            SELECT TOP (200)
                x.resource_text
            FROM
            (
                SELECT
                    resource_text = r.wait_resource
                FROM #req AS r
                WHERE r.wait_resource IS NOT NULL
                AND   LTRIM(RTRIM(r.wait_resource)) <> N''
                AND
                (
                    r.database_id = @db_id
                    OR EXISTS (SELECT 1/0 FROM #blk_nodes AS bn WHERE bn.session_id = r.session_id)
                )

                UNION

                SELECT
                    w.resource_description
                FROM #wt AS w
                JOIN #sess AS s
                  ON s.session_id = w.session_id
                WHERE w.task_rank = 1
                AND   w.resource_description IS NOT NULL
                AND   (w.wait_type LIKE N'LCK%' OR w.wait_type LIKE N'PAGE%LATCH%')
                AND   s.database_id = @db_id
            ) AS x;

            UPDATE w
            SET w.resource_kind =
                CASE
                    WHEN w.resource_text LIKE N'KEY: %' THEN N'KEY'
                    WHEN w.resource_text LIKE N'PAGE: %' THEN N'PAGE'
                    WHEN w.resource_text LIKE N'RID: %' THEN N'RID'
                    WHEN w.resource_text LIKE N'OBJECT: %' THEN N'OBJECT'
                    WHEN w.resource_text LIKE N'TAB: %' THEN N'OBJECT'
                    WHEN w.resource_text LIKE N'HOBT: %' THEN N'HOBT'
                    WHEN w.resource_text LIKE N'ALLOCATION[_]UNIT: %' THEN N'ALLOCATION_UNIT'
                    WHEN w.resource_text LIKE N'METADATA: %' THEN N'METADATA'
                    WHEN w.resource_text LIKE N'APPLICATION: %' THEN N'APPLICATION'
                    WHEN w.resource_text LIKE N'FILE: %' THEN N'FILE'
                    WHEN w.resource_text LIKE N'DATABASE: %' THEN N'DATABASE'
                    WHEN w.resource_text LIKE N'keylock %' THEN N'KEY'
                    WHEN w.resource_text LIKE N'pagelock %' THEN N'PAGE'
                    WHEN w.resource_text LIKE N'ridlock %' THEN N'RID'
                    WHEN w.resource_text LIKE N'objectlock %' THEN N'OBJECT'
                    WHEN w.resource_text LIKE N'hobtlock %' THEN N'HOBT'
                    WHEN w.resource_text LIKE N'allocunitlock %' THEN N'ALLOCATION_UNIT'
                    WHEN w.resource_text LIKE N'metadatalock %' THEN N'METADATA'
                    WHEN w.resource_text LIKE N'applicationlock %' THEN N'APPLICATION'
                    WHEN w.resource_text LIKE N'databaselock %' THEN N'DATABASE'
                    WHEN w.resource_text LIKE N'exchangeEvent %' THEN N'PARALLELISM'
                    WHEN tok.token NOT LIKE N'%[^0-9:]%' AND tok.token LIKE N'%_:%_:%_' THEN N'PAGE_LATCH'
                    ELSE N'OTHER'
                END
            FROM #wr AS w
            CROSS APPLY
            (
                SELECT
                    token = LEFT(w.resource_text, CHARINDEX(N' ', w.resource_text + N' ') - 1)
            ) AS tok;

            /* "TYPE: db:x[:y]" and "d:f:p" formats */
            UPDATE w
            SET
                w.res_db_id = TRY_CONVERT(int, a1.p1),
                w.res_hobt_id = CASE WHEN w.resource_kind IN (N'KEY', N'HOBT') THEN TRY_CONVERT(bigint, a2.p2) END,
                w.res_alloc_unit_id = CASE WHEN w.resource_kind = N'ALLOCATION_UNIT' THEN TRY_CONVERT(bigint, a2.p2) END,
                w.res_object_id = CASE WHEN w.resource_kind = N'OBJECT' THEN TRY_CONVERT(bigint, a2.p2) END,
                w.res_file_id = CASE WHEN w.resource_kind IN (N'PAGE', N'RID', N'PAGE_LATCH') THEN TRY_CONVERT(int, a2.p2) END,
                w.res_page_id = CASE WHEN w.resource_kind IN (N'PAGE', N'RID', N'PAGE_LATCH') THEN TRY_CONVERT(bigint, a3.p3) END
            FROM #wr AS w
            CROSS APPLY
            (
                SELECT
                    body0 =
                        CASE
                            WHEN w.resource_kind = N'PAGE_LATCH'
                            THEN w.resource_text
                            ELSE SUBSTRING(w.resource_text, CHARINDEX(N': ', w.resource_text) + 2, 3072)
                        END
            ) AS b0
            CROSS APPLY
            (
                SELECT
                    body = LEFT(b0.body0, CHARINDEX(N' ', b0.body0 + N' ') - 1)
            ) AS b
            CROSS APPLY
            (
                SELECT
                    p1 = LEFT(b.body, CHARINDEX(N':', b.body + N':') - 1),
                    r1 = SUBSTRING(b.body, CHARINDEX(N':', b.body + N':') + 1, 3072)
            ) AS a1
            CROSS APPLY
            (
                SELECT
                    p2 = LEFT(a1.r1, CHARINDEX(N':', a1.r1 + N':') - 1),
                    r2 = SUBSTRING(a1.r1, CHARINDEX(N':', a1.r1 + N':') + 1, 3072)
            ) AS a2
            CROSS APPLY
            (
                SELECT
                    p3 = LEFT(a2.r2, CHARINDEX(N':', a2.r2 + N':') - 1)
            ) AS a3
            WHERE w.resource_kind IN (N'KEY', N'PAGE', N'RID', N'OBJECT', N'HOBT', N'ALLOCATION_UNIT', N'PAGE_LATCH')
            AND   CHARINDEX(N'=', w.resource_text) = 0;

            /* name=value token format */
            UPDATE w
            SET
                w.res_db_id = ISNULL(w.res_db_id, TRY_CONVERT(int, v.dbid)),
                w.res_hobt_id = ISNULL(w.res_hobt_id, TRY_CONVERT(bigint, v.hobtid)),
                w.res_object_id = ISNULL(w.res_object_id, TRY_CONVERT(bigint, v.objid)),
                w.res_file_id = ISNULL(w.res_file_id, TRY_CONVERT(int, v.fileid)),
                w.res_page_id = ISNULL(w.res_page_id, TRY_CONVERT(bigint, v.pageid)),
                w.res_assoc_id = TRY_CONVERT(bigint, v.assoc)
            FROM #wr AS w
            CROSS APPLY
            (
                SELECT
                    t = N' ' + w.resource_text + N' '
            ) AS s
            CROSS APPLY
            (
                SELECT
                    p_dbid = CHARINDEX(N' dbid=', s.t),
                    p_hobtid = CHARINDEX(N' hobtid=', s.t),
                    p_objid = CHARINDEX(N' objid=', s.t),
                    p_fileid = CHARINDEX(N' fileid=', s.t),
                    p_pageid = CHARINDEX(N' pageid=', s.t),
                    p_assoc = CHARINDEX(N' associatedObjectId=', s.t)
            ) AS p
            CROSS APPLY
            (
                SELECT
                    dbid = CASE WHEN p.p_dbid > 0 THEN SUBSTRING(s.t, p.p_dbid + 6, CHARINDEX(N' ', s.t, p.p_dbid + 1) - p.p_dbid - 6) END,
                    hobtid = CASE WHEN p.p_hobtid > 0 THEN SUBSTRING(s.t, p.p_hobtid + 8, CHARINDEX(N' ', s.t, p.p_hobtid + 1) - p.p_hobtid - 8) END,
                    objid = CASE WHEN p.p_objid > 0 THEN SUBSTRING(s.t, p.p_objid + 7, CHARINDEX(N' ', s.t, p.p_objid + 1) - p.p_objid - 7) END,
                    fileid = CASE WHEN p.p_fileid > 0 THEN SUBSTRING(s.t, p.p_fileid + 8, CHARINDEX(N' ', s.t, p.p_fileid + 1) - p.p_fileid - 8) END,
                    pageid = CASE WHEN p.p_pageid > 0 THEN SUBSTRING(s.t, p.p_pageid + 8, CHARINDEX(N' ', s.t, p.p_pageid + 1) - p.p_pageid - 8) END,
                    assoc = CASE WHEN p.p_assoc > 0 THEN SUBSTRING(s.t, p.p_assoc + 20, CHARINDEX(N' ', s.t, p.p_assoc + 1) - p.p_assoc - 20) END
            ) AS v
            WHERE CHARINDEX(N'=', w.resource_text) > 0;

            /* Resolve objects in this database */
            UPDATE w
            SET
                w.object_id = p.object_id,
                w.index_id = p.index_id
            FROM #wr AS w
            JOIN sys.partitions AS p
              ON p.hobt_id = ISNULL(w.res_hobt_id, w.res_assoc_id)
            WHERE w.res_db_id = @db_id
            AND   w.resource_kind IN (N'KEY', N'HOBT', N'PAGE', N'RID');

            UPDATE w
            SET
                w.object_id = p.object_id,
                w.index_id = p.index_id
            FROM #wr AS w
            JOIN sys.allocation_units AS au
              ON au.allocation_unit_id = w.res_alloc_unit_id
            JOIN sys.partitions AS p
              ON (au.type IN (1, 3) AND p.hobt_id = au.container_id)
              OR (au.type = 2 AND p.partition_id = au.container_id)
            WHERE w.res_db_id = @db_id
            AND   w.resource_kind = N'ALLOCATION_UNIT';

            UPDATE w
            SET w.object_id = TRY_CONVERT(int, w.res_object_id)
            FROM #wr AS w
            WHERE w.res_db_id = @db_id
            AND   w.resource_kind = N'OBJECT'
            AND   w.res_object_id BETWEEN 1 AND 2147483647;
        END TRY
        BEGIN CATCH
            INSERT #messages (msg_type, section, message)
            VALUES ('INFO', N'waits', LEFT(N'Wait resource decoder: ' + ERROR_MESSAGE(), 4000));
        END CATCH;

        /* Page headers for latch / page waits in this database (bounded to 20 pages) */
        BEGIN TRY
            UPDATE TOP (20) w
            SET
                w.object_id = ISNULL(w.object_id, pi.object_id),
                w.index_id = ISNULL(w.index_id, pi.index_id),
                w.page_type = pi.page_type_desc
            FROM #wr AS w
            CROSS APPLY sys.dm_db_page_info(@db_id, w.res_file_id, w.res_page_id, 'LIMITED') AS pi
            WHERE w.res_db_id = @db_id
            AND   w.resource_kind IN (N'PAGE', N'RID', N'PAGE_LATCH')
            AND   w.res_file_id IS NOT NULL
            AND   w.res_page_id IS NOT NULL;
        END TRY
        BEGIN CATCH
            INSERT #messages (msg_type, section, message)
            VALUES ('INFO', N'waits', LEFT(N'sys.dm_db_page_info: ' + ERROR_MESSAGE(), 4000));
        END CATCH;

        BEGIN TRY
            UPDATE w
            SET w.decoded =
                LEFT
                (
                    CONCAT
                    (
                        w.resource_kind,
                        CASE
                            WHEN w.res_db_id = @db_id THEN N''
                            WHEN w.res_db_id = 2 THEN N' in tempdb'
                            WHEN w.res_db_id IS NOT NULL THEN N' in database_id ' + CONVERT(nvarchar(12), w.res_db_id)
                            ELSE N''
                        END,
                        CASE
                            WHEN o.name IS NOT NULL
                            THEN N' on ' + QUOTENAME(s.name COLLATE DATABASE_DEFAULT) + N'.' + QUOTENAME(o.name COLLATE DATABASE_DEFAULT)
                            WHEN w.object_id IS NOT NULL
                            THEN N' on object_id ' + CONVERT(nvarchar(12), w.object_id)
                            ELSE N''
                        END,
                        CASE
                            WHEN i.name IS NOT NULL THEN N' index ' + QUOTENAME(i.name COLLATE DATABASE_DEFAULT)
                            WHEN w.index_id = 0 THEN N' (heap)'
                            ELSE N''
                        END,
                        CASE
                            WHEN w.res_page_id IS NOT NULL
                            THEN N' page ' + CONVERT(nvarchar(12), w.res_file_id) + N':' + CONVERT(nvarchar(20), w.res_page_id)
                            ELSE N''
                        END,
                        CASE
                            WHEN w.page_type IS NOT NULL THEN N' (' + w.page_type + N')'
                            ELSE N''
                        END,
                        CASE
                            WHEN w.res_db_id = 2 AND w.res_page_id > 0 AND (w.res_page_id = 1 OR w.res_page_id % 8088 = 0)
                            THEN N' - PFS page: tempdb allocation contention'
                            WHEN w.res_db_id = 2 AND w.res_page_id > 0 AND (w.res_page_id = 2 OR w.res_page_id % 511232 = 0)
                            THEN N' - GAM page: tempdb allocation contention'
                            WHEN w.res_db_id = 2 AND w.res_page_id > 0 AND (w.res_page_id = 3 OR (w.res_page_id - 1) % 511232 = 0)
                            THEN N' - SGAM page: tempdb allocation contention'
                            WHEN w.res_db_id = 2 AND w.res_page_id IS NOT NULL
                            THEN N' - tempdb page (temp table or worktable contention)'
                            ELSE N''
                        END
                    ),
                    1000
                )
            FROM #wr AS w
            LEFT JOIN sys.objects AS o
              ON  o.object_id = w.object_id
              AND w.res_db_id = @db_id
            LEFT JOIN sys.schemas AS s
              ON s.schema_id = o.schema_id
            LEFT JOIN sys.indexes AS i
              ON  i.object_id = w.object_id
              AND i.index_id = w.index_id
              AND w.res_db_id = @db_id
            WHERE w.resource_kind IS NOT NULL;
        END TRY
        BEGIN CATCH
            INSERT #messages (msg_type, section, message)
            VALUES ('INFO', N'waits', LEFT(N'Wait resource names: ' + ERROR_MESSAGE(), 4000));
        END CATCH;
    END;

    /* ============================================================================================
       Input buffers for the sessions that matter: blocking tree, active requests, open transactions
       ============================================================================================ */
    CREATE TABLE #ib
    (
        session_id int NOT NULL PRIMARY KEY,
        priority_rank int NOT NULL,
        input_buffer nvarchar(max) COLLATE DATABASE_DEFAULT NULL
    );

    IF @do_blocking = 1 OR @do_requests = 1 OR @do_transactions = 1
    BEGIN
        BEGIN TRY
            INSERT #ib (session_id, priority_rank)
            SELECT TOP (200)
                x.session_id,
                MIN(x.priority_rank)
            FROM
            (
                SELECT
                    session_id = bn.session_id,
                    priority_rank = 1,
                    age_ms = CONVERT(bigint, 0)
                FROM #blk_nodes AS bn
                WHERE bn.session_id > 0

                UNION ALL

                SELECT
                    r.session_id,
                    2,
                    r.total_elapsed_time
                FROM #req AS r
                JOIN #sess AS s
                  ON s.session_id = r.session_id
                WHERE r.database_id = @db_id
                AND   s.is_user_process = 1

                UNION ALL

                SELECT
                    t.session_id,
                    3,
                    DATEDIFF_BIG(MILLISECOND, t.transaction_begin_time, @now)
                FROM #trn AS t
                JOIN #sess AS s
                  ON s.session_id = t.session_id
                WHERE s.database_id = @db_id
                AND   s.is_user_process = 1
            ) AS x
            GROUP BY
                x.session_id
            ORDER BY
                MIN(x.priority_rank),
                MAX(x.age_ms) DESC;

            UPDATE i
            SET i.input_buffer = ib.event_info
            FROM #ib AS i
            CROSS APPLY sys.dm_exec_input_buffer(i.session_id, NULL) AS ib;
        END TRY
        BEGIN CATCH
            INSERT #messages (msg_type, section, message)
            VALUES ('INFO', N'requests', LEFT(N'sys.dm_exec_input_buffer: ' + ERROR_MESSAGE(), 4000));
        END CATCH;
    END;

    /* ============================================================================================
       200 blocking_tree
       ============================================================================================ */
    IF @do_blocking = 1
    BEGIN
        SELECT
            @rk = N'blocking_tree',
            @t0 = SYSDATETIME();

        INSERT #emit (section_order, section_key, result_key, result_name, table_name, empty_message)
        VALUES (200, N'blocking', @rk, N'BLOCKING TREE (head blockers first)', N'#o_blocking_tree', N'No blocking in this database right now.');

        BEGIN TRY
            SELECT
                rn = n.node_order,
                tree =
                    CASE
                        WHEN n.in_cycle = 1 THEN N'CYCLE? ' + CONVERT(nvarchar(12), n.session_id)
                        WHEN n.is_head = 1 THEN N'HEAD ' + CONVERT(nvarchar(12), n.session_id)
                        ELSE REPLICATE(N'|   ', n.lvl - 1) + N'+-- ' + CONVERT(nvarchar(12), n.session_id)
                    END,
                session_id = n.session_id,
                blocked_by = n.blocked_by,
                also_blocked_by = ob.also_blocked_by,
                head_blocker = n.head_session_id,
                role =
                    CASE
                        WHEN n.in_cycle = 1 THEN N'IN OR BEHIND A BLOCKING CYCLE (no head blocker). Deadlock detection should resolve it; if it persists, investigate.'
                        WHEN n.session_id = -2 THEN N'HEAD BLOCKER - orphaned distributed transaction'
                        WHEN n.session_id = -3 THEN N'HEAD BLOCKER - deferred recovery transaction'
                        WHEN n.session_id = -4 THEN N'HEAD BLOCKER - latch owner unknown (latch state transition)'
                        WHEN n.session_id = -5 THEN N'HEAD BLOCKER - latch owner not tracked (for example an SH latch)'
                        WHEN n.is_head = 1 AND r.session_id IS NULL AND s.session_id IS NULL THEN N'HEAD BLOCKER - session no longer visible'
                        WHEN n.is_head = 1 AND r.session_id IS NULL THEN N'HEAD BLOCKER - idle session holding locks (open transaction, no running request)'
                        WHEN n.is_head = 1 THEN N'HEAD BLOCKER - ' + ISNULL(r.status, N'active') + N' request'
                        WHEN ISNULL(bc.total_blocked, 0) > 0 THEN N'BLOCKED and BLOCKING'
                        ELSE N'BLOCKED'
                    END,
                directly_blocking = ISNULL(bc.direct_blocked, 0),
                total_blocking = ISNULL(bc.total_blocked, 0),
                longest_blocked_wait_ms = bc.max_wait_ms,
                status = ISNULL(r.status, s.status),
                command = r.command,
                wait_type = r.wait_type,
                wait_ms = r.wait_time_ms,
                wait_time =
                    CASE
                        WHEN ms.wait_ms >= 0
                        THEN CONCAT(CASE WHEN ms.wait_ms < 864000000 THEN '0' ELSE '' END, ms.wait_ms / 86400000, ' ', CONVERT(varchar(8), DATEADD(SECOND, CONVERT(int, ms.wait_ms % 86400000 / 1000), CONVERT(time(0), '00:00:00')), 108), '.', RIGHT(CONCAT('00', ms.wait_ms % 1000), 3))
                    END,
                wait_resource = NULLIF(r.wait_resource, N''),
                wait_resource_decoded = wr.decoded,
                open_transactions = ISNULL(r.open_transaction_count, s.open_transaction_count),
                transaction_begin = tr.first_begin,
                transaction_age =
                    CASE
                        WHEN ms.tran_ms >= 0
                        THEN CONCAT(CASE WHEN ms.tran_ms < 864000000 THEN '0' ELSE '' END, ms.tran_ms / 86400000, ' ', CONVERT(varchar(8), DATEADD(SECOND, CONVERT(int, ms.tran_ms % 86400000 / 1000), CONVERT(time(0), '00:00:00')), 108), '.', RIGHT(CONCAT('00', ms.tran_ms % 1000), 3))
                    END,
                transaction_log_mb = CONVERT(decimal(18, 2), tr.log_bytes / 1048576.0),
                isolation_level =
                    CASE ISNULL(r.transaction_isolation_level, s.transaction_isolation_level)
                        WHEN 0 THEN N'Unspecified'
                        WHEN 1 THEN N'Read Uncommitted'
                        WHEN 2 THEN CASE WHEN @rcsi = 1 THEN N'Read Committed (RCSI)' ELSE N'Read Committed' END
                        WHEN 3 THEN N'Repeatable Read'
                        WHEN 4 THEN N'Serializable'
                        WHEN 5 THEN N'Snapshot'
                    END,
                idle_time =
                    CASE
                        WHEN ms.idle_ms >= 0
                        THEN CONCAT(CASE WHEN ms.idle_ms < 864000000 THEN '0' ELSE '' END, ms.idle_ms / 86400000, ' ', CONVERT(varchar(8), DATEADD(SECOND, CONVERT(int, ms.idle_ms % 86400000 / 1000), CONVERT(time(0), '00:00:00')), 108), '.', RIGHT(CONCAT('00', ms.idle_ms % 1000), 3))
                    END,
                login_name = s.login_name,
                host_name = s.host_name,
                program_name = s.program_name,
                client_net_address = s.client_net_address,
                locks_held = hl.locks_held,
                notes =
                    ISNULL(STUFF(CONCAT(
                        /* why this session waits */
                        CASE WHEN r.wait_resource LIKE N'%COMPILE%' THEN N'; waits for a compile lock: another session compiles the same procedure' END,
                        CASE WHEN r.wait_type IN (N'LCK_M_SCH_M', N'LCK_M_SCH_S') THEN N'; schema lock: a DDL statement, index rebuild, partition switch or TRUNCATE is in the chain' END,
                        CASE WHEN r.wait_type LIKE N'LCK[_]M[_]R%' THEN N'; range lock: a SERIALIZABLE transaction is in the chain' END,
                        CASE
                            WHEN r.wait_type IN (N'LCK_M_S', N'LCK_M_IS') AND @rcsi = 0
                            THEN N'; a reader blocked by a writer: READ_COMMITTED_SNAPSHOT would remove this block'
                            WHEN r.wait_type IN (N'LCK_M_S', N'LCK_M_IS') AND ISNULL(r.transaction_isolation_level, s.transaction_isolation_level) = 2
                            THEN N'; a reader takes shared locks although RCSI is on: look for a locking hint (HOLDLOCK, READCOMMITTEDLOCK, TABLOCK)'
                        END,
                        CASE WHEN r.wait_type LIKE N'PAGELATCH%' OR r.wait_type LIKE N'LATCH%' THEN N'; latch wait, not a lock: contention on a page or an internal structure' END,
                        /* why this session blocks others */
                        CASE
                            WHEN ISNULL(bc.total_blocked, 0) > 0 AND ISNULL(r.transaction_isolation_level, s.transaction_isolation_level) IN (3, 4)
                            THEN N'; this blocker runs at REPEATABLE READ or SERIALIZABLE and keeps its shared locks until it commits'
                        END,
                        CASE
                            WHEN ISNULL(bc.total_blocked, 0) > 0
                            AND  EXISTS (SELECT 1/0 FROM #trn AS ti WHERE ti.session_id = n.session_id AND ti.transaction_name = N'implicit_transaction')
                            THEN N'; this blocker uses implicit transactions (SET IMPLICIT_TRANSACTIONS ON): a transaction stays open until the application commits'
                        END
                    ), 1, 2, N''), N''),
                statement_text =
                    CASE
                        WHEN r.sql_handle IS NOT NULL
                        THEN SUBSTRING
                             (
                                 st.text,
                                 ISNULL(r.statement_start_offset, 0) / 2 + 1,
                                 CASE
                                     WHEN ISNULL(r.statement_end_offset, -1) = -1 OR r.statement_end_offset < ISNULL(r.statement_start_offset, 0)
                                     THEN 2147483647
                                     ELSE (r.statement_end_offset - ISNULL(r.statement_start_offset, 0)) / 2 + 1
                                 END
                             )
                        ELSE st.text
                    END,
                input_buffer_text = ib.input_buffer
            INTO #o_blocking_tree
            FROM #blk_nodes AS n
            LEFT JOIN #blk_counts AS bc
              ON bc.session_id = n.session_id
            LEFT JOIN #sess AS s
              ON s.session_id = n.session_id
            OUTER APPLY
            (
                SELECT TOP (1)
                    rq.session_id,
                    rq.status,
                    rq.command,
                    rq.wait_type,
                    rq.wait_time_ms,
                    rq.wait_resource,
                    rq.open_transaction_count,
                    rq.transaction_isolation_level,
                    rq.sql_handle,
                    rq.statement_start_offset,
                    rq.statement_end_offset
                FROM #req AS rq
                WHERE rq.session_id = n.session_id
                ORDER BY
                    CASE WHEN ISNULL(rq.blocking_session_id, 0) <> 0 THEN 0 ELSE 1 END,
                    rq.request_id
            ) AS r
            LEFT JOIN #wr AS wr
              ON wr.resource_text = r.wait_resource
            LEFT JOIN #head_locks AS hl
              ON hl.session_id = n.session_id
            OUTER APPLY
            (
                SELECT
                    also_blocked_by =
                        LEFT(STRING_AGG(CONVERT(nvarchar(max), e.blocker), N', ') WITHIN GROUP (ORDER BY e.wait_ms DESC, e.blocker), 400)
                FROM #blk_edges AS e
                WHERE e.waiter = n.session_id
                AND   e.blocker <> n.blocked_by
            ) AS ob
            LEFT JOIN #ib AS ib
              ON ib.session_id = n.session_id
            OUTER APPLY
            (
                SELECT
                    first_begin = MIN(t.transaction_begin_time),
                    log_bytes = SUM(t.log_bytes_used)
                FROM #trn AS t
                WHERE t.session_id = n.session_id
            ) AS tr
            OUTER APPLY sys.dm_exec_sql_text(ISNULL(r.sql_handle, s.most_recent_sql_handle)) AS st
            CROSS APPLY
            (
                SELECT
                    wait_ms = r.wait_time_ms,
                    tran_ms = DATEDIFF_BIG(MILLISECOND, tr.first_begin, @now),
                    idle_ms =
                        CASE
                            WHEN r.session_id IS NULL AND s.status = N'sleeping'
                            THEN DATEDIFF_BIG(MILLISECOND, s.last_request_end_time, @now)
                        END
            ) AS ms;
        END TRY
        BEGIN CATCH
            UPDATE #emit SET error_message = LEFT(ERROR_MESSAGE(), 4000) WHERE result_key = @rk;
        END CATCH;

        UPDATE #emit SET duration_ms = DATEDIFF_BIG(MILLISECOND, @t0, SYSDATETIME()) WHERE result_key = @rk;
    END;

    /* ============================================================================================
       300 requests
       ============================================================================================ */
    IF @do_requests = 1
    BEGIN
        SELECT
            @rk = N'requests',
            @t0 = SYSDATETIME();

        INSERT #emit (section_order, section_key, result_key, result_name, table_name, empty_message)
        VALUES
        (
            300, N'requests', @rk,
            CASE
                WHEN @is_sampled = 1
                THEN N'ACTIVE REQUESTS (blocking first, then longest running; *_in_sample = delta over ' + CONVERT(nvarchar(20), @sample_s) + N' s)'
                ELSE N'ACTIVE REQUESTS (blocking first, then longest running)'
            END,
            N'#o_requests',
            N'No active user requests in this database.'
        );

        BEGIN TRY
            SELECT
                rn = ROW_NUMBER() OVER (ORDER BY q.sort_group, q.total_elapsed_time DESC, q.session_id, q.request_id),
                session_id = q.session_id,
                request_id = q.request_id,
                blocking =
                    CASE
                        WHEN ISNULL(q.blocking_session_id, 0) <> 0 AND ISNULL(q.total_blocked, 0) > 0
                        THEN CONCAT(N'BLOCKED BY ', bl.blocker_label, N', BLOCKING ', q.total_blocked)
                        WHEN ISNULL(q.blocking_session_id, 0) <> 0
                        THEN CONCAT(N'BLOCKED BY ', bl.blocker_label)
                        WHEN ISNULL(q.total_blocked, 0) > 0
                        THEN CONCAT(N'HEAD BLOCKER, BLOCKING ', q.total_blocked)
                        ELSE N''
                    END,
                blocking_session_id = NULLIF(q.blocking_session_id, 0),
                status = q.status,
                command = q.command,
                elapsed =
                    CASE
                        WHEN q.total_elapsed_time >= 0
                        THEN CONCAT(CASE WHEN q.total_elapsed_time < 864000000 THEN '0' ELSE '' END, q.total_elapsed_time / 86400000, ' ', CONVERT(varchar(8), DATEADD(SECOND, CONVERT(int, q.total_elapsed_time % 86400000 / 1000), CONVERT(time(0), '00:00:00')), 108), '.', RIGHT(CONCAT('00', q.total_elapsed_time % 1000), 3))
                    END,
                elapsed_ms = q.total_elapsed_time,
                is_long_running = CONVERT(bit, CASE WHEN q.total_elapsed_time >= @long_running_seconds * 1000.0 THEN 1 ELSE 0 END),
                percent_complete = CASE WHEN q.percent_complete > 0 THEN CONVERT(decimal(9, 2), q.percent_complete) END,
                estimated_remaining =
                    CASE
                        WHEN q.percent_complete > 0 AND q.estimated_completion_time >= 0
                        THEN CONCAT(CASE WHEN q.estimated_completion_time < 864000000 THEN '0' ELSE '' END, q.estimated_completion_time / 86400000, ' ', CONVERT(varchar(8), DATEADD(SECOND, CONVERT(int, q.estimated_completion_time % 86400000 / 1000), CONVERT(time(0), '00:00:00')), 108), '.', RIGHT(CONCAT('00', q.estimated_completion_time % 1000), 3))
                    END,
                wait_type = q.wait_type,
                wait_ms = CASE WHEN q.wait_type IS NOT NULL THEN q.wait_time_ms END,
                wait_category = wc.category,
                wait_resource = NULLIF(q.wait_resource, N''),
                wait_resource_decoded = wr.decoded,
                last_wait_type = q.last_wait_type,
                cpu_ms = q.cpu_time,
                logical_reads = q.logical_reads,
                physical_reads = q.reads,
                page_server_reads = q.page_server_reads,
                writes = q.writes,
                cpu_ms_in_sample = CASE WHEN s1.session_id IS NOT NULL THEN q.cpu_time - s1.cpu_time END,
                logical_reads_in_sample = CASE WHEN s1.session_id IS NOT NULL THEN q.logical_reads - s1.logical_reads END,
                physical_reads_in_sample = CASE WHEN s1.session_id IS NOT NULL THEN q.reads - s1.reads END,
                page_server_reads_in_sample = CASE WHEN s1.session_id IS NOT NULL THEN q.page_server_reads - s1.page_server_reads END,
                writes_in_sample = CASE WHEN s1.session_id IS NOT NULL THEN q.writes - s1.writes END,
                avg_cores_in_sample =
                    CASE
                        WHEN s1.session_id IS NOT NULL AND @sample_s > 0
                        THEN CONVERT(decimal(9, 2), (q.cpu_time - s1.cpu_time) / (@sample_s * 1000.0))
                    END,
                row_count = q.row_count,
                dop = q.dop,
                parallel_workers = q.parallel_worker_count,
                memory_grant_mb = CONVERT(decimal(18, 2), g.granted_memory_kb / 1024.0),
                memory_requested_mb = CONVERT(decimal(18, 2), g.requested_memory_kb / 1024.0),
                memory_used_mb = CONVERT(decimal(18, 2), g.used_memory_kb / 1024.0),
                grant_wait_ms = CASE WHEN g.session_id IS NOT NULL AND g.grant_time IS NULL THEN g.wait_time_ms END,
                tempdb_mb =
                    CONVERT
                    (
                        decimal(18, 2),
                        (ISNULL(tsu.session_user_pages, 0) + ISNULL(tsu.session_internal_pages, 0) + ISNULL(tsu.task_user_pages, 0) + ISNULL(tsu.task_internal_pages, 0)) * 8 / 1024.0
                    ),
                open_transactions = q.open_transaction_count,
                transaction_age =
                    CASE
                        WHEN ms.tran_ms >= 0
                        THEN CONCAT(CASE WHEN ms.tran_ms < 864000000 THEN '0' ELSE '' END, ms.tran_ms / 86400000, ' ', CONVERT(varchar(8), DATEADD(SECOND, CONVERT(int, ms.tran_ms % 86400000 / 1000), CONVERT(time(0), '00:00:00')), 108), '.', RIGHT(CONCAT('00', ms.tran_ms % 1000), 3))
                    END,
                transaction_log_mb = CONVERT(decimal(18, 2), tr.log_bytes / 1048576.0),
                isolation_level =
                    CASE q.transaction_isolation_level
                        WHEN 0 THEN N'Unspecified'
                        WHEN 1 THEN N'Read Uncommitted'
                        WHEN 2 THEN CASE WHEN @rcsi = 1 THEN N'Read Committed (RCSI)' ELSE N'Read Committed' END
                        WHEN 3 THEN N'Repeatable Read'
                        WHEN 4 THEN N'Serializable'
                        WHEN 5 THEN N'Snapshot'
                    END,
                login_name = s.login_name,
                host_name = s.host_name,
                program_name = s.program_name,
                client_net_address = s.client_net_address,
                module_name = mo.module_name,
                query_hash = CONVERT(varchar(130), q.query_hash, 1),
                query_plan_hash = CONVERT(varchar(130), q.query_plan_hash, 1),
                plan_handle = CONVERT(varchar(130), q.plan_handle, 1),
                sql_handle = CONVERT(varchar(130), q.sql_handle, 1),
                statement_text =
                    SUBSTRING
                    (
                        st.text,
                        ISNULL(q.statement_start_offset, 0) / 2 + 1,
                        CASE
                            WHEN ISNULL(q.statement_end_offset, -1) = -1 OR q.statement_end_offset < ISNULL(q.statement_start_offset, 0)
                            THEN 2147483647
                            ELSE (q.statement_end_offset - ISNULL(q.statement_start_offset, 0)) / 2 + 1
                        END
                    ),
                input_buffer_text = ib.input_buffer
            INTO #o_requests
            FROM
            (
                SELECT TOP (@top_n)
                    r.*,
                    sort_group =
                        CASE
                            WHEN ISNULL(c.total_blocked, 0) > 0 AND ISNULL(r.blocking_session_id, 0) = 0 THEN 0
                            WHEN ISNULL(r.blocking_session_id, 0) <> 0 THEN 1
                            ELSE 2
                        END,
                    total_blocked = c.total_blocked
                FROM #req AS r
                LEFT JOIN #sess AS ss
                  ON ss.session_id = r.session_id
                LEFT JOIN #blk_counts AS c
                  ON c.session_id = r.session_id
                WHERE
                (
                    r.database_id = @db_id
                    AND ISNULL(ss.is_user_process, 1) = 1
                )
                OR EXISTS
                (
                    SELECT
                        1/0
                    FROM #blk_nodes AS bn
                    WHERE bn.session_id = r.session_id
                )
                ORDER BY
                    sort_group,
                    r.total_elapsed_time DESC
            ) AS q
            LEFT JOIN #sess AS s
              ON s.session_id = q.session_id
            LEFT JOIN #req_sample1 AS s1
              ON  s1.session_id = q.session_id
              AND s1.request_id = q.request_id
              AND s1.start_time = q.start_time
            LEFT JOIN #wr AS wr
              ON wr.resource_text = q.wait_resource
            LEFT JOIN #tsu AS tsu
              ON tsu.session_id = q.session_id
            LEFT JOIN #ib AS ib
              ON ib.session_id = q.session_id
            OUTER APPLY
            (
                SELECT TOP (1)
                    gg.session_id,
                    gg.granted_memory_kb,
                    gg.requested_memory_kb,
                    gg.used_memory_kb,
                    gg.grant_time,
                    gg.wait_time_ms
                FROM #grants AS gg
                WHERE gg.session_id = q.session_id
                AND   gg.request_id = q.request_id
            ) AS g
            OUTER APPLY
            (
                SELECT
                    first_begin = MIN(t.transaction_begin_time),
                    log_bytes = SUM(t.log_bytes_used)
                FROM #trn AS t
                WHERE t.session_id = q.session_id
            ) AS tr
            OUTER APPLY
            (
                SELECT TOP (1)
                    c.category
                FROM #wait_cat AS c
                WHERE q.wait_type LIKE c.pattern
                ORDER BY
                    c.priority
            ) AS wc
            OUTER APPLY sys.dm_exec_sql_text(q.sql_handle) AS st
            OUTER APPLY
            (
                SELECT
                    module_name = QUOTENAME(sc.name) + N'.' + QUOTENAME(o.name)
                FROM sys.objects AS o
                JOIN sys.schemas AS sc
                  ON sc.schema_id = o.schema_id
                WHERE o.object_id = st.objectid
                AND   st.dbid = @db_id
            ) AS mo
            CROSS APPLY
            (
                SELECT
                    blocker_label =
                        CASE q.blocking_session_id
                            WHEN -2 THEN N'an orphaned distributed transaction (-2)'
                            WHEN -3 THEN N'a deferred recovery transaction (-3)'
                            WHEN -4 THEN N'a latch, owner unknown (-4)'
                            WHEN -5 THEN N'a latch, owner not tracked (-5)'
                            ELSE CONVERT(nvarchar(12), q.blocking_session_id)
                        END
            ) AS bl
            CROSS APPLY
            (
                SELECT
                    tran_ms = DATEDIFF_BIG(MILLISECOND, tr.first_begin, @now)
            ) AS ms;
        END TRY
        BEGIN CATCH
            UPDATE #emit SET error_message = LEFT(ERROR_MESSAGE(), 4000) WHERE result_key = @rk;
        END CATCH;

        /* Optional plans: live in-flight plan first (lightweight profiling), cached plan as fallback */
        IF @include_plans = 1 AND OBJECT_ID(N'tempdb..#o_requests') IS NOT NULL
        BEGIN
            BEGIN TRY
                ALTER TABLE #o_requests ADD query_plan xml NULL;

                UPDATE o
                SET o.query_plan = ISNULL(lp.query_plan, TRY_CONVERT(xml, cp.query_plan))
                FROM #o_requests AS o
                JOIN #req AS r
                  ON  r.session_id = o.session_id
                  AND r.request_id = o.request_id
                OUTER APPLY
                (
                    SELECT TOP (1)
                        x.query_plan
                    FROM sys.dm_exec_query_statistics_xml(o.session_id) AS x
                    WHERE x.request_id = o.request_id
                ) AS lp
                OUTER APPLY sys.dm_exec_text_query_plan(r.plan_handle, ISNULL(r.statement_start_offset, 0), ISNULL(r.statement_end_offset, -1)) AS cp
                WHERE r.plan_handle IS NOT NULL;
            END TRY
            BEGIN CATCH
                INSERT #messages (msg_type, section, message)
                VALUES ('INFO', N'requests', LEFT(N'Query plans for requests: ' + ERROR_MESSAGE(), 4000));
            END CATCH;

            /* Parameter values from the plan: the values that the plan was compiled for and, in a
               live plan, the values of this execution. A large difference in what the two select is
               the sign of parameter sniffing. Dynamic SQL: the column is new at this point, and an
               error there must become a message. */
            IF COL_LENGTH(N'tempdb..#o_requests', N'query_plan') IS NOT NULL
            BEGIN
                BEGIN TRY
                    ALTER TABLE #o_requests ADD plan_parameters nvarchar(max) NULL;

                    EXEC sys.sp_executesql N'
WITH XMLNAMESPACES (DEFAULT ''http://schemas.microsoft.com/sqlserver/2004/07/showplan'')
UPDATE o
SET o.plan_parameters = x.params
FROM #o_requests AS o
CROSS APPLY
(
    SELECT
        params =
            LEFT
            (
                STRING_AGG
                (
                    CONVERT(nvarchar(max), CONCAT(p.name, N'' compiled '', ISNULL(p.compiled_value, N''?''), N'', runtime '' + p.runtime_value)),
                    N''; ''
                ),
                4000
            )
    FROM
    (
        SELECT DISTINCT
            name = c.n.value(''@Column'', ''nvarchar(128)''),
            compiled_value = c.n.value(''@ParameterCompiledValue'', ''nvarchar(400)''),
            runtime_value = c.n.value(''@ParameterRuntimeValue'', ''nvarchar(400)'')
        FROM o.query_plan.nodes(''//ParameterList/ColumnReference'') AS c (n)
    ) AS p
) AS x
WHERE o.query_plan IS NOT NULL;';
                END TRY
                BEGIN CATCH
                    INSERT #messages (msg_type, section, message)
                    VALUES ('INFO', N'requests', LEFT(N'Plan parameters for requests: ' + ERROR_MESSAGE(), 4000));
                END CATCH;
            END;
        END;

        UPDATE #emit SET duration_ms = DATEDIFF_BIG(MILLISECOND, @t0, SYSDATETIME()) WHERE result_key = @rk;
    END;

    /* ============================================================================================
       400 waits_now, 410 wait_stats, 420 index_lock_waits
       ============================================================================================ */
    IF @do_waits = 1
    BEGIN
        SELECT
            @rk = N'waits_now',
            @t0 = SYSDATETIME();

        INSERT #emit (section_order, section_key, result_key, result_name, table_name, empty_message)
        VALUES (400, N'waits', @rk, N'WAITING RIGHT NOW (tasks in this database by wait type, plus tasks that wait for a worker thread)', N'#o_waits_now', N'No user tasks are waiting right now.');

        BEGIN TRY
            WITH
                w AS
                (
                    SELECT
                        wt.wait_type,
                        wt.session_id,
                        wt.wait_duration_ms,
                        wt.blocking_session_id,
                        wt.resource_description,
                        rnk = ROW_NUMBER() OVER (PARTITION BY wt.wait_type ORDER BY wt.wait_duration_ms DESC, wt.session_id)
                    FROM #wt AS wt
                    LEFT JOIN #sess AS s
                      ON s.session_id = wt.session_id
                    WHERE wt.task_rank = 1
                    AND
                    (
                        /* THREADPOOL waiters have no session yet */
                        (wt.session_id IS NULL AND wt.wait_type = N'THREADPOOL')
                        OR
                        (
                            s.database_id = @db_id
                            AND
                            (
                                s.is_user_process = 1
                                OR EXISTS (SELECT 1/0 FROM #blk_nodes AS bn WHERE bn.session_id = wt.session_id)
                            )
                        )
                    )
                    AND NOT EXISTS
                    (
                        SELECT
                            1/0
                        FROM #benign_waits AS b
                        WHERE b.wait_type = wt.wait_type
                    )
                ),
                a AS
                (
                    SELECT
                        w.wait_type,
                        waiting_tasks = COUNT_BIG(*),
                        sessions = COUNT(DISTINCT w.session_id),
                        total_wait_ms = SUM(w.wait_duration_ms),
                        avg_wait_ms = AVG(w.wait_duration_ms),
                        max_wait_ms = MAX(w.wait_duration_ms),
                        blocked_tasks = SUM(CASE WHEN ISNULL(w.blocking_session_id, 0) <> 0 AND w.blocking_session_id <> w.session_id THEN 1 ELSE 0 END)
                    FROM w
                    GROUP BY
                        w.wait_type
                )
            SELECT
                rn = ROW_NUMBER() OVER (ORDER BY a.total_wait_ms DESC, a.wait_type),
                wait_type = a.wait_type,
                category = c.category,
                waiting_tasks = a.waiting_tasks,
                sessions = a.sessions,
                blocked_tasks = a.blocked_tasks,
                total_wait_ms = a.total_wait_ms,
                avg_wait_ms = a.avg_wait_ms,
                max_wait_ms = a.max_wait_ms,
                longest_waiter_session_id = l.session_id,
                longest_waiter_blocked_by = CASE WHEN l.blocking_session_id NOT IN (0, l.session_id) THEN l.blocking_session_id END,
                longest_waiter_resource = LEFT(l.resource_description, 256),
                longest_waiter_resource_decoded = wr.decoded,
                explanation = c.explanation
            INTO #o_waits_now
            FROM a
            JOIN w AS l
              ON  l.wait_type = a.wait_type
              AND l.rnk = 1
            LEFT JOIN #wr AS wr
              ON wr.resource_text = l.resource_description
            OUTER APPLY
            (
                SELECT TOP (1)
                    wc.category,
                    wc.explanation
                FROM #wait_cat AS wc
                WHERE a.wait_type LIKE wc.pattern
                ORDER BY
                    wc.priority
            ) AS c;
        END TRY
        BEGIN CATCH
            UPDATE #emit SET error_message = LEFT(ERROR_MESSAGE(), 4000) WHERE result_key = @rk;
        END CATCH;

        UPDATE #emit SET duration_ms = DATEDIFF_BIG(MILLISECOND, @t0, SYSDATETIME()) WHERE result_key = @rk;

        SELECT
            @rk = N'wait_stats',
            @t0 = SYSDATETIME();

        INSERT #emit (section_order, section_key, result_key, result_name, table_name, empty_message)
        VALUES
        (
            410, N'waits', @rk,
            CASE
                WHEN @is_sampled = 1
                THEN N'DATABASE WAIT STATS - DELTA OVER ' + CONVERT(nvarchar(20), @sample_s) + N' s (benign waits excluded; the waits of a request can arrive here only after it ends: see session_waits_sampled)'
                ELSE N'DATABASE WAIT STATS - CUMULATIVE (benign waits excluded; use @sample_seconds for a live delta)'
            END,
            N'#o_wait_stats',
            N'No significant waits recorded.'
        );

        BEGIN TRY
            WITH
                d AS
                (
                    SELECT
                        w2.wait_type,
                        wait_ms = w2.wait_time_ms - ISNULL(w1.wait_time_ms, 0),
                        waiting_tasks = w2.waiting_tasks_count - ISNULL(w1.waiting_tasks_count, 0),
                        signal_ms = w2.signal_wait_time_ms - ISNULL(w1.signal_wait_time_ms, 0),
                        max_wait_ms = w2.max_wait_time_ms
                    FROM #waits_snap AS w2
                    LEFT JOIN #waits_snap AS w1
                      ON  w1.sample_no = 1
                      AND w1.wait_type = w2.wait_type
                    WHERE w2.sample_no = 2
                    AND NOT EXISTS
                    (
                        SELECT
                            1/0
                        FROM #benign_waits AS b
                        WHERE b.wait_type = w2.wait_type
                    )
                ),
                t AS
                (
                    SELECT
                        d.wait_type,
                        d.wait_ms,
                        d.waiting_tasks,
                        d.signal_ms,
                        d.max_wait_ms,
                        total_ms = SUM(d.wait_ms) OVER ()
                    FROM d
                    WHERE d.wait_ms > 0
                )
            SELECT TOP (@top_n)
                rn = ROW_NUMBER() OVER (ORDER BY t.wait_ms DESC, t.wait_type),
                wait_type = t.wait_type,
                category = c.category,
                wait_ms = t.wait_ms,
                wait_time =
                    CONCAT(CASE WHEN t.wait_ms < 864000000 THEN '0' ELSE '' END, t.wait_ms / 86400000, ' ', CONVERT(varchar(8), DATEADD(SECOND, CONVERT(int, t.wait_ms % 86400000 / 1000), CONVERT(time(0), '00:00:00')), 108), '.', RIGHT(CONCAT('00', t.wait_ms % 1000), 3)),
                pct_of_wait_time = CONVERT(decimal(9, 2), 100.0 * t.wait_ms / NULLIF(t.total_ms, 0)),
                waiting_tasks = t.waiting_tasks,
                avg_wait_ms = CONVERT(decimal(18, 2), 1.0 * t.wait_ms / NULLIF(t.waiting_tasks, 0)),
                signal_wait_pct = CONVERT(decimal(9, 2), 100.0 * t.signal_ms / NULLIF(t.wait_ms, 0)),
                avg_concurrent_waiters = CONVERT(decimal(18, 2), 1.0 * t.wait_ms / NULLIF(win.window_ms, 0)),
                max_wait_ms_since_start = t.max_wait_ms,
                explanation = c.explanation,
                measured_over = win.measured_over
            INTO #o_wait_stats
            FROM t
            CROSS JOIN
            (
                SELECT
                    window_ms =
                        CASE
                            WHEN @is_sampled = 1 THEN CONVERT(bigint, @sample_s * 1000)
                            ELSE DATEDIFF_BIG(MILLISECOND, @instance_start, @now)
                        END,
                    measured_over =
                        CASE
                            WHEN @is_sampled = 1 THEN CONCAT(N'delta over ', @sample_s, N' s')
                            ELSE CONCAT(N'cumulative since about ', CONVERT(nvarchar(19), @instance_start, 120), N' UTC (instance start)')
                        END
            ) AS win
            OUTER APPLY
            (
                SELECT TOP (1)
                    wc.category,
                    wc.explanation
                FROM #wait_cat AS wc
                WHERE t.wait_type LIKE wc.pattern
                ORDER BY
                    wc.priority
            ) AS c
            ORDER BY
                t.wait_ms DESC;
        END TRY
        BEGIN CATCH
            UPDATE #emit SET error_message = LEFT(ERROR_MESSAGE(), 4000) WHERE result_key = @rk;
        END CATCH;

        UPDATE #emit SET duration_ms = DATEDIFF_BIG(MILLISECOND, @t0, SYSDATETIME()) WHERE result_key = @rk;

        IF @is_sampled = 1
        BEGIN
            SELECT
                @rk = N'session_waits_sampled',
                @t0 = SYSDATETIME();

            INSERT #emit (section_order, section_key, result_key, result_name, table_name, empty_message)
            VALUES
            (
                415, N'waits', @rk,
                N'SESSION WAITS - DELTA OVER ' + CONVERT(nvarchar(20), @sample_s) + N' s (user sessions in this database, requests that still run included; benign waits excluded)',
                N'#o_session_waits_sampled',
                N'No user session in this database recorded a wait during the sample.'
            );

            BEGIN TRY
                WITH
                    d AS
                    (
                        SELECT
                            w2.session_id,
                            w2.wait_type,
                            wait_ms = w2.wait_time_ms - ISNULL(w1.wait_time_ms, 0),
                            waiting_tasks = w2.waiting_tasks_count - ISNULL(w1.waiting_tasks_count, 0),
                            signal_ms = w2.signal_wait_time_ms - ISNULL(w1.signal_wait_time_ms, 0)
                        FROM #sess_waits_snap AS w2
                        LEFT JOIN #sess_waits_snap AS w1
                          ON  w1.sample_no = 1
                          AND w1.session_id = w2.session_id
                          AND w1.wait_type = w2.wait_type
                        WHERE w2.sample_no = 2
                        /* A session that was reset between the samples has lower counters: skip it */
                        AND   w2.wait_time_ms - ISNULL(w1.wait_time_ms, 0) > 0
                        AND   NOT EXISTS
                        (
                            SELECT
                                1/0
                            FROM #benign_waits AS b
                            WHERE b.wait_type = w2.wait_type
                        )
                    ),
                    r AS
                    (
                        SELECT
                            d.session_id,
                            d.wait_type,
                            d.wait_ms,
                            d.waiting_tasks,
                            d.signal_ms,
                            srn = ROW_NUMBER() OVER (PARTITION BY d.wait_type ORDER BY d.wait_ms DESC, d.session_id)
                        FROM d
                    ),
                    a AS
                    (
                        SELECT
                            r.wait_type,
                            wait_ms = SUM(r.wait_ms),
                            waiting_tasks = SUM(r.waiting_tasks),
                            signal_ms = SUM(r.signal_ms),
                            sessions = COUNT_BIG(*),
                            top_session_id = MAX(CASE WHEN r.srn = 1 THEN r.session_id END),
                            top_session_wait_ms = MAX(CASE WHEN r.srn = 1 THEN r.wait_ms END)
                        FROM r
                        GROUP BY
                            r.wait_type
                    )
                SELECT TOP (@top_n)
                    rn = ROW_NUMBER() OVER (ORDER BY a.wait_ms DESC, a.wait_type),
                    wait_type = a.wait_type,
                    category = c.category,
                    wait_ms = a.wait_ms,
                    pct_of_wait_time = CONVERT(decimal(9, 2), 100.0 * a.wait_ms / NULLIF(SUM(a.wait_ms) OVER (), 0)),
                    waiting_tasks = a.waiting_tasks,
                    avg_wait_ms = CONVERT(decimal(18, 2), 1.0 * a.wait_ms / NULLIF(a.waiting_tasks, 0)),
                    signal_wait_pct = CONVERT(decimal(18, 2), 100.0 * a.signal_ms / NULLIF(a.wait_ms, 0)),
                    avg_concurrent_waiters = CONVERT(decimal(18, 2), 1.0 * a.wait_ms / NULLIF(CONVERT(bigint, @sample_s * 1000), 0)),
                    sessions = a.sessions,
                    top_session_id = a.top_session_id,
                    top_session_wait_ms = a.top_session_wait_ms,
                    explanation = c.explanation
                INTO #o_session_waits_sampled
                FROM a
                OUTER APPLY
                (
                    SELECT TOP (1)
                        wc.category,
                        wc.explanation
                    FROM #wait_cat AS wc
                    WHERE a.wait_type LIKE wc.pattern
                    ORDER BY
                        wc.priority
                ) AS c
                ORDER BY
                    a.wait_ms DESC,
                    a.wait_type;
            END TRY
            BEGIN CATCH
                UPDATE #emit SET error_message = LEFT(ERROR_MESSAGE(), 4000) WHERE result_key = @rk;
            END CATCH;

            UPDATE #emit SET duration_ms = DATEDIFF_BIG(MILLISECOND, @t0, SYSDATETIME()) WHERE result_key = @rk;
        END;

        SELECT
            @rk = N'index_lock_waits',
            @t0 = SYSDATETIME();

        INSERT #emit (section_order, section_key, result_key, result_name, table_name, empty_message)
        VALUES (420, N'waits', @rk, N'LOCK AND LATCH WAITS BY INDEX (cumulative while the index metadata is cached)', N'#o_index_lock_waits', N'No lock or latch waits recorded against user indexes.');

        BEGIN TRY
            SELECT TOP (@top_n)
                rn = ROW_NUMBER() OVER (ORDER BY x.total_wait_ms DESC, x.object_id, x.index_id),
                schema_name = sc.name,
                table_name = o.name,
                index_name = i.name,
                index_type = i.type_desc,
                total_wait_ms = x.total_wait_ms,
                row_lock_waits = x.row_lock_wait_count,
                row_lock_wait_ms = x.row_lock_wait_in_ms,
                page_lock_waits = x.page_lock_wait_count,
                page_lock_wait_ms = x.page_lock_wait_in_ms,
                page_latch_waits = x.page_latch_wait_count,
                page_latch_wait_ms = x.page_latch_wait_in_ms,
                tree_page_latch_waits = x.tree_page_latch_wait_count,
                page_io_latch_waits = x.page_io_latch_wait_count,
                page_io_latch_wait_ms = x.page_io_latch_wait_in_ms,
                lock_escalation_attempts = x.index_lock_promotion_attempt_count,
                lock_escalations = x.index_lock_promotion_count,
                leaf_inserts = x.leaf_insert_count,
                leaf_updates = x.leaf_update_count,
                leaf_deletes = x.leaf_delete_count,
                range_scans = x.range_scan_count,
                singleton_lookups = x.singleton_lookup_count
            INTO #o_index_lock_waits
            FROM
            (
                SELECT
                    ios.object_id,
                    ios.index_id,
                    row_lock_wait_count = SUM(ios.row_lock_wait_count),
                    row_lock_wait_in_ms = SUM(ios.row_lock_wait_in_ms),
                    page_lock_wait_count = SUM(ios.page_lock_wait_count),
                    page_lock_wait_in_ms = SUM(ios.page_lock_wait_in_ms),
                    page_latch_wait_count = SUM(ios.page_latch_wait_count),
                    page_latch_wait_in_ms = SUM(ios.page_latch_wait_in_ms),
                    tree_page_latch_wait_count = SUM(ios.tree_page_latch_wait_count),
                    page_io_latch_wait_count = SUM(ios.page_io_latch_wait_count),
                    page_io_latch_wait_in_ms = SUM(ios.page_io_latch_wait_in_ms),
                    index_lock_promotion_attempt_count = SUM(ios.index_lock_promotion_attempt_count),
                    index_lock_promotion_count = SUM(ios.index_lock_promotion_count),
                    leaf_insert_count = SUM(ios.leaf_insert_count),
                    leaf_update_count = SUM(ios.leaf_update_count),
                    leaf_delete_count = SUM(ios.leaf_delete_count),
                    range_scan_count = SUM(ios.range_scan_count),
                    singleton_lookup_count = SUM(ios.singleton_lookup_count),
                    total_wait_ms = SUM(ios.row_lock_wait_in_ms + ios.page_lock_wait_in_ms + ios.page_latch_wait_in_ms + ios.page_io_latch_wait_in_ms)
                FROM sys.dm_db_index_operational_stats(@db_id, NULL, NULL, NULL) AS ios
                GROUP BY
                    ios.object_id,
                    ios.index_id
            ) AS x
            JOIN sys.objects AS o
              ON o.object_id = x.object_id
            JOIN sys.schemas AS sc
              ON sc.schema_id = o.schema_id
            LEFT JOIN sys.indexes AS i
              ON  i.object_id = x.object_id
              AND i.index_id = x.index_id
            WHERE o.is_ms_shipped = 0
            AND   (x.total_wait_ms > 0 OR x.index_lock_promotion_count > 0)
            ORDER BY
                x.total_wait_ms DESC;
        END TRY
        BEGIN CATCH
            UPDATE #emit SET error_message = LEFT(ERROR_MESSAGE(), 4000) WHERE result_key = @rk;
        END CATCH;

        UPDATE #emit SET duration_ms = DATEDIFF_BIG(MILLISECOND, @t0, SYSDATETIME()) WHERE result_key = @rk;
    END;

    /* ============================================================================================
       500 resource_stats, 510 resource_samples (slow), 520 governance, 530 schedulers,
       540 workload_group, 550 perf_counters
       ============================================================================================ */
    IF @do_resources = 1
    BEGIN
        SELECT
            @rk = N'resource_stats',
            @t0 = SYSDATETIME();

        INSERT #emit (section_order, section_key, result_key, result_name, table_name, empty_message)
        VALUES (500, N'resources', @rk, N'SERVICE OBJECTIVE UTILIZATION % (sys.dm_db_resource_stats, 15-second samples)', N'#o_resource_stats', N'sys.dm_db_resource_stats returned no rows.');

        BEGIN TRY
            WITH
                rs AS
                (
                    SELECT
                        s.end_time,
                        s.avg_cpu_percent,
                        s.avg_data_io_percent,
                        s.avg_log_write_percent,
                        s.max_worker_percent,
                        s.max_session_percent,
                        s.avg_memory_usage_percent,
                        s.avg_instance_cpu_percent,
                        s.avg_instance_memory_percent,
                        s.xtp_storage_percent
                    FROM sys.dm_db_resource_stats AS s
                ),
                mx AS
                (
                    SELECT
                        max_end = MAX(rs.end_time)
                    FROM rs
                ),
                u AS
                (
                    SELECT
                        rs.end_time,
                        v.metric_order,
                        v.metric,
                        v.val,
                        v.meaning
                    FROM rs
                    CROSS APPLY
                    (
                        VALUES
                            (1, N'cpu_percent', CONVERT(decimal(9, 2), rs.avg_cpu_percent), N'CPU used versus the service objective limit. Sustained > 80% means CPU-bound: tune the top CPU queries or scale up.'),
                            (2, N'data_io_percent', CONVERT(decimal(9, 2), rs.avg_data_io_percent), N'Data file IO versus the IOPS limit. High values with PAGEIOLATCH waits mean read-bound: indexes, scans, memory.'),
                            (3, N'log_write_percent', CONVERT(decimal(9, 2), rs.avg_log_write_percent), N'Log generation versus the log-rate limit. Near 100% throttles writes (LOG_RATE_GOVERNOR): batch or reduce writes.'),
                            (4, N'worker_percent', CONVERT(decimal(9, 2), rs.max_worker_percent), N'Concurrent workers versus the limit. At 100% new requests fail with error 10928: blocking or long requests piling up.'),
                            (5, N'session_percent', CONVERT(decimal(9, 2), rs.max_session_percent), N'Sessions versus the limit. At 100% new logins fail with error 10928: connection leaks or pool sizing.'),
                            (6, N'memory_percent', CONVERT(decimal(9, 2), rs.avg_memory_usage_percent), N'Memory in use (buffer pool, caches, grants). High values are normal; the cache fills memory by design.'),
                            (7, N'instance_cpu_percent', CONVERT(decimal(9, 2), rs.avg_instance_cpu_percent), N'CPU of the whole SQL instance, including internal tasks and other databases in the pool.'),
                            (8, N'instance_memory_percent', CONVERT(decimal(9, 2), rs.avg_instance_memory_percent), N'Memory of the whole SQL instance.'),
                            (9, N'xtp_storage_percent', CONVERT(decimal(9, 2), rs.xtp_storage_percent), N'In-memory OLTP storage versus the limit (NULL or 0 when not used).')
                    ) AS v (metric_order, metric, val, meaning)
                )
            SELECT
                rn = u.metric_order,
                metric = u.metric,
                latest = MAX(CASE WHEN u.end_time = mx.max_end THEN u.val END),
                avg_1_min = CONVERT(decimal(9, 2), AVG(CASE WHEN u.end_time > DATEADD(SECOND, -60, mx.max_end) THEN u.val END)),
                max_1_min = MAX(CASE WHEN u.end_time > DATEADD(SECOND, -60, mx.max_end) THEN u.val END),
                avg_5_min = CONVERT(decimal(9, 2), AVG(CASE WHEN u.end_time > DATEADD(MINUTE, -5, mx.max_end) THEN u.val END)),
                max_5_min = MAX(CASE WHEN u.end_time > DATEADD(MINUTE, -5, mx.max_end) THEN u.val END),
                avg_15_min = CONVERT(decimal(9, 2), AVG(CASE WHEN u.end_time > DATEADD(MINUTE, -15, mx.max_end) THEN u.val END)),
                max_15_min = MAX(CASE WHEN u.end_time > DATEADD(MINUTE, -15, mx.max_end) THEN u.val END),
                avg_60_min = CONVERT(decimal(9, 2), AVG(CASE WHEN u.end_time > DATEADD(MINUTE, -60, mx.max_end) THEN u.val END)),
                max_60_min = MAX(CASE WHEN u.end_time > DATEADD(MINUTE, -60, mx.max_end) THEN u.val END),
                latest_sample_utc = MAX(mx.max_end),
                meaning = MAX(u.meaning)
            INTO #o_resource_stats
            FROM u
            CROSS JOIN mx
            GROUP BY
                u.metric_order,
                u.metric;
        END TRY
        BEGIN CATCH
            UPDATE #emit SET error_message = LEFT(ERROR_MESSAGE(), 4000) WHERE result_key = @rk;
        END CATCH;

        UPDATE #emit SET duration_ms = DATEDIFF_BIG(MILLISECOND, @t0, SYSDATETIME()) WHERE result_key = @rk;

        IF @slow = 1
        BEGIN
            SELECT
                @rk = N'resource_samples',
                @t0 = SYSDATETIME();

            INSERT #emit (section_order, section_key, result_key, result_name, table_name, empty_message)
            VALUES (510, N'resources', @rk, N'RESOURCE SAMPLES - LAST 15 MINUTES (newest first)', N'#o_resource_samples', N'sys.dm_db_resource_stats returned no rows.');

            BEGIN TRY
                SELECT
                    rn = ROW_NUMBER() OVER (ORDER BY s.end_time DESC),
                    end_time_utc = s.end_time,
                    cpu_percent = s.avg_cpu_percent,
                    data_io_percent = s.avg_data_io_percent,
                    log_write_percent = s.avg_log_write_percent,
                    worker_percent = s.max_worker_percent,
                    session_percent = s.max_session_percent,
                    memory_percent = s.avg_memory_usage_percent,
                    instance_cpu_percent = s.avg_instance_cpu_percent,
                    instance_memory_percent = s.avg_instance_memory_percent
                INTO #o_resource_samples
                FROM sys.dm_db_resource_stats AS s
                WHERE s.end_time > DATEADD(MINUTE, -15, (SELECT MAX(s2.end_time) FROM sys.dm_db_resource_stats AS s2));
            END TRY
            BEGIN CATCH
                UPDATE #emit SET error_message = LEFT(ERROR_MESSAGE(), 4000) WHERE result_key = @rk;
            END CATCH;

            UPDATE #emit SET duration_ms = DATEDIFF_BIG(MILLISECOND, @t0, SYSDATETIME()) WHERE result_key = @rk;
        END;

        SELECT
            @rk = N'governance',
            @t0 = SYSDATETIME();

        INSERT #emit (section_order, section_key, result_key, result_name, table_name, empty_message)
        VALUES (520, N'resources', @rk, N'RESOURCE GOVERNANCE LIMITS (what the service objective allows)', N'#o_governance', N'sys.dm_user_db_resource_governance returned no rows.');

        BEGIN TRY
            SELECT
                rn = v.sort_order,
                setting = v.setting,
                value = v.value,
                meaning = v.meaning
            INTO #o_governance
            FROM
            (
                SELECT TOP (1)
                    g.*
                FROM sys.dm_user_db_resource_governance AS g
                WHERE g.database_id = @db_id
            ) AS g
            CROSS APPLY
            (
                VALUES
                    (1, N'service_objective', CONVERT(nvarchar(200), @service_objective) COLLATE DATABASE_DEFAULT, N'Service objective currently applied.'),
                    (2, N'edition', CONVERT(nvarchar(200), @edition), N'Service tier.'),
                    (23, N'internal_slo_name', CONVERT(nvarchar(200), g.slo_name), N'Internal service-level objective name (useful for support cases).'),
                    (3, N'updateability', CONVERT(nvarchar(200), DATABASEPROPERTYEX(@db_name, 'Updateability')), N'READ_ONLY means you are connected to a read-scale-out or named replica.'),
                    (4, N'replica_role',
                        CASE g.replica_role
                            WHEN 0 THEN N'Primary'
                            WHEN 1 THEN N'High-availability secondary'
                            WHEN 2 THEN N'Geo-replication forwarder'
                            WHEN 3 THEN N'Named replica'
                            ELSE CONVERT(nvarchar(200), g.replica_role)
                        END,
                        N'Role of the replica this session is connected to.'),
                    (5, N'cpu_limit_vcores', CONVERT(nvarchar(200), g.cpu_limit), N'vCores available to the user workload.'),
                    (6, N'max_dop', CONVERT(nvarchar(200), g.max_dop), N'Parallelism cap from governance (0 = not capped).'),
                    (7, N'max_workers', CONVERT(nvarchar(200), g.primary_group_max_workers), N'Concurrent worker limit for user requests. Reaching it raises error 10928.'),
                    (8, N'max_sessions', CONVERT(nvarchar(200), g.max_sessions), N'Concurrent session limit. Reaching it raises error 10928.'),
                    (9, N'max_log_rate_mb_per_s', CONVERT(nvarchar(200), CONVERT(decimal(18, 2), g.primary_max_log_rate / 1048576.0)), N'Log generation limit. Exceeding it causes LOG_RATE_GOVERNOR waits.'),
                    (10, N'max_data_iops', CONVERT(nvarchar(200), g.primary_group_max_io), N'Data IOPS limit for the user workload group.'),
                    (11, N'pool_max_iops', CONVERT(nvarchar(200), g.pool_max_io), N'Data IOPS limit for the resource pool (elastic pools share it).'),
                    (12, N'max_size_mb',
                        CASE
                            WHEN CONVERT(bigint, DATABASEPROPERTYEX(@db_name, 'MaxSizeInBytes')) > 0
                            THEN CONVERT(nvarchar(200), CONVERT(bigint, DATABASEPROPERTYEX(@db_name, 'MaxSizeInBytes')) / 1048576)
                            ELSE N'not capped (Hyperscale) / unknown'
                        END,
                        N'Configured maximum data size.'),
                    (13, N'log_size_mb', CONVERT(nvarchar(200), g.log_size_in_mb), N'Transaction log size limit.'),
                    (14, N'max_transaction_log_mb',
                        CASE
                            WHEN g.max_transaction_size > 0
                            THEN CONVERT(nvarchar(200), CONVERT(decimal(18, 2), g.max_transaction_size / 1024.0))
                            ELSE N'not capped'
                        END,
                        N'Log space a single transaction may use before error 40552.'),
                    (15, N'instance_cpu_cap_percent', CONVERT(nvarchar(200), g.instance_cap_cpu), N'CPU cap of the SQL instance hosting the database.'),
                    (16, N'instance_max_workers', CONVERT(nvarchar(200), g.instance_max_worker_threads), N'Worker threads available to the whole SQL instance.'),
                    (17, N'instance_max_log_rate_mb_per_s', CONVERT(nvarchar(200), CONVERT(decimal(18, 2), g.instance_max_log_rate / 1048576.0)), N'Log generation limit of the whole SQL instance.'),
                    (18, N'checkpoint_rate_mbps', CONVERT(nvarchar(200), g.checkpoint_rate_mbps), N'Checkpoint IO throughput limit.'),
                    (19, N'local_storage_quota_mb', CONVERT(nvarchar(200), g.user_data_directory_space_quota_mb), N'Local SSD space quota (tempdb and, outside Hyperscale, data files on local storage).'),
                    (20, N'local_storage_used_mb', CONVERT(nvarchar(200), g.user_data_directory_space_usage_mb), N'Local SSD space in use.'),
                    (21, N'rbpex_size_gb', CONVERT(nvarchar(200), g.bufferpool_extension_size_gb), N'Hyperscale resilient buffer pool extension (local SSD cache) size.'),
                    (22, N'governance_updated_utc', CONVERT(nvarchar(200), g.last_updated_date_utc, 120), N'When these limits were last applied (scale operations change them).')
            ) AS v (sort_order, setting, value, meaning);
        END TRY
        BEGIN CATCH
            UPDATE #emit SET error_message = LEFT(ERROR_MESSAGE(), 4000) WHERE result_key = @rk;
        END CATCH;

        UPDATE #emit SET duration_ms = DATEDIFF_BIG(MILLISECOND, @t0, SYSDATETIME()) WHERE result_key = @rk;

        SELECT
            @rk = N'schedulers',
            @t0 = SYSDATETIME();

        INSERT #emit (section_order, section_key, result_key, result_name, table_name, empty_message)
        VALUES (530, N'resources', @rk, N'SCHEDULERS AND WORKERS (instance level)', N'#o_schedulers', NULL);

        BEGIN TRY
            SELECT
                rn = 1,
                online_schedulers = COUNT_BIG(*),
                current_tasks = SUM(CONVERT(bigint, sch.current_tasks_count)),
                runnable_tasks = SUM(CONVERT(bigint, sch.runnable_tasks_count)),
                avg_runnable_per_scheduler = CONVERT(decimal(9, 2), AVG(1.0 * sch.runnable_tasks_count)),
                max_runnable_on_one_scheduler = MAX(sch.runnable_tasks_count),
                work_queue = SUM(CONVERT(bigint, sch.work_queue_count)),
                current_workers = SUM(CONVERT(bigint, sch.current_workers_count)),
                active_workers = SUM(CONVERT(bigint, sch.active_workers_count)),
                instance_max_workers = @instance_max_workers,
                workers_pct_of_instance_max = CONVERT(decimal(9, 2), 100.0 * SUM(CONVERT(bigint, sch.current_workers_count)) / NULLIF(@instance_max_workers, 0)),
                pending_disk_io = SUM(CONVERT(bigint, sch.pending_disk_io_count)),
                failed_to_create_worker = SUM(CASE WHEN sch.failed_to_create_worker = 1 THEN 1 ELSE 0 END),
                interpretation =
                    CASE
                        WHEN SUM(CONVERT(bigint, sch.work_queue_count)) > 0
                        THEN N'Tasks are queued waiting for a worker thread (THREADPOOL). Look for blocking or a pile-up of parallel queries.'
                        WHEN AVG(1.0 * sch.runnable_tasks_count) >= 1
                        THEN N'Tasks are waiting for CPU (runnable queue). CPU pressure: check resource_stats and the top CPU queries.'
                        WHEN SUM(CASE WHEN sch.failed_to_create_worker = 1 THEN 1 ELSE 0 END) > 0
                        THEN N'Worker creation failed on some schedulers (memory pressure or worker limit).'
                        ELSE N'No scheduler pressure.'
                    END
            INTO #o_schedulers
            FROM sys.dm_os_schedulers AS sch
            WHERE sch.status = N'VISIBLE ONLINE';
        END TRY
        BEGIN CATCH
            UPDATE #emit SET error_message = LEFT(ERROR_MESSAGE(), 4000) WHERE result_key = @rk;
        END CATCH;

        UPDATE #emit SET duration_ms = DATEDIFF_BIG(MILLISECOND, @t0, SYSDATETIME()) WHERE result_key = @rk;

        SELECT
            @rk = N'workload_group',
            @t0 = SYSDATETIME();

        INSERT #emit (section_order, section_key, result_key, result_name, table_name, empty_message)
        VALUES (540, N'resources', @rk, N'USER WORKLOAD GROUP (live and since statistics_since)', N'#o_workload_group', N'The user workload group for this database is not visible.');

        BEGIN TRY
            SELECT
                rn = ROW_NUMBER() OVER (ORDER BY wg.group_id),
                group_name = wg.name,
                active_requests = wg.active_request_count,
                queued_requests = wg.queued_request_count,
                blocked_tasks = wg.blocked_task_count,
                active_workers = wg.active_worker_count,
                peak_active_workers = wg.peak_active_worker_count,
                max_workers = wg.max_workers,
                workers_pct = CONVERT(decimal(9, 2), 100.0 * wg.active_worker_count / NULLIF(wg.max_workers, 0)),
                open_sessions = wg.open_session_count,
                peak_open_sessions = wg.peak_open_session_count,
                max_sessions = wg.max_sessions,
                sessions_pct = CONVERT(decimal(9, 2), 100.0 * wg.open_session_count / NULLIF(wg.max_sessions, 0)),
                effective_max_dop = wg.effective_max_dop,
                max_memory_grant_pct = wg.request_max_memory_grant_percent_numeric,
                tempdb_data_mb = CONVERT(decimal(18, 2), wg.tempdb_data_space_kb / 1024.0),
                peak_tempdb_data_mb = CONVERT(decimal(18, 2), wg.peak_tempdb_data_space_kb / 1024.0),
                reads_throttled = wg.reads_throttled_total,
                read_stall_queued_ms = wg.read_stall_queued_ms,
                write_stall_queued_ms = wg.write_stall_queued_ms,
                log_rate_waits = wg.log_waits_for_allotment_total,
                log_rate_wait_ms = wg.log_time_waited_for_allotment_total_ms,
                total_requests = wg.total_request_count,
                total_queued_requests = wg.total_queued_request_count,
                total_lock_waits = wg.total_lock_wait_count,
                total_lock_wait_ms = wg.total_lock_wait_time_ms,
                total_reduced_memory_grants = wg.total_reduced_memgrant_count,
                total_cpu_ms = wg.total_cpu_usage_ms,
                cpu_limit_violations = wg.total_cpu_limit_violation_count,
                statistics_since = wg.statistics_start_time
            INTO #o_workload_group
            FROM sys.dm_resource_governor_workload_groups AS wg
            WHERE wg.group_id = @primary_group_id
            OR
            (
                @primary_group_id IS NULL
                AND wg.name = N'UserPrimaryGroup.DBId' + CONVERT(nvarchar(10), @db_id)
            );
        END TRY
        BEGIN CATCH
            UPDATE #emit SET error_message = LEFT(ERROR_MESSAGE(), 4000) WHERE result_key = @rk;
        END CATCH;

        UPDATE #emit SET duration_ms = DATEDIFF_BIG(MILLISECOND, @t0, SYSDATETIME()) WHERE result_key = @rk;

        SELECT
            @rk = N'perf_counters',
            @t0 = SYSDATETIME();

        INSERT #emit (section_order, section_key, result_key, result_name, table_name, empty_message)
        VALUES
        (
            550, N'resources', @rk,
            CASE
                WHEN @is_sampled = 1
                THEN N'PERFORMANCE COUNTERS (rates sampled over ' + CONVERT(nvarchar(20), @sample_s) + N' s)'
                ELSE N'PERFORMANCE COUNTERS (rates averaged since instance start; use @sample_seconds for live rates)'
            END,
            N'#o_perf_counters',
            N'sys.dm_os_performance_counters returned no rows.'
        );

        BEGIN TRY
            SELECT
                rn = ROW_NUMBER() OVER (ORDER BY CASE WHEN p2.object_name = N'Databases' THEN 0 ELSE 1 END, p2.object_name, p2.counter_name, p2.instance_name),
                counter_name = p2.counter_name,
                object_name = p2.object_name,
                instance_name = CASE WHEN p2.instance_name = @physical_db_name THEN @db_name ELSE p2.instance_name END,
                scope = CASE WHEN p2.object_name = N'Databases' THEN N'database' ELSE N'instance' END,
                value =
                    CONVERT
                    (
                        decimal(28, 2),
                        CASE
                            WHEN p2.cntr_type = 65792
                            THEN p2.cntr_value
                            WHEN p1.cntr_value IS NOT NULL AND @sample_s > 0
                            THEN (p2.cntr_value - p1.cntr_value) / @sample_s
                            ELSE p2.cntr_value / NULLIF(CONVERT(decimal(19, 3), DATEDIFF_BIG(SECOND, @instance_start, @now)), 0)
                        END
                    ),
                value_type =
                    CASE
                        WHEN p2.cntr_type = 65792 THEN N'current value'
                        WHEN p1.cntr_value IS NOT NULL AND @sample_s > 0 THEN N'per second, sampled'
                        ELSE N'per second, average since instance start'
                    END,
                raw_value = p2.cntr_value
            INTO #o_perf_counters
            FROM #perf_snap AS p2
            LEFT JOIN #perf_snap AS p1
              ON  p1.sample_no = 1
              AND p1.object_name = p2.object_name
              AND p1.counter_name = p2.counter_name
              AND ISNULL(p1.instance_name, N'') = ISNULL(p2.instance_name, N'')
            WHERE p2.sample_no = 2;
        END TRY
        BEGIN CATCH
            UPDATE #emit SET error_message = LEFT(ERROR_MESSAGE(), 4000) WHERE result_key = @rk;
        END CATCH;

        UPDATE #emit SET duration_ms = DATEDIFF_BIG(MILLISECOND, @t0, SYSDATETIME()) WHERE result_key = @rk;
    END;

    /* ============================================================================================
       Shared lookups and working tables for the remaining sections
       ============================================================================================ */
    DECLARE @user_pool_id int;

    BEGIN TRY
        SELECT TOP (1)
            @user_pool_id = wg.pool_id
        FROM sys.dm_resource_governor_workload_groups AS wg
        WHERE wg.group_id = @primary_group_id
        OR    wg.name = N'UserPrimaryGroup.DBId' + CONVERT(nvarchar(10), @db_id)
        ORDER BY
            CASE WHEN wg.group_id = @primary_group_id THEN 0 ELSE 1 END;
    END TRY
    BEGIN CATCH
        INSERT #messages (msg_type, section, message)
        VALUES ('INFO', N'setup', LEFT(N'User resource pool lookup: ' + ERROR_MESSAGE(), 4000));
    END CATCH;

    CREATE TABLE #mem_metrics
    (
        sort_order int NOT NULL,
        metric nvarchar(60) COLLATE DATABASE_DEFAULT NOT NULL,
        value decimal(28, 2) NULL,
        unit nvarchar(20) COLLATE DATABASE_DEFAULT NULL,
        meaning nvarchar(400) COLLATE DATABASE_DEFAULT NULL
    );

    CREATE TABLE #pool_names
    (
        pool_id int NOT NULL PRIMARY KEY,
        pool_name nvarchar(128) COLLATE DATABASE_DEFAULT NULL
    );

    CREATE TABLE #tempdb_space
    (
        file_type nvarchar(10) COLLATE DATABASE_DEFAULT NOT NULL,
        files bigint NULL,
        size_mb decimal(18, 2) NULL,
        max_size_mb decimal(18, 2) NULL,
        used_mb decimal(18, 2) NULL,
        user_objects_mb decimal(18, 2) NULL,
        internal_objects_mb decimal(18, 2) NULL,
        version_store_mb decimal(18, 2) NULL,
        free_mb decimal(18, 2) NULL
    );

    CREATE TABLE #replicas
    (
        sort_group int NOT NULL,
        source nvarchar(60) COLLATE DATABASE_DEFAULT NOT NULL,
        replica nvarchar(300) COLLATE DATABASE_DEFAULT NULL,
        role nvarchar(60) COLLATE DATABASE_DEFAULT NULL,
        state nvarchar(200) COLLATE DATABASE_DEFAULT NULL,
        health nvarchar(60) COLLATE DATABASE_DEFAULT NULL,
        is_suspended bit NULL,
        suspend_reason nvarchar(60) COLLATE DATABASE_DEFAULT NULL,
        lag_seconds bigint NULL,
        log_send_queue_kb bigint NULL,
        log_send_rate_kb_s bigint NULL,
        redo_queue_kb bigint NULL,
        redo_rate_kb_s bigint NULL,
        last_commit_utc datetime2(3) NULL,
        last_replication_utc datetime2(3) NULL,
        secondary_allow_connections nvarchar(60) COLLATE DATABASE_DEFAULT NULL
    );

    CREATE TABLE #forcing
    (
        kind nvarchar(20) COLLATE DATABASE_DEFAULT NOT NULL,
        query_id bigint NOT NULL,
        plan_id bigint NULL,
        forcing_type nvarchar(60) COLLATE DATABASE_DEFAULT NULL,
        failure_count bigint NULL,
        last_failure_reason nvarchar(128) COLLATE DATABASE_DEFAULT NULL,
        last_execution datetimeoffset(7) NULL,
        hint_text nvarchar(max) COLLATE DATABASE_DEFAULT NULL
    );

    CREATE TABLE #plan_db
    (
        plan_handle varbinary(64) NOT NULL PRIMARY KEY
    );

    /* ============================================================================================
       600 memory_overview, 610 memory_grants, 620 resource_semaphores, 630 memory_clerks,
       640 memory_health
       ============================================================================================ */
    IF @do_memory = 1
    BEGIN
        BEGIN TRY
            INSERT #pool_names (pool_id, pool_name)
            SELECT
                rp.pool_id,
                MAX(rp.name)
            FROM sys.dm_resource_governor_resource_pools AS rp
            GROUP BY
                rp.pool_id;
        END TRY
        BEGIN CATCH
            INSERT #messages (msg_type, section, message)
            VALUES ('INFO', N'memory', LEFT(N'Resource pool names: ' + ERROR_MESSAGE(), 4000));
        END CATCH;

        SELECT
            @rk = N'memory_overview',
            @t0 = SYSDATETIME();

        INSERT #emit (section_order, section_key, result_key, result_name, table_name, empty_message)
        VALUES (600, N'memory', @rk, N'MEMORY OVERVIEW (instance memory, main caches and the user pool grant semaphores)', N'#o_memory_overview', N'No memory metrics are visible.');

        BEGIN TRY
            INSERT #mem_metrics (sort_order, metric, value, unit, meaning)
            SELECT
                v.sort_order,
                v.metric,
                v.value,
                N'MB',
                v.meaning
            FROM sys.dm_os_sys_info AS i
            CROSS APPLY
            (
                VALUES
                    (1, N'sql_committed_memory', CONVERT(decimal(28, 2), i.committed_kb / 1024.0), N'Memory committed by the SQL instance hosting this database. Shared with the other databases on the instance or elastic pool.'),
                    (2, N'sql_target_memory', CONVERT(decimal(28, 2), i.committed_target_kb / 1024.0), N'Memory the SQL instance may commit. Committed far below target is normal shortly after a restart, failover or scale operation.')
            ) AS v (sort_order, metric, value, meaning);
        END TRY
        BEGIN CATCH
            INSERT #messages (msg_type, section, message)
            VALUES ('INFO', N'memory', LEFT(N'sys.dm_os_sys_info: ' + ERROR_MESSAGE(), 4000));
        END CATCH;

        BEGIN TRY
            INSERT #mem_metrics (sort_order, metric, value, unit, meaning)
            SELECT
                v.sort_order,
                v.metric,
                CONVERT(decimal(28, 2), v.value_kb / 1024.0),
                N'MB',
                v.meaning
            FROM
            (
                SELECT
                    total_kb = SUM(x.memory_kb),
                    buffer_pool_kb = SUM(CASE WHEN x.type = N'MEMORYCLERK_SQLBUFFERPOOL' THEN x.memory_kb ELSE 0 END),
                    plan_cache_kb = SUM(CASE WHEN x.type IN (N'CACHESTORE_SQLCP', N'CACHESTORE_OBJCP', N'CACHESTORE_PHDR', N'CACHESTORE_XPROC') THEN x.memory_kb ELSE 0 END),
                    adhoc_kb = SUM(CASE WHEN x.type = N'CACHESTORE_SQLCP' THEN x.memory_kb ELSE 0 END),
                    grants_kb = SUM(CASE WHEN x.type = N'MEMORYCLERK_SQLQERESERVATIONS' THEN x.memory_kb ELSE 0 END),
                    lock_kb = SUM(CASE WHEN x.type = N'OBJECTSTORE_LOCK_MANAGER' THEN x.memory_kb ELSE 0 END),
                    columnstore_kb = SUM(CASE WHEN x.type = N'CACHESTORE_COLUMNSTOREOBJECTPOOL' THEN x.memory_kb ELSE 0 END),
                    xtp_kb = SUM(CASE WHEN x.type = N'MEMORYCLERK_XTP' THEN x.memory_kb ELSE 0 END),
                    query_store_kb = SUM(CASE WHEN x.type LIKE N'MEMORYCLERK[_]QUERYDISKSTORE%' THEN x.memory_kb ELSE 0 END),
                    token_kb = SUM(CASE WHEN x.type = N'USERSTORE_TOKENPERM' THEN x.memory_kb ELSE 0 END)
                FROM
                (
                    SELECT
                        mc.type,
                        memory_kb = mc.pages_kb + mc.virtual_memory_committed_kb + mc.awe_allocated_kb
                    FROM sys.dm_os_memory_clerks AS mc
                ) AS x
            ) AS c
            CROSS APPLY
            (
                VALUES
                    (3, N'memory_clerks_total', c.total_kb, N'Memory tracked by all memory clerks on the instance.'),
                    (4, N'buffer_pool', c.buffer_pool_kb, N'Cached data and index pages. Normally the largest consumer, by design.'),
                    (5, N'plan_cache', c.plan_cache_kb, N'Compiled plans: ad hoc and prepared (SQLCP), modules (OBJCP) and bound trees (PHDR).'),
                    (6, N'plan_cache_adhoc_prepared', c.adhoc_kb, N'Ad hoc and prepared plans. A large share suggests unparameterized queries: parameterize, or consider forced parameterization.'),
                    (7, N'query_grants_reserved', c.grants_kb, N'Memory reserved for query memory grants (MEMORYCLERK_SQLQERESERVATIONS).'),
                    (8, N'lock_manager', c.lock_kb, N'Lock structures. Large values mean many locks are held: long transactions or large modifications without lock escalation.'),
                    (9, N'columnstore_object_pool', c.columnstore_kb, N'Columnstore segments cached in memory.'),
                    (10, N'in_memory_oltp', c.xtp_kb, N'Memory-optimized tables and the In-Memory OLTP engine (MEMORYCLERK_XTP).'),
                    (11, N'query_store', c.query_store_kb, N'Query Store in-memory structures.'),
                    (12, N'security_token_cache', c.token_kb, N'Security token and permission cache (USERSTORE_TOKENPERM). Several GB slows logins and permission checks.')
            ) AS v (sort_order, metric, value_kb, meaning);
        END TRY
        BEGIN CATCH
            INSERT #messages (msg_type, section, message)
            VALUES ('INFO', N'memory', LEFT(N'sys.dm_os_memory_clerks: ' + ERROR_MESSAGE(), 4000));
        END CATCH;

        BEGIN TRY
            INSERT #mem_metrics (sort_order, metric, value, unit, meaning)
            SELECT
                v.sort_order,
                v.metric,
                v.value,
                v.unit,
                v.meaning
            FROM
            (
                SELECT
                    target_kb = SUM(CONVERT(bigint, rs.target_memory_kb)),
                    granted_kb = SUM(CONVERT(bigint, rs.granted_memory_kb)),
                    used_kb = SUM(CONVERT(bigint, rs.used_memory_kb)),
                    grantees = SUM(CONVERT(bigint, rs.grantee_count)),
                    waiters = SUM(CONVERT(bigint, rs.waiter_count)),
                    timeouts = SUM(CONVERT(bigint, rs.timeout_error_count)),
                    forced = SUM(CONVERT(bigint, rs.forced_grant_count))
                FROM sys.dm_exec_query_resource_semaphores AS rs
                WHERE rs.pool_id = @user_pool_id
            ) AS s
            CROSS APPLY
            (
                VALUES
                    (13, N'grant_memory_target', CONVERT(decimal(28, 2), s.target_kb / 1024.0), N'MB', N'Query memory the user pool may grant right now.'),
                    (14, N'grant_memory_granted', CONVERT(decimal(28, 2), s.granted_kb / 1024.0), N'MB', N'Query memory granted to running queries.'),
                    (15, N'grant_memory_used', CONVERT(decimal(28, 2), s.used_kb / 1024.0), N'MB', N'Granted memory actually in use. Far below granted means over-estimated grants (stale statistics, wide columns).'),
                    (16, N'grants_running', CONVERT(decimal(28, 2), s.grantees), N'count', N'Queries holding a memory grant.'),
                    (17, N'grants_waiting', CONVERT(decimal(28, 2), s.waiters), N'count', N'Queries waiting for a memory grant (RESOURCE_SEMAPHORE). Above 0 means grant pressure: see memory_grants.'),
                    (18, N'grant_timeouts', CONVERT(decimal(28, 2), s.timeouts), N'count', N'Grant requests that timed out (error 8645) since the semaphore was created.'),
                    (19, N'grants_forced', CONVERT(decimal(28, 2), s.forced), N'count', N'Grants that received less memory than requested since the semaphore was created: those queries probably spilled to tempdb.')
            ) AS v (sort_order, metric, value, unit, meaning)
            WHERE @user_pool_id IS NOT NULL;
        END TRY
        BEGIN CATCH
            INSERT #messages (msg_type, section, message)
            VALUES ('INFO', N'memory', LEFT(N'sys.dm_exec_query_resource_semaphores: ' + ERROR_MESSAGE(), 4000));
        END CATCH;

        BEGIN TRY
            INSERT #mem_metrics (sort_order, metric, value, unit, meaning)
            SELECT TOP (1)
                20,
                N'page_life_expectancy',
                CONVERT(decimal(28, 2), p.cntr_value),
                N'seconds',
                N'Expected seconds a page stays in the buffer pool. Compare with your own baseline: sudden drops mean large scans are flushing the cache.'
            FROM #perf_snap AS p
            WHERE p.sample_no = 2
            AND   p.object_name = N'Buffer Manager'
            AND   p.counter_name = N'Page life expectancy';

            INSERT #mem_metrics (sort_order, metric, value, unit, meaning)
            SELECT TOP (1)
                21,
                N'memory_usage_percent',
                CONVERT(decimal(28, 2), s.avg_memory_usage_percent),
                N'percent',
                N'Latest memory use versus the service objective limit. High values are normal: caches use free memory by design.'
            FROM sys.dm_db_resource_stats AS s
            ORDER BY
                s.end_time DESC;
        END TRY
        BEGIN CATCH
            INSERT #messages (msg_type, section, message)
            VALUES ('INFO', N'memory', LEFT(N'Page life expectancy / memory percent: ' + ERROR_MESSAGE(), 4000));
        END CATCH;

        BEGIN TRY
            SELECT
                rn = ROW_NUMBER() OVER (ORDER BY m.sort_order),
                metric = m.metric,
                value = m.value,
                unit = m.unit,
                meaning = m.meaning
            INTO #o_memory_overview
            FROM #mem_metrics AS m;
        END TRY
        BEGIN CATCH
            UPDATE #emit SET error_message = LEFT(ERROR_MESSAGE(), 4000) WHERE result_key = @rk;
        END CATCH;

        UPDATE #emit SET duration_ms = DATEDIFF_BIG(MILLISECOND, @t0, SYSDATETIME()) WHERE result_key = @rk;

        SELECT
            @rk = N'memory_grants',
            @t0 = SYSDATETIME();

        INSERT #emit (section_order, section_key, result_key, result_name, table_name, empty_message)
        VALUES (610, N'memory', @rk, N'QUERY MEMORY GRANTS (waiting first, then largest granted)', N'#o_memory_grants', N'No query memory grants in this database right now.');

        BEGIN TRY
            SELECT
                rn = ROW_NUMBER() OVER (ORDER BY q.sort_group, q.wait_sort, q.granted_memory_kb DESC, q.requested_memory_kb DESC, q.session_id),
                session_id = q.session_id,
                request_id = q.request_id,
                grant_status = CASE WHEN q.grant_time IS NULL THEN N'WAITING' ELSE N'GRANTED' END,
                grant_wait_ms =
                    CASE
                        WHEN q.grant_time IS NULL
                        THEN ISNULL(q.wait_time_ms, DATEDIFF_BIG(MILLISECOND, q.request_time, @now))
                        ELSE DATEDIFF_BIG(MILLISECOND, q.request_time, q.grant_time)
                    END,
                requested_mb = CONVERT(decimal(18, 2), q.requested_memory_kb / 1024.0),
                granted_mb = CONVERT(decimal(18, 2), q.granted_memory_kb / 1024.0),
                used_mb = CONVERT(decimal(18, 2), q.used_memory_kb / 1024.0),
                max_used_mb = CONVERT(decimal(18, 2), q.max_used_memory_kb / 1024.0),
                ideal_mb = CONVERT(decimal(18, 2), q.ideal_memory_kb / 1024.0),
                required_mb = CONVERT(decimal(18, 2), q.required_memory_kb / 1024.0),
                unused_grant_pct =
                    CASE
                        WHEN q.granted_memory_kb > 0
                        THEN CONVERT(decimal(9, 1), 100.0 * (q.granted_memory_kb - ISNULL(q.max_used_memory_kb, 0)) / q.granted_memory_kb)
                    END,
                dop = q.dop,
                query_cost = CONVERT(decimal(18, 2), q.query_cost),
                timeout_sec = q.timeout_sec,
                semaphore =
                    CASE q.resource_semaphore_id
                        WHEN 0 THEN N'regular'
                        WHEN 1 THEN N'small query'
                        ELSE CONVERT(nvarchar(10), q.resource_semaphore_id)
                    END,
                pool_name = pn.pool_name,
                queue_id = q.queue_id,
                wait_order = q.wait_order,
                is_next_candidate = q.is_next_candidate,
                reserved_workers = q.reserved_worker_count,
                used_workers = q.used_worker_count,
                request_status = r.status,
                wait_type = r.wait_type,
                elapsed_ms = r.total_elapsed_time,
                login_name = s.login_name,
                host_name = s.host_name,
                program_name = s.program_name,
                query_hash = CONVERT(varchar(130), r.query_hash, 1),
                plan_handle = CONVERT(varchar(130), q.plan_handle, 1),
                statement_text =
                    CASE
                        WHEN r.sql_handle = q.sql_handle
                        THEN
                            SUBSTRING
                            (
                                st.text,
                                ISNULL(r.statement_start_offset, 0) / 2 + 1,
                                CASE
                                    WHEN ISNULL(r.statement_end_offset, -1) = -1 OR r.statement_end_offset < ISNULL(r.statement_start_offset, 0)
                                    THEN 2147483647
                                    ELSE (r.statement_end_offset - ISNULL(r.statement_start_offset, 0)) / 2 + 1
                                END
                            )
                        ELSE st.text
                    END
            INTO #o_memory_grants
            FROM
            (
                SELECT TOP (@top_n)
                    g.*,
                    sort_group = CASE WHEN g.grant_time IS NULL THEN 0 ELSE 1 END,
                    wait_sort = CASE WHEN g.grant_time IS NULL THEN ISNULL(g.wait_order, 2147483647) ELSE 0 END
                FROM #grants AS g
                LEFT JOIN #req AS rr
                  ON  rr.session_id = g.session_id
                  AND rr.request_id = g.request_id
                LEFT JOIN #sess AS ss
                  ON ss.session_id = g.session_id
                WHERE ISNULL(rr.database_id, ss.database_id) = @db_id
                AND   ISNULL(ss.is_user_process, 1) = 1
                ORDER BY
                    sort_group,
                    wait_sort,
                    g.granted_memory_kb DESC,
                    g.requested_memory_kb DESC
            ) AS q
            LEFT JOIN #req AS r
              ON  r.session_id = q.session_id
              AND r.request_id = q.request_id
            LEFT JOIN #sess AS s
              ON s.session_id = q.session_id
            LEFT JOIN #pool_names AS pn
              ON pn.pool_id = q.pool_id
            OUTER APPLY sys.dm_exec_sql_text(q.sql_handle) AS st;
        END TRY
        BEGIN CATCH
            UPDATE #emit SET error_message = LEFT(ERROR_MESSAGE(), 4000) WHERE result_key = @rk;
        END CATCH;

        UPDATE #emit SET duration_ms = DATEDIFF_BIG(MILLISECOND, @t0, SYSDATETIME()) WHERE result_key = @rk;

        SELECT
            @rk = N'resource_semaphores',
            @t0 = SYSDATETIME();

        INSERT #emit (section_order, section_key, result_key, result_name, table_name, empty_message)
        VALUES (620, N'memory', @rk, N'RESOURCE SEMAPHORES (memory grant gates for the user pool, plus any pool with waiters)', N'#o_resource_semaphores', N'No resource semaphores visible for the user pool.');

        BEGIN TRY
            SELECT
                rn = ROW_NUMBER() OVER (ORDER BY CASE WHEN rs.pool_id = @user_pool_id THEN 0 ELSE 1 END, rs.pool_id, rs.resource_semaphore_id),
                pool_name = pn.pool_name,
                is_user_pool = CONVERT(bit, CASE WHEN rs.pool_id = @user_pool_id THEN 1 ELSE 0 END),
                semaphore =
                    CASE rs.resource_semaphore_id
                        WHEN 0 THEN N'regular'
                        WHEN 1 THEN N'small query'
                        ELSE CONVERT(nvarchar(10), rs.resource_semaphore_id)
                    END,
                target_mb = CONVERT(decimal(18, 2), rs.target_memory_kb / 1024.0),
                max_target_mb = CONVERT(decimal(18, 2), rs.max_target_memory_kb / 1024.0),
                total_mb = CONVERT(decimal(18, 2), rs.total_memory_kb / 1024.0),
                available_mb = CONVERT(decimal(18, 2), rs.available_memory_kb / 1024.0),
                granted_mb = CONVERT(decimal(18, 2), rs.granted_memory_kb / 1024.0),
                used_mb = CONVERT(decimal(18, 2), rs.used_memory_kb / 1024.0),
                grantees = rs.grantee_count,
                waiters = rs.waiter_count,
                timeout_errors = rs.timeout_error_count,
                forced_grants = rs.forced_grant_count,
                interpretation =
                    CASE
                        WHEN rs.waiter_count > 0
                        THEN N'Queries are queued for memory grants (RESOURCE_SEMAPHORE waits). Check memory_grants for the largest grants; fix their estimates (statistics, indexes, narrower columns) or scale up.'
                        WHEN rs.total_memory_kb > 0 AND rs.available_memory_kb < rs.total_memory_kb * 0.10
                        THEN N'Less than 10% of grant memory is available: new large grants may soon have to wait.'
                        ELSE N'OK'
                    END
            INTO #o_resource_semaphores
            FROM sys.dm_exec_query_resource_semaphores AS rs
            LEFT JOIN #pool_names AS pn
              ON pn.pool_id = rs.pool_id
            WHERE rs.pool_id = @user_pool_id
            OR    rs.waiter_count > 0;
        END TRY
        BEGIN CATCH
            UPDATE #emit SET error_message = LEFT(ERROR_MESSAGE(), 4000) WHERE result_key = @rk;
        END CATCH;

        UPDATE #emit SET duration_ms = DATEDIFF_BIG(MILLISECOND, @t0, SYSDATETIME()) WHERE result_key = @rk;

        SELECT
            @rk = N'memory_clerks',
            @t0 = SYSDATETIME();

        INSERT #emit (section_order, section_key, result_key, result_name, table_name, empty_message)
        VALUES (630, N'memory', @rk, N'MEMORY CLERKS (largest memory consumers on the instance)', N'#o_memory_clerks', N'No memory clerks visible.');

        BEGIN TRY
            SELECT
                rn = ROW_NUMBER() OVER (ORDER BY c.memory_kb DESC, c.clerk_type),
                clerk_type = c.clerk_type,
                memory_mb = CONVERT(decimal(18, 2), c.memory_kb / 1024.0),
                pct_of_clerks = CONVERT(decimal(9, 1), 100.0 * c.memory_kb / NULLIF(c.total_kb, 0)),
                instances = c.instances,
                meaning =
                    CASE
                        WHEN c.clerk_type = N'MEMORYCLERK_SQLBUFFERPOOL' THEN N'Buffer pool: cached data and index pages. Normally the largest clerk.'
                        WHEN c.clerk_type = N'CACHESTORE_SQLCP' THEN N'Ad hoc and prepared plans. A large share points to unparameterized queries.'
                        WHEN c.clerk_type = N'CACHESTORE_OBJCP' THEN N'Plans for procedures, functions and triggers.'
                        WHEN c.clerk_type = N'CACHESTORE_PHDR' THEN N'Bound trees for views, constraints and defaults.'
                        WHEN c.clerk_type = N'CACHESTORE_COLUMNSTOREOBJECTPOOL' THEN N'Columnstore segments and dictionaries cached in memory.'
                        WHEN c.clerk_type = N'MEMORYCLERK_SQLQERESERVATIONS' THEN N'Query memory grants (sorts, hashes, batch mode).'
                        WHEN c.clerk_type = N'MEMORYCLERK_XTP' THEN N'In-Memory OLTP: memory-optimized tables and table types.'
                        WHEN c.clerk_type IN (N'MEMORYCLERK_SOSMEMMANAGER', N'MEMORYCLERK_SOSNODE') THEN N'SQLOS internal memory: threads, scheduling and per-node structures.'
                        WHEN c.clerk_type = N'MEMORYCLERK_RBPEX' THEN N'Resilient buffer pool extension (local SSD data cache) bookkeeping.'
                        WHEN c.clerk_type = N'MEMORYCLERK_RBIO' THEN N'Hyperscale remote block IO to page servers and the log service.'
                        WHEN c.clerk_type LIKE N'MEMORYCLERK[_]XE%' THEN N'Extended Events session buffers.'
                        WHEN c.clerk_type = N'OBJECTSTORE_LOCK_MANAGER' THEN N'Lock structures. Large values mean many locks held: long or large transactions.'
                        WHEN c.clerk_type = N'OBJECTSTORE_SERVICE_BROKER' THEN N'Service Broker objects.'
                        WHEN c.clerk_type = N'MEMORYCLERK_SQLLOGPOOL' THEN N'Log pool: cached log blocks used by replication and recovery.'
                        WHEN c.clerk_type = N'USERSTORE_SCHEMAMGR' THEN N'Schema metadata cache. Grows with many objects or heavy temp table churn.'
                        WHEN c.clerk_type = N'USERSTORE_DBMETADATA' THEN N'Database metadata cache.'
                        WHEN c.clerk_type = N'USERSTORE_TOKENPERM' THEN N'Security token and permission cache. Several GB slows logins and permission checks.'
                        WHEN c.clerk_type LIKE N'MEMORYCLERK[_]QUERYDISKSTORE%' THEN N'Query Store in-memory structures.'
                        WHEN c.clerk_type = N'MEMORYCLERK_SQLCLR' THEN N'SQL CLR, also used internally by some features.'
                        WHEN c.clerk_type = N'MEMORYCLERK_SQLSTORENG' THEN N'Storage engine internal structures.'
                        WHEN c.clerk_type = N'MEMORYCLERK_SQLOPTIMIZER' THEN N'Query optimizer working memory. High values mean many or very complex compilations.'
                        WHEN c.clerk_type = N'MEMORYCLERK_SQLQUERYEXEC' THEN N'Query execution structures (other than grants).'
                        WHEN c.clerk_type = N'MEMORYCLERK_QUERYPROFILE' THEN N'Lightweight query profiling (live query statistics, last actual plans).'
                        WHEN c.clerk_type = N'OBJECTSTORE_SNI_PACKET' THEN N'Network packet buffers.'
                        WHEN c.clerk_type = N'MEMORYCLERK_SQLGENERAL' THEN N'General engine allocations.'
                        WHEN c.clerk_type = N'MEMORYCLERK_FULLTEXT' THEN N'Full-text search.'
                    END
            INTO #o_memory_clerks
            FROM
            (
                SELECT TOP (@top_n)
                    clerk_type = mc.type COLLATE DATABASE_DEFAULT,
                    memory_kb = SUM(mc.pages_kb + mc.virtual_memory_committed_kb + mc.awe_allocated_kb),
                    total_kb = SUM(SUM(mc.pages_kb + mc.virtual_memory_committed_kb + mc.awe_allocated_kb)) OVER (),
                    instances = COUNT_BIG(*)
                FROM sys.dm_os_memory_clerks AS mc
                GROUP BY
                    mc.type
                ORDER BY
                    memory_kb DESC
            ) AS c;
        END TRY
        BEGIN CATCH
            UPDATE #emit SET error_message = LEFT(ERROR_MESSAGE(), 4000) WHERE result_key = @rk;
        END CATCH;

        UPDATE #emit SET duration_ms = DATEDIFF_BIG(MILLISECOND, @t0, SYSDATETIME()) WHERE result_key = @rk;

        SELECT
            @rk = N'memory_health',
            @t0 = SYSDATETIME();

        INSERT #emit (section_order, section_key, result_key, result_name, table_name, empty_message)
        VALUES (640, N'memory', @rk, N'MEMORY HEALTH HISTORY (latest snapshot, then the lookback window by severity)', N'#o_memory_health', N'sys.dm_os_memory_health_history returned no rows.');

        CREATE TABLE #o_memory_health
        (
            rn bigint NOT NULL,
            scope nvarchar(60) COLLATE DATABASE_DEFAULT NULL,
            severity nvarchar(60) COLLATE DATABASE_DEFAULT NULL,
            snapshots bigint NULL,
            first_snapshot datetime2(7) NULL,
            last_snapshot datetime2(7) NULL,
            min_allocation_potential_mb int NULL,
            min_reclaimable_cache_mb int NULL,
            max_out_of_memory_event_count int NULL,
            max_memgrant_timeout_count int NULL,
            max_memgrant_waiter_count int NULL,
            top_memory_clerks nvarchar(4000) COLLATE DATABASE_DEFAULT NULL,
            meaning nvarchar(400) COLLATE DATABASE_DEFAULT NULL
        );

        /* Dynamic SQL on purpose: Microsoft documents the three counter columns as unsupported, and a
           removed column referenced statically would abort the whole procedure instead of this result. */
        SET @sql = N'
INSERT #o_memory_health
(
    rn, scope, severity, snapshots, first_snapshot, last_snapshot, min_allocation_potential_mb,
    min_reclaimable_cache_mb, max_out_of_memory_event_count, max_memgrant_timeout_count,
    max_memgrant_waiter_count, top_memory_clerks, meaning
)
SELECT
    ROW_NUMBER() OVER (ORDER BY h.scope_order, h.severity_level DESC),
    h.scope,
    h.severity,
    h.snapshots,
    h.first_snapshot,
    h.last_snapshot,
    h.min_allocation_potential_mb,
    h.min_reclaimable_cache_mb,
    h.max_oom,
    h.max_timeouts,
    h.max_waiters,
    h.top_memory_clerks,
    CASE h.severity_level
        WHEN 1 THEN N''LOW: no memory health issue.''
        WHEN 2 THEN N''MEDIUM: some allocations may fail and caches may shrink. Brief flapping between LOW and MEDIUM is common.''
        WHEN 3 THEN N''HIGH: memory is likely insufficient. Expect error 701, grant timeouts and extra IO. Check top_memory_clerks and memory_grants.''
    END
FROM
(
    SELECT
        scope_order = 0,
        scope = CONVERT(nvarchar(60), N''latest snapshot''),
        severity_level = l.severity_level,
        severity = l.severity_level_desc COLLATE DATABASE_DEFAULT,
        snapshots = CONVERT(bigint, 1),
        first_snapshot = l.snapshot_time,
        last_snapshot = l.snapshot_time,
        min_allocation_potential_mb = l.allocation_potential_memory_mb,
        min_reclaimable_cache_mb = l.reclaimable_cache_memory_mb,
        max_oom = l.out_of_memory_event_count,
        max_timeouts = l.memgrant_timeout_count,
        max_waiters = l.memgrant_waiter_count,
        top_memory_clerks = l.top_memory_clerks COLLATE DATABASE_DEFAULT
    FROM
    (
        SELECT TOP (1)
            mh.snapshot_time,
            mh.severity_level,
            mh.severity_level_desc,
            mh.allocation_potential_memory_mb,
            mh.reclaimable_cache_memory_mb,
            mh.out_of_memory_event_count,
            mh.memgrant_timeout_count,
            mh.memgrant_waiter_count,
            mh.top_memory_clerks
        FROM sys.dm_os_memory_health_history AS mh
        ORDER BY
            mh.snapshot_time DESC
    ) AS l

    UNION ALL

    SELECT
        1,
        CONVERT(nvarchar(60), CONCAT(N''last '', @lookback_minutes, N'' minutes'')),
        w.severity_level,
        MAX(w.severity_level_desc) COLLATE DATABASE_DEFAULT,
        COUNT_BIG(*),
        MIN(w.snapshot_time),
        MAX(w.snapshot_time),
        MIN(w.allocation_potential_memory_mb),
        MIN(w.reclaimable_cache_memory_mb),
        MAX(w.out_of_memory_event_count),
        MAX(w.memgrant_timeout_count),
        MAX(w.memgrant_waiter_count),
        NULL
    FROM sys.dm_os_memory_health_history AS w
    WHERE w.snapshot_time >= @window_start
    GROUP BY
        w.severity_level
) AS h;';

        BEGIN TRY
            IF @debug = 1 PRINT @sql;

            EXEC sys.sp_executesql
                @sql,
                N'@window_start datetime, @lookback_minutes int',
                @window_start,
                @lookback_minutes;
        END TRY
        BEGIN CATCH
            UPDATE #emit SET error_message = LEFT(ERROR_MESSAGE(), 4000) WHERE result_key = @rk;
        END CATCH;

        UPDATE #emit SET duration_ms = DATEDIFF_BIG(MILLISECOND, @t0, SYSDATETIME()) WHERE result_key = @rk;
    END;

    /* ============================================================================================
       tempdb space (also feeds the summary): 700 tempdb_space, 710 tempdb_sessions
       ============================================================================================ */
    IF @do_tempdb = 1 OR @do_summary = 1
    BEGIN
        /* Dynamic SQL: the three-part tempdb names are resolved at run time, so a permission or
           availability problem becomes a message instead of aborting the procedure. */
        SET @sql = N'
INSERT #tempdb_space
(
    file_type, files, size_mb, max_size_mb, used_mb, user_objects_mb, internal_objects_mb, version_store_mb, free_mb
)
SELECT
    N''data'',
    COUNT_BIG(*),
    SUM(CONVERT(bigint, df.size)) * 8 / 1024.0,
    CASE
        WHEN MIN(df.max_size) = -1 THEN NULL
        ELSE SUM(CONVERT(bigint, CASE WHEN df.max_size = 0 THEN df.size ELSE df.max_size END)) * 8 / 1024.0
    END,
    SUM(fsu.total_page_count - fsu.unallocated_extent_page_count) * 8 / 1024.0,
    SUM(fsu.user_object_reserved_page_count) * 8 / 1024.0,
    SUM(fsu.internal_object_reserved_page_count) * 8 / 1024.0,
    SUM(fsu.version_store_reserved_page_count) * 8 / 1024.0,
    SUM(fsu.unallocated_extent_page_count) * 8 / 1024.0
FROM tempdb.sys.database_files AS df
LEFT JOIN tempdb.sys.dm_db_file_space_usage AS fsu
  ON  fsu.file_id = df.file_id
  AND fsu.database_id = 2
WHERE df.type = 0
HAVING COUNT_BIG(*) > 0;';

        BEGIN TRY
            IF @debug = 1 PRINT @sql;
            EXEC sys.sp_executesql @sql;
        END TRY
        BEGIN CATCH
            INSERT #messages (msg_type, section, message)
            VALUES ('INFO', N'tempdb', LEFT(N'tempdb data file space: ' + ERROR_MESSAGE(), 4000));
        END CATCH;

        SET @sql = N'
INSERT #tempdb_space (file_type, files, size_mb, max_size_mb, used_mb, free_mb)
SELECT
    N''log'',
    f.files,
    ISNULL(ls.total_log_size_in_bytes / 1048576.0, f.size_mb),
    f.max_size_mb,
    ls.used_log_space_in_bytes / 1048576.0,
    (ls.total_log_size_in_bytes - ls.used_log_space_in_bytes) / 1048576.0
FROM
(
    SELECT
        files = COUNT_BIG(*),
        size_mb = SUM(CONVERT(bigint, df.size)) * 8 / 1024.0,
        max_size_mb =
            CASE
                WHEN MIN(df.max_size) = -1 THEN NULL
                ELSE SUM(CONVERT(bigint, CASE WHEN df.max_size = 0 THEN df.size ELSE df.max_size END)) * 8 / 1024.0
            END
    FROM tempdb.sys.database_files AS df
    WHERE df.type = 1
    HAVING COUNT_BIG(*) > 0
) AS f
LEFT JOIN tempdb.sys.dm_db_log_space_usage AS ls
  ON ls.database_id = 2;';

        BEGIN TRY
            IF @debug = 1 PRINT @sql;
            EXEC sys.sp_executesql @sql;
        END TRY
        BEGIN CATCH
            INSERT #messages (msg_type, section, message)
            VALUES ('INFO', N'tempdb', LEFT(N'tempdb log space: ' + ERROR_MESSAGE(), 4000));
        END CATCH;
    END;

    IF @do_tempdb = 1
    BEGIN
        SELECT
            @rk = N'tempdb_space',
            @t0 = SYSDATETIME();

        INSERT #emit (section_order, section_key, result_key, result_name, table_name, empty_message)
        VALUES (700, N'tempdb', @rk, N'TEMPDB SPACE (data and log, with the main consumers)', N'#o_tempdb_space', N'tempdb space information is not available (see messages).');

        BEGIN TRY
            SELECT
                rn = ROW_NUMBER() OVER (ORDER BY CASE t.file_type WHEN N'data' THEN 0 ELSE 1 END),
                file_type = t.file_type,
                files = t.files,
                size_mb = CONVERT(decimal(18, 2), t.size_mb),
                max_size_mb = CONVERT(decimal(18, 2), t.max_size_mb),
                used_mb = CONVERT(decimal(18, 2), t.used_mb),
                used_pct_of_size = CONVERT(decimal(9, 1), 100.0 * t.used_mb / NULLIF(t.size_mb, 0)),
                used_pct_of_max = CONVERT(decimal(9, 1), 100.0 * t.used_mb / NULLIF(t.max_size_mb, 0)),
                free_mb = CONVERT(decimal(18, 2), t.free_mb),
                user_objects_mb = CONVERT(decimal(18, 2), t.user_objects_mb),
                internal_objects_mb = CONVERT(decimal(18, 2), t.internal_objects_mb),
                version_store_mb = CONVERT(decimal(18, 2), t.version_store_mb),
                interpretation =
                    CASE
                        WHEN t.file_type = N'log' AND t.used_mb >= 0.70 * ISNULL(t.max_size_mb, t.size_mb)
                        THEN N'tempdb log is filling: an open transaction that uses tempdb (large temp table load, sort or long batch) prevents truncation. See tempdb_sessions and open_transactions.'
                        WHEN t.file_type = N'log'
                        THEN N'OK'
                        WHEN t.used_mb >= 0.80 * t.max_size_mb
                        THEN N'tempdb data is nearly full for this service objective: queries will fail with error 1105 when it is. See tempdb_sessions.'
                        WHEN t.used_mb < 1024
                        THEN N'Low usage.'
                        WHEN ISNULL(t.version_store_mb, 0) >= ISNULL(t.internal_objects_mb, 0) AND ISNULL(t.version_store_mb, 0) >= ISNULL(t.user_objects_mb, 0)
                        THEN N'Version store is the largest consumer: a long-running transaction is keeping old row versions. See open_transactions.'
                        WHEN ISNULL(t.internal_objects_mb, 0) >= ISNULL(t.user_objects_mb, 0)
                        THEN N'Internal objects dominate (sorts, hashes, spools, spills): see tempdb_sessions and memory_grants for the queries.'
                        ELSE N'User objects dominate (temp tables, table variables): see tempdb_sessions for the sessions holding them.'
                    END
            INTO #o_tempdb_space
            FROM #tempdb_space AS t;
        END TRY
        BEGIN CATCH
            UPDATE #emit SET error_message = LEFT(ERROR_MESSAGE(), 4000) WHERE result_key = @rk;
        END CATCH;

        UPDATE #emit SET duration_ms = DATEDIFF_BIG(MILLISECOND, @t0, SYSDATETIME()) WHERE result_key = @rk;

        SELECT
            @rk = N'tempdb_sessions',
            @t0 = SYSDATETIME();

        INSERT #emit (section_order, section_key, result_key, result_name, table_name, empty_message)
        VALUES (710, N'tempdb', @rk, N'TEMPDB BY SESSION (largest tempdb consumers in this database)', N'#o_tempdb_sessions', N'No session in this database is using tempdb right now.');

        BEGIN TRY
            SELECT
                rn = ROW_NUMBER() OVER (ORDER BY x.total_pages DESC, x.session_id),
                session_id = x.session_id,
                tempdb_mb = CONVERT(decimal(18, 2), x.total_pages * 8 / 1024.0),
                user_objects_mb = CONVERT(decimal(18, 2), (x.session_user_pages + x.task_user_pages) * 8 / 1024.0),
                internal_objects_mb = CONVERT(decimal(18, 2), (x.session_internal_pages + x.task_internal_pages) * 8 / 1024.0),
                running_tasks_mb = CONVERT(decimal(18, 2), (x.task_user_pages + x.task_internal_pages) * 8 / 1024.0),
                session_status = s.status,
                command = r.command,
                wait_type = r.wait_type,
                elapsed_ms = r.total_elapsed_time,
                open_transactions = s.open_transaction_count,
                login_name = s.login_name,
                host_name = s.host_name,
                program_name = s.program_name,
                last_request_end = s.last_request_end_time,
                statement_text =
                    CASE
                        WHEN r.session_id IS NOT NULL
                        THEN
                            SUBSTRING
                            (
                                st.text,
                                ISNULL(r.statement_start_offset, 0) / 2 + 1,
                                CASE
                                    WHEN ISNULL(r.statement_end_offset, -1) = -1 OR r.statement_end_offset < ISNULL(r.statement_start_offset, 0)
                                    THEN 2147483647
                                    ELSE (r.statement_end_offset - ISNULL(r.statement_start_offset, 0)) / 2 + 1
                                END
                            )
                        ELSE st.text
                    END,
                input_buffer_text = ISNULL(ib.input_buffer, ib2.event_info)
            INTO #o_tempdb_sessions
            FROM
            (
                SELECT TOP (@top_n)
                    t.session_id,
                    session_user_pages = ISNULL(t.session_user_pages, 0),
                    session_internal_pages = ISNULL(t.session_internal_pages, 0),
                    task_user_pages = ISNULL(t.task_user_pages, 0),
                    task_internal_pages = ISNULL(t.task_internal_pages, 0),
                    total_pages = ISNULL(t.session_user_pages, 0) + ISNULL(t.session_internal_pages, 0) + ISNULL(t.task_user_pages, 0) + ISNULL(t.task_internal_pages, 0)
                FROM #tsu AS t
                JOIN #sess AS ss
                  ON ss.session_id = t.session_id
                WHERE ss.database_id = @db_id
                AND   ss.is_user_process = 1
                AND   ISNULL(t.session_user_pages, 0) + ISNULL(t.session_internal_pages, 0) + ISNULL(t.task_user_pages, 0) + ISNULL(t.task_internal_pages, 0) > 0
                ORDER BY
                    total_pages DESC
            ) AS x
            JOIN #sess AS s
              ON s.session_id = x.session_id
            OUTER APPLY
            (
                SELECT TOP (1)
                    rr.session_id,
                    rr.command,
                    rr.wait_type,
                    rr.total_elapsed_time,
                    rr.sql_handle,
                    rr.statement_start_offset,
                    rr.statement_end_offset
                FROM #req AS rr
                WHERE rr.session_id = x.session_id
                ORDER BY
                    rr.request_id
            ) AS r
            LEFT JOIN #ib AS ib
              ON ib.session_id = x.session_id
            OUTER APPLY
            (
                SELECT
                    ibf.event_info
                FROM sys.dm_exec_input_buffer(x.session_id, NULL) AS ibf
                WHERE ib.session_id IS NULL
            ) AS ib2
            OUTER APPLY sys.dm_exec_sql_text(ISNULL(r.sql_handle, s.most_recent_sql_handle)) AS st;
        END TRY
        BEGIN CATCH
            UPDATE #emit SET error_message = LEFT(ERROR_MESSAGE(), 4000) WHERE result_key = @rk;
        END CATCH;

        UPDATE #emit SET duration_ms = DATEDIFF_BIG(MILLISECOND, @t0, SYSDATETIME()) WHERE result_key = @rk;
    END;

    /* ============================================================================================
       800 open_transactions, 810 version_store, 820 log_usage, 830 replicas
       ============================================================================================ */
    IF @do_transactions = 1
    BEGIN
        SELECT
            @rk = N'open_transactions',
            @t0 = SYSDATETIME();

        INSERT #emit (section_order, section_key, result_key, result_name, table_name, empty_message)
        VALUES
        (
            800, N'transactions', @rk,
            CASE
                WHEN @slow = 1 THEN N'OPEN TRANSACTIONS (all, oldest first)'
                ELSE CONCAT(N'OPEN TRANSACTIONS (older than ', @long_running_seconds, N' s, idle in transaction, blocking or rolling back; oldest first)')
            END,
            N'#o_open_transactions',
            N'No open transactions worth attention in this database.'
        );

        BEGIN TRY
            SELECT
                rn = ROW_NUMBER() OVER (ORDER BY CASE WHEN q.begin_time IS NULL THEN 1 ELSE 0 END, q.begin_time, q.session_id, q.transaction_id),
                session_id = q.session_id,
                transaction_id = q.transaction_id,
                concern =
                    ISNULL
                    (
                        STUFF
                        (
                            CONCAT
                            (
                                CASE WHEN q.transaction_state = 7 THEN N', ROLLING BACK' END,
                                CASE WHEN q.total_blocked > 0 THEN CONCAT(N', BLOCKING ', q.total_blocked, N' SESSION(S)') END,
                                CASE
                                    WHEN q.request_session_id IS NULL AND q.session_status = N'sleeping' AND q.idle_ms >= 5000
                                    THEN CASE WHEN q.holds_resources = 1 OR q.total_blocked > 0 THEN N', SLEEPING WITH OPEN TRANSACTION' ELSE N', SLEEPING, TRANSACTION HAS DONE NO WORK' END
                                END,
                                CASE WHEN q.tran_ms >= 600000 AND (q.holds_resources = 1 OR q.total_blocked > 0 OR q.request_session_id IS NOT NULL) THEN N', OPEN > 10 MIN' END,
                                CASE WHEN q.log_bytes_used >= 1073741824 THEN N', > 1 GB LOG' END
                            ),
                            1, 2, N''
                        ),
                        N''
                    ),
                holds_resources = CONVERT(bit, CASE WHEN q.holds_resources = 1 OR q.total_blocked > 0 THEN 1 ELSE 0 END),
                transaction_age =
                    CASE
                        WHEN q.tran_ms >= 0
                        THEN CONCAT(CASE WHEN q.tran_ms < 864000000 THEN '0' ELSE '' END, q.tran_ms / 86400000, ' ', CONVERT(varchar(8), DATEADD(SECOND, CONVERT(int, q.tran_ms % 86400000 / 1000), CONVERT(time(0), '00:00:00')), 108), '.', RIGHT(CONCAT('00', q.tran_ms % 1000), 3))
                    END,
                transaction_ms = q.tran_ms,
                transaction_begin = q.begin_time,
                first_log_record = q.db_tran_begin_time,
                transaction_name = q.transaction_name,
                transaction_type =
                    CASE q.transaction_type
                        WHEN 1 THEN N'read/write'
                        WHEN 2 THEN N'read-only'
                        WHEN 3 THEN N'system'
                        WHEN 4 THEN N'distributed'
                    END,
                transaction_state =
                    CASE q.transaction_state
                        WHEN 0 THEN N'initializing'
                        WHEN 1 THEN N'initialized, not started'
                        WHEN 2 THEN N'active'
                        WHEN 3 THEN N'ended (read-only)'
                        WHEN 4 THEN N'distributed commit initiated'
                        WHEN 5 THEN N'prepared, awaiting resolution'
                        WHEN 6 THEN N'committed'
                        WHEN 7 THEN N'rolling back'
                        WHEN 8 THEN N'rolled back'
                    END,
                database_state =
                    CASE q.db_tran_state
                        WHEN 1 THEN N'not initialized'
                        WHEN 3 THEN N'no log records yet'
                        WHEN 4 THEN N'log records generated'
                        WHEN 5 THEN N'prepared'
                        WHEN 10 THEN N'committed'
                        WHEN 11 THEN N'rolled back'
                        WHEN 12 THEN N'being committed'
                    END,
                is_user_transaction = q.is_user_transaction,
                log_records = q.log_record_count,
                log_used_mb = CONVERT(decimal(18, 2), q.log_bytes_used / 1048576.0),
                log_reserved_mb = CONVERT(decimal(18, 2), q.log_bytes_reserved / 1048576.0),
                is_snapshot = q.is_snapshot,
                snapshot_seconds = q.snapshot_elapsed_s,
                max_version_chain = q.max_version_chain,
                session_status = q.session_status,
                request_status = r.status,
                command = r.command,
                wait_type = r.wait_type,
                idle_ms = q.idle_ms,
                blocking_others = q.total_blocked,
                isolation_level =
                    CASE s.transaction_isolation_level
                        WHEN 0 THEN N'Unspecified'
                        WHEN 1 THEN N'Read Uncommitted'
                        WHEN 2 THEN CASE WHEN @rcsi = 1 THEN N'Read Committed (RCSI)' ELSE N'Read Committed' END
                        WHEN 3 THEN N'Repeatable Read'
                        WHEN 4 THEN N'Serializable'
                        WHEN 5 THEN N'Snapshot'
                    END,
                open_transaction_count = s.open_transaction_count,
                login_name = s.login_name,
                host_name = s.host_name,
                program_name = s.program_name,
                client_net_address = s.client_net_address,
                last_request_start = s.last_request_start_time,
                last_request_end = s.last_request_end_time,
                statement_text =
                    CASE
                        WHEN r.sql_handle IS NOT NULL
                        THEN
                            SUBSTRING
                            (
                                st.text,
                                ISNULL(r.statement_start_offset, 0) / 2 + 1,
                                CASE
                                    WHEN ISNULL(r.statement_end_offset, -1) = -1 OR r.statement_end_offset < ISNULL(r.statement_start_offset, 0)
                                    THEN 2147483647
                                    ELSE (r.statement_end_offset - ISNULL(r.statement_start_offset, 0)) / 2 + 1
                                END
                            )
                        ELSE st.text
                    END,
                input_buffer_text = ib.input_buffer
            INTO #o_open_transactions
            FROM
            (
                SELECT TOP (@top_n)
                    t.*,
                    begin_time = ISNULL(t.transaction_begin_time, t.db_tran_begin_time),
                    tran_ms = DATEDIFF_BIG(MILLISECOND, ISNULL(t.transaction_begin_time, t.db_tran_begin_time), @now),
                    session_status = ss.status,
                    idle_ms = CASE WHEN rq.session_id IS NULL THEN DATEDIFF_BIG(MILLISECOND, ss.last_request_end_time, @now) END,
                    request_session_id = rq.session_id,
                    total_blocked = bc.total_blocked
                FROM #trn AS t
                LEFT JOIN #sess AS ss
                  ON ss.session_id = t.session_id
                LEFT JOIN #blk_counts AS bc
                  ON bc.session_id = t.session_id
                OUTER APPLY
                (
                    SELECT TOP (1)
                        rr.session_id
                    FROM #req AS rr
                    WHERE rr.session_id = t.session_id
                ) AS rq
                WHERE
                (
                    (ss.database_id = @db_id AND ss.is_user_process = 1)
                    OR (t.session_id IS NULL AND t.db_tran_state IS NOT NULL)
                )
                AND
                (
                    @slow = 1
                    OR DATEDIFF_BIG(MILLISECOND, ISNULL(t.transaction_begin_time, t.db_tran_begin_time), @now) >= @long_running_seconds * 1000
                    OR (t.session_id IS NOT NULL AND rq.session_id IS NULL)
                    OR bc.total_blocked > 0
                    OR t.transaction_state = 7
                )
                ORDER BY
                    CASE WHEN ISNULL(t.transaction_begin_time, t.db_tran_begin_time) IS NULL THEN 1 ELSE 0 END,
                    ISNULL(t.transaction_begin_time, t.db_tran_begin_time)
            ) AS q
            LEFT JOIN #sess AS s
              ON s.session_id = q.session_id
            OUTER APPLY
            (
                SELECT TOP (1)
                    rr.status,
                    rr.command,
                    rr.wait_type,
                    rr.sql_handle,
                    rr.statement_start_offset,
                    rr.statement_end_offset
                FROM #req AS rr
                WHERE rr.session_id = q.session_id
                ORDER BY
                    rr.request_id
            ) AS r
            LEFT JOIN #ib AS ib
              ON ib.session_id = q.session_id
            OUTER APPLY sys.dm_exec_sql_text(ISNULL(r.sql_handle, s.most_recent_sql_handle)) AS st;
        END TRY
        BEGIN CATCH
            UPDATE #emit SET error_message = LEFT(ERROR_MESSAGE(), 4000) WHERE result_key = @rk;
        END CATCH;

        UPDATE #emit SET duration_ms = DATEDIFF_BIG(MILLISECOND, @t0, SYSDATETIME()) WHERE result_key = @rk;

        SELECT
            @rk = N'version_store',
            @t0 = SYSDATETIME();

        INSERT #emit (section_order, section_key, result_key, result_name, table_name, empty_message)
        VALUES (810, N'transactions', @rk, N'VERSION STORE (persistent version store for ADR, tempdb version store, and what holds cleanup back)', N'#o_version_store', N'No version store information available.');

        BEGIN TRY
            SELECT
                rn = 1,
                adr_enabled = d.is_accelerated_database_recovery_on,
                rcsi_enabled = d.is_read_committed_snapshot_on,
                snapshot_isolation = d.snapshot_isolation_state_desc COLLATE DATABASE_DEFAULT,
                pvs_mb = CONVERT(decimal(18, 2), p.persistent_version_store_size_kb / 1024.0),
                pvs_pct_of_used_space = CONVERT(decimal(9, 1), 100.0 * p.persistent_version_store_size_kb / NULLIF(u.used_kb, 0)),
                online_index_version_store_mb = CONVERT(decimal(18, 2), p.online_index_version_store_size_kb / 1024.0),
                tempdb_version_store_mb = CONVERT(decimal(18, 2), tv.reserved_space_kb / 1024.0),
                aborted_transactions = p.current_aborted_transaction_count,
                oldest_active_transaction_id = p.oldest_active_transaction_id,
                oldest_active_session_id = oa.session_id,
                oldest_active_age =
                    CASE
                        WHEN oa.tran_ms >= 0
                        THEN CONCAT(CASE WHEN oa.tran_ms < 864000000 THEN '0' ELSE '' END, oa.tran_ms / 86400000, ' ', CONVERT(varchar(8), DATEADD(SECOND, CONVERT(int, oa.tran_ms % 86400000 / 1000), CONVERT(time(0), '00:00:00')), 108), '.', RIGHT(CONCAT('00', oa.tran_ms % 1000), 3))
                    END,
                oldest_aborted_transaction_id = p.oldest_aborted_transaction_id,
                oldest_version_reader_session_id = vr.session_id,
                oldest_version_reader_seconds = vr.snapshot_elapsed_s,
                offrow_cleaner_start = p.offrow_version_cleaner_start_time,
                offrow_cleaner_end = p.offrow_version_cleaner_end_time,
                aborted_cleaner_start = p.aborted_version_cleaner_start_time,
                aborted_cleaner_end = p.aborted_version_cleaner_end_time,
                pages_skipped_low_water_mark = p.pvs_off_row_page_skipped_low_water_mark,
                pages_skipped_transaction_not_cleaned = p.pvs_off_row_page_skipped_transaction_not_cleaned,
                pages_skipped_oldest_active_xdesid = p.pvs_off_row_page_skipped_oldest_active_xdesid,
                pages_skipped_min_useful_xts = p.pvs_off_row_page_skipped_min_useful_xts,
                pages_skipped_oldest_snapshot = p.pvs_off_row_page_skipped_oldest_snapshot,
                pages_skipped_oldest_aborted_xdesid = p.pvs_off_row_page_skipped_oldest_aborted_xdesid,
                interpretation =
                    CASE
                        WHEN p.persistent_version_store_size_kb >= 52428800
                        OR   p.persistent_version_store_size_kb >= 0.10 * u.used_kb
                        THEN
                            CASE
                                WHEN oa.session_id IS NOT NULL
                                THEN CONCAT(N'PVS is large and cleanup is held back by the oldest active transaction (session ', oa.session_id, N'). Commit or roll it back; see open_transactions.')
                                WHEN p.current_aborted_transaction_count > 0
                                THEN N'PVS is large and aborted transactions are waiting for the aborted version cleaner.'
                                WHEN vr.session_id IS NOT NULL AND vr.snapshot_elapsed_s >= 600
                                THEN CONCAT(N'PVS is large and a long-running versioned reader (session ', vr.session_id, N') keeps old versions alive.')
                                ELSE N'PVS is large and no local user session holds it: look for long queries on readable secondaries or geo-secondaries, or system transactions. The pages_skipped_* counters show which reason dominates.'
                            END
                        WHEN p.current_aborted_transaction_count > 0
                        THEN N'Aborted transactions are waiting for the aborted version cleaner. Normal after rollbacks unless the count keeps growing.'
                        WHEN tv.reserved_space_kb >= 10485760
                        THEN N'The tempdb version store for this database is large: a long-running snapshot or RCSI reader holds versions. See open_transactions.'
                        ELSE N'OK'
                    END
            INTO #o_version_store
            FROM sys.databases AS d
            LEFT JOIN sys.dm_tran_persistent_version_store_stats AS p
              ON p.database_id = d.database_id
            OUTER APPLY
            (
                SELECT
                    used_kb = SUM(fsu.allocated_extent_page_count) * 8
                FROM sys.dm_db_file_space_usage AS fsu
                WHERE fsu.database_id = d.database_id
            ) AS u
            OUTER APPLY
            (
                SELECT
                    reserved_space_kb = SUM(vs.reserved_space_kb)
                FROM sys.dm_tran_version_store_space_usage AS vs
                WHERE vs.database_id = d.database_id
            ) AS tv
            OUTER APPLY
            (
                SELECT TOP (1)
                    t.session_id,
                    tran_ms = DATEDIFF_BIG(MILLISECOND, ISNULL(t.transaction_begin_time, t.db_tran_begin_time), @now)
                FROM #trn AS t
                WHERE t.transaction_id = p.oldest_active_transaction_id
            ) AS oa
            OUTER APPLY
            (
                SELECT TOP (1)
                    t.session_id,
                    t.snapshot_elapsed_s
                FROM #trn AS t
                LEFT JOIN #sess AS s
                  ON s.session_id = t.session_id
                WHERE t.snapshot_elapsed_s IS NOT NULL
                AND   (s.database_id = d.database_id OR t.db_tran_state IS NOT NULL)
                ORDER BY
                    t.snapshot_elapsed_s DESC
            ) AS vr
            WHERE d.database_id = @db_id;
        END TRY
        BEGIN CATCH
            UPDATE #emit SET error_message = LEFT(ERROR_MESSAGE(), 4000) WHERE result_key = @rk;
        END CATCH;

        UPDATE #emit SET duration_ms = DATEDIFF_BIG(MILLISECOND, @t0, SYSDATETIME()) WHERE result_key = @rk;

        SELECT
            @rk = N'log_usage',
            @t0 = SYSDATETIME();

        INSERT #emit (section_order, section_key, result_key, result_name, table_name, empty_message)
        VALUES (820, N'transactions', @rk, N'TRANSACTION LOG (space against the maximum log size, truncation holdup and log rate)', N'#o_log_usage', N'No transaction log information available.');

        BEGIN TRY
            SELECT
                rn = 1,
                recovery_model = d.recovery_model_desc COLLATE DATABASE_DEFAULT,
                log_reuse_wait = d.log_reuse_wait_desc COLLATE DATABASE_DEFAULT,
                log_truncation_holdup = ls.log_truncation_holdup_reason COLLATE DATABASE_DEFAULT,
                log_size_mb = CONVERT(decimal(18, 2), lsu.total_log_size_in_bytes / 1048576.0),
                log_used_mb = CONVERT(decimal(18, 2), lsu.used_log_space_in_bytes / 1048576.0),
                log_used_pct = CONVERT(decimal(9, 1), lsu.used_log_space_in_percent),
                log_max_mb = CONVERT(decimal(18, 2), @log_max_mb),
                log_used_pct_of_max = CONVERT(decimal(9, 1), lm.pct_of_max),
                active_log_mb = CONVERT(decimal(18, 2), ls.active_log_size_mb),
                log_since_last_backup_mb = CONVERT(decimal(18, 2), ls.log_since_last_log_backup_mb),
                log_since_last_checkpoint_mb = CONVERT(decimal(18, 2), ls.log_since_last_checkpoint_mb),
                log_recovery_size_mb = CONVERT(decimal(18, 2), ls.log_recovery_size_mb),
                total_vlfs = ls.total_vlf_count,
                active_vlfs = ls.active_vlf_count,
                last_log_backup = CASE WHEN ls.log_backup_time > '19000101' THEN ls.log_backup_time END,
                log_write_pct_latest = rs.avg_log_write_percent,
                log_rate_limit_mbps = @rg_max_log_rate_mbps,
                interpretation =
                    CASE
                        WHEN lp.fill_pct >= 70 AND d.log_reuse_wait_desc = N'ACTIVE_TRANSACTION'
                        THEN N'The log is filling because a long-running transaction prevents truncation. Find it in open_transactions (oldest first) and commit or roll it back.'
                        WHEN lp.fill_pct >= 70 AND d.log_reuse_wait_desc = N'LOG_BACKUP'
                        THEN N'The log is waiting for the next automatic log backup. Usually transient in Azure SQL Database; if it persists, open a support case.'
                        WHEN lp.fill_pct >= 70 AND d.log_reuse_wait_desc IN (N'AVAILABILITY_REPLICA', N'DATABASE_MIRRORING')
                        THEN N'The log is retained for a replica (HA or geo-secondary) that is behind. See replicas.'
                        WHEN lp.fill_pct >= 70
                        THEN CONCAT(N'The log is ', CONVERT(decimal(9, 1), lp.fill_pct), N'% used; truncation waits on ', d.log_reuse_wait_desc COLLATE DATABASE_DEFAULT, N'.')
                        WHEN rs.avg_log_write_percent >= 90
                        THEN N'Log generation is at the service objective log rate limit (LOG_RATE_GOVERNOR waits). Batch large modifications, move index maintenance off peak, or scale up.'
                        ELSE N'OK'
                    END
            INTO #o_log_usage
            FROM sys.databases AS d
            OUTER APPLY sys.dm_db_log_stats(d.database_id) AS ls
            LEFT JOIN sys.dm_db_log_space_usage AS lsu
              ON lsu.database_id = d.database_id
            /* The log file grows on demand: judge how full the log is against its maximum size,
               and against the current file only when the maximum is not known. */
            CROSS APPLY
            (
                SELECT
                    pct_of_max =
                        CASE
                            WHEN @log_max_mb * 1048576.0 >= lsu.total_log_size_in_bytes
                            THEN 100.0 * lsu.used_log_space_in_bytes / (@log_max_mb * 1048576.0)
                        END
            ) AS lm
            CROSS APPLY
            (
                SELECT
                    fill_pct = ISNULL(lm.pct_of_max, lsu.used_log_space_in_percent)
            ) AS lp
            OUTER APPLY
            (
                SELECT TOP (1)
                    s.avg_log_write_percent
                FROM sys.dm_db_resource_stats AS s
                ORDER BY
                    s.end_time DESC
            ) AS rs
            WHERE d.database_id = @db_id;
        END TRY
        BEGIN CATCH
            UPDATE #emit SET error_message = LEFT(ERROR_MESSAGE(), 4000) WHERE result_key = @rk;
        END CATCH;

        UPDATE #emit SET duration_ms = DATEDIFF_BIG(MILLISECOND, @t0, SYSDATETIME()) WHERE result_key = @rk;
    END;

    IF @do_transactions = 1 OR @do_summary = 1
    BEGIN
        BEGIN TRY
            INSERT #replicas
            (
                sort_group, source, replica, role, state, health, is_suspended, suspend_reason, lag_seconds,
                log_send_queue_kb, log_send_rate_kb_s, redo_queue_kb, redo_rate_kb_s, last_commit_utc,
                last_replication_utc, secondary_allow_connections
            )
            SELECT
                1,
                N'HA replica',
                CONCAT(CASE WHEN rs.is_local = 1 THEN N'local ' ELSE N'remote ' END, CONVERT(nvarchar(36), rs.replica_id)),
                CASE WHEN rs.is_primary_replica = 1 THEN N'PRIMARY' ELSE N'SECONDARY' END,
                CONCAT(rs.synchronization_state_desc, N' / ' + rs.database_state_desc) COLLATE DATABASE_DEFAULT,
                rs.synchronization_health_desc COLLATE DATABASE_DEFAULT,
                rs.is_suspended,
                rs.suspend_reason_desc COLLATE DATABASE_DEFAULT,
                rs.secondary_lag_seconds,
                rs.log_send_queue_size,
                rs.log_send_rate,
                rs.redo_queue_size,
                rs.redo_rate,
                rs.last_commit_time,
                NULL,
                NULL
            FROM sys.dm_database_replica_states AS rs
            WHERE rs.database_id = @db_id;
        END TRY
        BEGIN CATCH
            INSERT #messages (msg_type, section, message)
            VALUES ('INFO', N'transactions', LEFT(N'sys.dm_database_replica_states: ' + ERROR_MESSAGE(), 4000));
        END CATCH;

        BEGIN TRY
            INSERT #replicas
            (
                sort_group, source, replica, role, state, health, is_suspended, suspend_reason, lag_seconds,
                log_send_queue_kb, log_send_rate_kb_s, redo_queue_kb, redo_rate_kb_s, last_commit_utc,
                last_replication_utc, secondary_allow_connections
            )
            SELECT
                2,
                N'geo-replication link',
                CONCAT(gl.partner_server, N'.', gl.partner_database) COLLATE DATABASE_DEFAULT,
                gl.role_desc COLLATE DATABASE_DEFAULT,
                gl.replication_state_desc COLLATE DATABASE_DEFAULT,
                NULL,
                NULL,
                NULL,
                gl.replication_lag_sec,
                NULL,
                NULL,
                NULL,
                NULL,
                CONVERT(datetime2(3), SWITCHOFFSET(gl.last_commit, 0)),
                CONVERT(datetime2(3), SWITCHOFFSET(gl.last_replication, 0)),
                gl.secondary_allow_connections_desc COLLATE DATABASE_DEFAULT
            FROM sys.dm_geo_replication_link_status AS gl;
        END TRY
        BEGIN CATCH
            INSERT #messages (msg_type, section, message)
            VALUES ('INFO', N'transactions', LEFT(N'sys.dm_geo_replication_link_status: ' + ERROR_MESSAGE(), 4000));
        END CATCH;
    END;

    IF @do_transactions = 1
    BEGIN
        SELECT
            @rk = N'replicas',
            @t0 = SYSDATETIME();

        INSERT #emit (section_order, section_key, result_key, result_name, table_name, empty_message)
        VALUES (830, N'transactions', @rk, N'REPLICAS (HA replica state and geo-replication links)', N'#o_replicas', N'No replica or geo-replication information visible.');

        BEGIN TRY
            SELECT
                rn = ROW_NUMBER() OVER (ORDER BY r.sort_group, r.role, r.replica),
                source = r.source,
                replica = r.replica,
                role = r.role,
                state = r.state,
                health = r.health,
                is_suspended = r.is_suspended,
                suspend_reason = r.suspend_reason,
                lag_seconds = r.lag_seconds,
                log_send_queue_kb = r.log_send_queue_kb,
                log_send_rate_kb_s = r.log_send_rate_kb_s,
                redo_queue_kb = r.redo_queue_kb,
                redo_rate_kb_s = r.redo_rate_kb_s,
                last_commit_utc = r.last_commit_utc,
                last_replication_utc = r.last_replication_utc,
                secondary_allow_connections = r.secondary_allow_connections,
                interpretation =
                    CASE
                        WHEN r.is_suspended = 1
                        THEN N'Data movement is suspended: this replica is not receiving changes.'
                        WHEN r.health IS NOT NULL AND r.health <> N'HEALTHY'
                        THEN N'Replica is not healthy.'
                        WHEN r.lag_seconds >= 60
                        THEN N'Replica is more than a minute behind: heavy log generation, or the secondary is undersized or busy.'
                        WHEN r.sort_group = 1 AND r.role = N'PRIMARY'
                        AND  NOT EXISTS (SELECT 1/0 FROM #replicas AS r2 WHERE r2.sort_group = 1 AND r2.role <> N'PRIMARY')
                        THEN N'OK. No secondary replica is visible from this connection.'
                        WHEN r.sort_group = 2
                        THEN N'OK. The role column is the role of this database in the link.'
                        ELSE N'OK'
                    END
            INTO #o_replicas
            FROM #replicas AS r;
        END TRY
        BEGIN CATCH
            UPDATE #emit SET error_message = LEFT(ERROR_MESSAGE(), 4000) WHERE result_key = @rk;
        END CATCH;

        UPDATE #emit SET duration_ms = DATEDIFF_BIG(MILLISECOND, @t0, SYSDATETIME()) WHERE result_key = @rk;
    END;

    /* ============================================================================================
       900 FILE IO. Hyperscale: data files are page servers (their writes are simulated),
       database_id 0 is the local SSD cache, and Data IO % governs local SSD + tempdb only.
       ============================================================================================ */
    IF @do_io = 1
    BEGIN
        SELECT
            @rk = N'file_io',
            @t0 = SYSDATETIME();

        INSERT #emit (section_order, section_key, result_key, result_name, table_name, empty_message)
        VALUES
        (
            900, N'io', @rk,
            CASE
                WHEN @is_sampled = 1
                THEN N'FILE IO - DELTA OVER ' + CONVERT(nvarchar(20), @sample_s) + N' s'
                ELSE N'FILE IO - CUMULATIVE SINCE INSTANCE START (use @sample_seconds for current rates)'
            END,
            N'#o_file_io',
            N'No file IO statistics available.'
        );

        BEGIN TRY
            WITH
                d AS
                (
                    SELECT
                        grp =
                            CASE
                                WHEN s2.database_id = 0 THEN 3
                                WHEN s2.database_id = 2 AND @db_id <> 2 THEN CASE WHEN s2.file_id = 2 THEN 5 ELSE 4 END
                                WHEN df.type = 1 THEN 2
                                ELSE 1
                            END,
                        reads = s2.num_of_reads - ISNULL(s1.num_of_reads, 0),
                        read_bytes = s2.num_of_bytes_read - ISNULL(s1.num_of_bytes_read, 0),
                        read_stall = s2.io_stall_read_ms - ISNULL(s1.io_stall_read_ms, 0),
                        read_queued = s2.io_stall_queued_read_ms - ISNULL(s1.io_stall_queued_read_ms, 0),
                        writes = s2.num_of_writes - ISNULL(s1.num_of_writes, 0),
                        write_bytes = s2.num_of_bytes_written - ISNULL(s1.num_of_bytes_written, 0),
                        write_stall = s2.io_stall_write_ms - ISNULL(s1.io_stall_write_ms, 0),
                        write_queued = s2.io_stall_queued_write_ms - ISNULL(s1.io_stall_queued_write_ms, 0),
                        size_bytes = CASE WHEN df.size IS NOT NULL THEN CONVERT(bigint, df.size) * 8192 ELSE s2.size_on_disk_bytes END
                    FROM #file_snap AS s2
                    LEFT JOIN #file_snap AS s1
                      ON  s1.sample_no = 1
                      AND s1.database_id = s2.database_id
                      AND s1.file_id = s2.file_id
                    LEFT JOIN sys.database_files AS df
                      ON  s2.database_id = @db_id
                      AND df.file_id = s2.file_id
                    WHERE s2.sample_no = 2
                ),
                a AS
                (
                    SELECT
                        d.grp,
                        files = COUNT(*),
                        reads = SUM(d.reads),
                        read_bytes = SUM(d.read_bytes),
                        read_stall = SUM(d.read_stall),
                        read_queued = SUM(d.read_queued),
                        writes = SUM(d.writes),
                        write_bytes = SUM(d.write_bytes),
                        write_stall = SUM(d.write_stall),
                        write_queued = SUM(d.write_queued),
                        worst_read_ms = MAX(CASE WHEN d.reads > 0 THEN d.read_stall * 1.0 / d.reads END),
                        worst_write_ms = MAX(CASE WHEN d.writes > 0 THEN d.write_stall * 1.0 / d.writes END),
                        size_bytes = SUM(d.size_bytes)
                    FROM d
                    GROUP BY d.grp
                ),
                m AS
                (
                    SELECT
                        a.*,
                        avg_read_ms = a.read_stall * 1.0 / NULLIF(a.reads, 0),
                        avg_write_ms = a.write_stall * 1.0 / NULLIF(a.writes, 0),
                        queued_pct = 100.0 * (ISNULL(a.read_queued, 0) + ISNULL(a.write_queued, 0))
                                     / NULLIF(ISNULL(a.read_stall, 0) + ISNULL(a.write_stall, 0), 0),
                        queued_ms_per_io = (ISNULL(a.read_queued, 0) + ISNULL(a.write_queued, 0)) * 1.0
                                           / NULLIF(ISNULL(a.reads, 0) + ISNULL(a.writes, 0), 0),
                        local_read_share_pct =
                            CASE
                                WHEN @is_hyperscale = 1 AND a.grp IN (1, 3)
                                THEN 100.0 * a.read_bytes / NULLIF(SUM(CASE WHEN a.grp IN (1, 3) THEN a.read_bytes END) OVER (), 0)
                            END,
                        seconds =
                            CASE
                                WHEN @is_sampled = 1 THEN @sample_s
                                ELSE CONVERT(decimal(18, 3), DATEDIFF_BIG(SECOND, @instance_start, @now))
                            END
                    FROM a
                )
            SELECT
                rn = ROW_NUMBER() OVER (ORDER BY m.grp),
                database_name = CASE WHEN m.grp = 3 THEN N'(compute replica)' WHEN m.grp IN (4, 5) THEN N'tempdb' ELSE @db_name END,
                file_type =
                    CASE m.grp
                        WHEN 1 THEN CASE WHEN @is_hyperscale = 1 THEN N'data (page servers)' ELSE N'data' END
                        WHEN 3 THEN N'local SSD cache (RBPEX)'
                        WHEN 4 THEN N'data'
                        ELSE N'log'
                    END,
                files = m.files,
                reads = m.reads,
                read_mb = CONVERT(decimal(19, 1), m.read_bytes / 1048576.0),
                avg_read_ms = CONVERT(decimal(19, 2), m.avg_read_ms),
                worst_file_avg_read_ms = CONVERT(decimal(19, 2), m.worst_read_ms),
                writes = m.writes,
                write_mb = CONVERT(decimal(19, 1), m.write_bytes / 1048576.0),
                avg_write_ms = CONVERT(decimal(19, 2), m.avg_write_ms),
                worst_file_avg_write_ms = CONVERT(decimal(19, 2), m.worst_write_ms),
                iops = CONVERT(decimal(19, 1), (ISNULL(m.reads, 0) + ISNULL(m.writes, 0)) / NULLIF(m.seconds, 0)),
                read_mb_per_sec = CONVERT(decimal(19, 2), m.read_bytes / 1048576.0 / NULLIF(m.seconds, 0)),
                write_mb_per_sec = CONVERT(decimal(19, 2), m.write_bytes / 1048576.0 / NULLIF(m.seconds, 0)),
                avg_queued_read_ms = CONVERT(decimal(19, 2), m.read_queued * 1.0 / NULLIF(m.reads, 0)),
                avg_queued_write_ms = CONVERT(decimal(19, 2), m.write_queued * 1.0 / NULLIF(m.writes, 0)),
                governance_pct_of_stall = CONVERT(decimal(9, 1), m.queued_pct),
                pct_of_data_bytes_read = CONVERT(decimal(9, 1), m.local_read_share_pct),
                size_mb = CONVERT(decimal(19, 1), m.size_bytes / 1048576.0),
                measured_over =
                    CASE
                        WHEN @is_sampled = 1 THEN CONCAT(N'last ', @sample_s, N' s')
                        ELSE CONCAT(N'since about ', CONVERT(nvarchar(19), @instance_start, 120), N' UTC')
                    END,
                interpretation =
                    CASE
                        WHEN ISNULL(m.reads, 0) + ISNULL(m.writes, 0) = 0
                        THEN N'No IO in this window.'
                        WHEN m.queued_pct >= 10 AND m.queued_ms_per_io >= 2 AND m.grp IN (2, 5)
                        THEN N'Resource governance is queuing log IO: the log rate limit is being reached. Check LOG_RATE_GOVERNOR waits, large modifications and index maintenance.'
                        WHEN m.queued_pct >= 10 AND m.queued_ms_per_io >= 2
                        THEN N'Resource governance is queuing data IO (Max Data IOPS limit'
                             + CASE WHEN @is_hyperscale = 1 THEN N' for local SSD and tempdb' ELSE N'' END
                             + N'). Reduce reads and writes (scans, missing indexes, spills) or scale up.'
                        WHEN m.grp = 2 AND m.avg_write_ms >= 10
                        THEN N'Log writes are slow (avg >= 10 ms): commits wait on WRITELOG. Batch small transactions and check the log rate.'
                        WHEN m.grp = 1 AND @is_hyperscale = 1 AND m.avg_read_ms >= 20
                        THEN N'Page server reads are slow (avg >= 20 ms). This includes waiting for a page server to catch up to the required LSN. Check PAGEIOLATCH waits and the local cache share.'
                        WHEN m.grp IN (1, 4) AND m.avg_read_ms >= 20
                        THEN N'Data reads are slow (avg >= 20 ms): check PAGEIOLATCH waits, Data IO % and large scans.'
                        WHEN (m.grp = 4 OR (m.grp = 1 AND @is_hyperscale = 0)) AND m.avg_write_ms >= 20
                        THEN N'Data writes are slow (avg >= 20 ms): checkpoint or lazy-writer pressure, or tempdb spills.'
                        WHEN m.grp = 3 AND m.avg_read_ms >= 5
                        THEN N'Local SSD cache reads are slower than expected (avg >= 5 ms).'
                        WHEN m.queued_pct >= 10
                        THEN N'OK. Governance adds a little queuing per IO: the workload touches the IOPS limit at times.'
                        WHEN m.grp = 1 AND @is_hyperscale = 1
                        THEN N'OK. ' + ISNULL(CONVERT(nvarchar(10), CONVERT(decimal(9, 1), m.local_read_share_pct)), N'?')
                             + N'% of data bytes read came from page servers (the rest from the local SSD cache). Page server write figures are simulated.'
                        ELSE N'OK'
                    END
            INTO #o_file_io
            FROM m;
        END TRY
        BEGIN CATCH
            UPDATE #emit SET error_message = LEFT(ERROR_MESSAGE(), 4000) WHERE result_key = @rk;
        END CATCH;

        UPDATE #emit SET duration_ms = DATEDIFF_BIG(MILLISECOND, @t0, SYSDATETIME()) WHERE result_key = @rk;
    END;

    /* ============================================================================================
       1000 plan_cache_top: aggregated by query_hash, top N by CPU, reads and duration
       ============================================================================================ */
    IF @do_queries = 1
    BEGIN
        SELECT
            @rk = N'plan_cache_top',
            @t0 = SYSDATETIME();

        INSERT #emit (section_order, section_key, result_key, result_name, table_name, empty_message)
        VALUES
        (
            1000, N'queries', @rk,
            N'PLAN CACHE TOP STATEMENTS BY CPU, READS AND DURATION (ran in the last ' + CONVERT(nvarchar(10), @lookback_minutes)
            + N' min; totals are since each plan was cached)',
            N'#o_plan_cache_top',
            N'No cached statements for this database ran in the window.'
        );

        CREATE TABLE #qs_window
        (
            query_hash binary(8) NULL,
            query_plan_hash binary(8) NULL,
            plan_handle varbinary(64) NOT NULL,
            sql_handle varbinary(64) NULL,
            statement_start_offset int NULL,
            statement_end_offset int NULL,
            creation_time datetime NULL,
            last_execution_time datetime NULL,
            execution_count bigint NULL,
            total_worker_time bigint NULL,
            total_elapsed_time bigint NULL,
            max_elapsed_time bigint NULL,
            total_logical_reads bigint NULL,
            total_physical_reads bigint NULL,
            total_page_server_reads bigint NULL,
            total_logical_writes bigint NULL,
            total_rows bigint NULL,
            total_spills bigint NULL,
            total_grant_kb bigint NULL,
            max_grant_kb bigint NULL,
            max_dop bigint NULL
        );

        BEGIN TRY
            INSERT #qs_window
            (
                query_hash, query_plan_hash, plan_handle, sql_handle, statement_start_offset, statement_end_offset,
                creation_time, last_execution_time, execution_count, total_worker_time, total_elapsed_time,
                max_elapsed_time, total_logical_reads, total_physical_reads, total_page_server_reads,
                total_logical_writes, total_rows, total_spills, total_grant_kb, max_grant_kb, max_dop
            )
            SELECT
                qs.query_hash, qs.query_plan_hash, qs.plan_handle, qs.sql_handle, qs.statement_start_offset, qs.statement_end_offset,
                qs.creation_time, qs.last_execution_time, qs.execution_count, qs.total_worker_time, qs.total_elapsed_time,
                qs.max_elapsed_time, qs.total_logical_reads, qs.total_physical_reads, qs.total_page_server_reads,
                qs.total_logical_writes, qs.total_rows, qs.total_spills, qs.total_grant_kb, qs.max_grant_kb, qs.max_dop
            FROM sys.dm_exec_query_stats AS qs
            WHERE qs.last_execution_time >= @window_start;

            /* Keep plans compiled in this database (drops master, tempdb and resource database plans) */
            INSERT #plan_db (plan_handle)
            SELECT
                p.plan_handle
            FROM
            (
                SELECT DISTINCT
                    w.plan_handle
                FROM #qs_window AS w
            ) AS p
            CROSS APPLY sys.dm_exec_plan_attributes(p.plan_handle) AS pa
            WHERE pa.attribute = N'dbid'
            AND   TRY_CONVERT(int, pa.value) = @db_id;

            WITH
                agg AS
                (
                    SELECT
                        w.query_hash,
                        executions = SUM(w.execution_count),
                        cpu_us = SUM(w.total_worker_time),
                        elapsed_us = SUM(w.total_elapsed_time),
                        max_elapsed_us = MAX(w.max_elapsed_time),
                        logical_reads = SUM(w.total_logical_reads),
                        physical_reads = SUM(w.total_physical_reads),
                        page_server_reads = SUM(w.total_page_server_reads),
                        writes = SUM(w.total_logical_writes),
                        rows_returned = SUM(w.total_rows),
                        spills = SUM(w.total_spills),
                        grant_kb = SUM(w.total_grant_kb),
                        max_grant_kb = MAX(w.max_grant_kb),
                        max_dop = MAX(w.max_dop),
                        plans = COUNT(DISTINCT w.query_plan_hash),
                        cached_entries = COUNT(*),
                        last_execution = MAX(w.last_execution_time),
                        first_cached = MIN(w.creation_time)
                    FROM #qs_window AS w
                    JOIN #plan_db AS pd
                      ON pd.plan_handle = w.plan_handle
                    GROUP BY
                        w.query_hash
                ),
                ranked AS
                (
                    SELECT
                        agg.*,
                        cpu_rank = ROW_NUMBER() OVER (ORDER BY agg.cpu_us DESC),
                        reads_rank = ROW_NUMBER() OVER (ORDER BY agg.logical_reads DESC),
                        duration_rank = ROW_NUMBER() OVER (ORDER BY agg.elapsed_us DESC),
                        all_cpu_us = SUM(agg.cpu_us) OVER (),
                        all_reads = SUM(agg.logical_reads) OVER ()
                    FROM agg
                )
            SELECT
                rn = ROW_NUMBER() OVER (ORDER BY br.best_rank, r.cpu_rank),
                ranked_by =
                    ISNULL(STUFF(CONCAT(
                        CASE WHEN r.cpu_rank <= @top_n THEN CONCAT(N', cpu #', r.cpu_rank) END,
                        CASE WHEN r.reads_rank <= @top_n THEN CONCAT(N', reads #', r.reads_rank) END,
                        CASE WHEN r.duration_rank <= @top_n THEN CONCAT(N', duration #', r.duration_rank) END), 1, 2, N''), N''),
                query_hash = CONVERT(varchar(20), r.query_hash, 1),
                executions = r.executions,
                cpu_ms = r.cpu_us / 1000,
                pct_of_cpu = CONVERT(decimal(9, 1), 100.0 * r.cpu_us / NULLIF(r.all_cpu_us, 0)),
                avg_cpu_ms = CONVERT(decimal(19, 2), r.cpu_us / 1000.0 / NULLIF(r.executions, 0)),
                duration_ms = r.elapsed_us / 1000,
                avg_duration_ms = CONVERT(decimal(19, 2), r.elapsed_us / 1000.0 / NULLIF(r.executions, 0)),
                max_duration_ms = r.max_elapsed_us / 1000,
                logical_reads = r.logical_reads,
                pct_of_reads = CONVERT(decimal(9, 1), 100.0 * r.logical_reads / NULLIF(r.all_reads, 0)),
                avg_logical_reads = r.logical_reads / NULLIF(r.executions, 0),
                physical_reads = r.physical_reads,
                page_server_reads = r.page_server_reads,
                writes = r.writes,
                avg_rows = r.rows_returned / NULLIF(r.executions, 0),
                spills = r.spills,
                avg_grant_mb = CONVERT(decimal(19, 1), r.grant_kb / 1024.0 / NULLIF(r.executions, 0)),
                max_grant_mb = CONVERT(decimal(19, 1), r.max_grant_kb / 1024.0),
                max_dop = r.max_dop,
                plans = r.plans,
                cached_entries = r.cached_entries,
                notes =
                    ISNULL(STUFF(CONCAT(
                        CASE WHEN r.spills > 0 THEN N'; spills to tempdb' END,
                        CASE WHEN r.plans > 1 THEN CONCAT(N'; ', r.plans, N' different plans (parameter sensitivity or plan variance)') END,
                        CASE WHEN r.cached_entries >= 20 THEN CONCAT(N'; ', r.cached_entries, N' cache entries for one query shape (not parameterized?)') END,
                        CASE WHEN r.max_grant_kb >= 1048576 THEN N'; memory grant of 1 GB or more' END,
                        CASE WHEN r.max_dop > 1 THEN N'; runs in parallel' END,
                        CASE WHEN ISNULL(r.max_dop, 1) <= 1 AND r.cpu_us > 0 AND r.elapsed_us > 3 * r.cpu_us THEN N'; mostly waiting (duration well above CPU)' END
                    ), 1, 2, N''), N''),
                last_execution = r.last_execution,
                first_cached = r.first_cached,
                module_name = mo.module_name,
                query_plan_hash = CONVERT(varchar(20), rep.query_plan_hash, 1),
                plan_handle = CONVERT(varchar(130), rep.plan_handle, 1),
                statement_text =
                    SUBSTRING
                    (
                        st.text,
                        ISNULL(rep.statement_start_offset, 0) / 2 + 1,
                        CASE
                            WHEN ISNULL(rep.statement_end_offset, -1) = -1
                            OR   rep.statement_end_offset < ISNULL(rep.statement_start_offset, 0)
                            THEN 2147483647
                            ELSE (rep.statement_end_offset - ISNULL(rep.statement_start_offset, 0)) / 2 + 1
                        END
                    ),
                query_plan = qp.query_plan
            INTO #o_plan_cache_top
            FROM ranked AS r
            CROSS APPLY
            (
                SELECT
                    best_rank = MIN(v.x)
                FROM (VALUES (r.cpu_rank), (r.reads_rank), (r.duration_rank)) AS v (x)
            ) AS br
            OUTER APPLY
            (
                SELECT TOP (1)
                    w.plan_handle,
                    w.sql_handle,
                    w.statement_start_offset,
                    w.statement_end_offset,
                    w.query_plan_hash
                FROM #qs_window AS w
                JOIN #plan_db AS pd
                  ON pd.plan_handle = w.plan_handle
                WHERE w.query_hash = r.query_hash
                ORDER BY
                    w.total_worker_time DESC,
                    w.last_execution_time DESC
            ) AS rep
            OUTER APPLY sys.dm_exec_sql_text(rep.sql_handle) AS st
            OUTER APPLY
            (
                SELECT
                    module_name = QUOTENAME(sc.name) + N'.' + QUOTENAME(o.name)
                FROM sys.objects AS o
                JOIN sys.schemas AS sc
                  ON sc.schema_id = o.schema_id
                WHERE o.object_id = st.objectid
                AND   st.dbid = @db_id
            ) AS mo
            OUTER APPLY
            (
                SELECT
                    query_plan = TRY_CONVERT(xml, t.query_plan)
                FROM sys.dm_exec_text_query_plan(rep.plan_handle, ISNULL(rep.statement_start_offset, 0), ISNULL(rep.statement_end_offset, -1)) AS t
                WHERE @include_plans = 1
            ) AS qp
            WHERE r.cpu_rank <= @top_n
            OR    r.reads_rank <= @top_n
            OR    r.duration_rank <= @top_n;

            IF @include_plans = 0
                ALTER TABLE #o_plan_cache_top DROP COLUMN query_plan;
        END TRY
        BEGIN CATCH
            UPDATE #emit SET error_message = LEFT(ERROR_MESSAGE(), 4000) WHERE result_key = @rk;
        END CATCH;

        UPDATE #emit SET duration_ms = DATEDIFF_BIG(MILLISECOND, @t0, SYSDATETIME()) WHERE result_key = @rk;

        /* ---- 1005 plan_cache_sampled: what completed during the sample. The plan cache counters of a
           statement change when an execution ends, so a statement that still runs is not here:
           find it in requests. ---- */
        IF @is_sampled = 1
        BEGIN
            SELECT
                @rk = N'plan_cache_sampled',
                @t0 = SYSDATETIME();

            INSERT #emit (section_order, section_key, result_key, result_name, table_name, empty_message)
            VALUES
            (
                1005, N'queries', @rk,
                N'STATEMENTS THAT COMPLETED DURING THE SAMPLE OF ' + CONVERT(nvarchar(20), @sample_s) + N' s (top by CPU and by executions; a statement that still runs is in requests, not here)',
                N'#o_plan_cache_sampled',
                N'No statement of this database completed during the sample.'
            );

            BEGIN TRY
                SELECT
                    qs.query_hash,
                    qs.plan_handle,
                    qs.sql_handle,
                    qs.statement_start_offset,
                    qs.statement_end_offset,
                    executions = qs.execution_count - ISNULL(s1.execution_count, 0),
                    cpu_us = qs.total_worker_time - ISNULL(s1.total_worker_time, 0),
                    elapsed_us = qs.total_elapsed_time - ISNULL(s1.total_elapsed_time, 0),
                    logical_reads = qs.total_logical_reads - ISNULL(s1.total_logical_reads, 0)
                INTO #qs_delta
                FROM sys.dm_exec_query_stats AS qs
                LEFT JOIN #qs_s1 AS s1
                  ON  s1.plan_handle = qs.plan_handle
                  AND s1.statement_start_offset = qs.statement_start_offset
                  AND s1.statement_end_offset = qs.statement_end_offset
                  AND s1.creation_time = qs.creation_time
                WHERE qs.execution_count > ISNULL(s1.execution_count, 0)
                /* Not in the first sample: count it only when it was compiled during the sample */
                AND   (s1.plan_handle IS NOT NULL OR qs.creation_time >= @sample_start);

                /* Keep plans compiled in this database */
                SELECT
                    p.plan_handle
                INTO #qs_delta_db
                FROM
                (
                    SELECT DISTINCT
                        w.plan_handle
                    FROM #qs_delta AS w
                ) AS p
                CROSS APPLY sys.dm_exec_plan_attributes(p.plan_handle) AS pa
                WHERE pa.attribute = N'dbid'
                AND   TRY_CONVERT(int, pa.value) = @db_id;

                WITH
                    agg AS
                    (
                        SELECT
                            w.query_hash,
                            executions = SUM(w.executions),
                            cpu_us = SUM(w.cpu_us),
                            elapsed_us = SUM(w.elapsed_us),
                            logical_reads = SUM(w.logical_reads)
                        FROM #qs_delta AS w
                        JOIN #qs_delta_db AS pd
                          ON pd.plan_handle = w.plan_handle
                        GROUP BY
                            w.query_hash
                    ),
                    ranked AS
                    (
                        SELECT
                            agg.*,
                            cpu_rank = ROW_NUMBER() OVER (ORDER BY agg.cpu_us DESC, agg.executions DESC),
                            exec_rank = ROW_NUMBER() OVER (ORDER BY agg.executions DESC, agg.cpu_us DESC),
                            all_cpu_us = SUM(agg.cpu_us) OVER (),
                            all_reads = SUM(agg.logical_reads) OVER (),
                            all_executions = SUM(agg.executions) OVER ()
                        FROM agg
                    )
                SELECT
                    rn = ROW_NUMBER() OVER (ORDER BY r.cpu_rank),
                    ranked_by =
                        ISNULL(STUFF(CONCAT(
                            CASE WHEN r.cpu_rank <= @top_n THEN CONCAT(N', cpu #', r.cpu_rank) END,
                            CASE WHEN r.exec_rank <= @top_n THEN CONCAT(N', executions #', r.exec_rank) END), 1, 2, N''), N''),
                    query_hash = CONVERT(varchar(20), r.query_hash, 1),
                    executions = r.executions,
                    executions_per_sec = CONVERT(decimal(19, 1), r.executions / NULLIF(@sample_s, 0)),
                    pct_of_executions = CONVERT(decimal(9, 1), 100.0 * r.executions / NULLIF(r.all_executions, 0)),
                    cpu_ms = r.cpu_us / 1000,
                    pct_of_cpu = CONVERT(decimal(9, 1), 100.0 * r.cpu_us / NULLIF(r.all_cpu_us, 0)),
                    avg_cores = CONVERT(decimal(9, 2), r.cpu_us / 1000000.0 / NULLIF(@sample_s, 0)),
                    avg_cpu_ms = CONVERT(decimal(19, 2), r.cpu_us / 1000.0 / NULLIF(r.executions, 0)),
                    avg_duration_ms = CONVERT(decimal(19, 2), r.elapsed_us / 1000.0 / NULLIF(r.executions, 0)),
                    logical_reads = r.logical_reads,
                    pct_of_reads = CONVERT(decimal(9, 1), 100.0 * r.logical_reads / NULLIF(r.all_reads, 0)),
                    avg_logical_reads = r.logical_reads / NULLIF(r.executions, 0),
                    notes =
                        ISNULL(STUFF(CONCAT(
                            CASE WHEN r.executions >= 50 * @sample_s THEN N'; runs 50 times a second or more: many cheap executions add up' END,
                            CASE WHEN r.cpu_us * 2 >= r.all_cpu_us AND r.all_cpu_us >= 1000000 THEN N'; half or more of the CPU of the statements that completed in the sample' END
                        ), 1, 2, N''), N''),
                    module_name = mo.module_name,
                    plan_handle = CONVERT(varchar(130), rep.plan_handle, 1),
                    statement_text =
                        SUBSTRING
                        (
                            st.text,
                            ISNULL(rep.statement_start_offset, 0) / 2 + 1,
                            CASE
                                WHEN ISNULL(rep.statement_end_offset, -1) = -1
                                OR   rep.statement_end_offset < ISNULL(rep.statement_start_offset, 0)
                                THEN 2147483647
                                ELSE (rep.statement_end_offset - ISNULL(rep.statement_start_offset, 0)) / 2 + 1
                            END
                        )
                INTO #o_plan_cache_sampled
                FROM ranked AS r
                OUTER APPLY
                (
                    SELECT TOP (1)
                        w.plan_handle,
                        w.sql_handle,
                        w.statement_start_offset,
                        w.statement_end_offset
                    FROM #qs_delta AS w
                    JOIN #qs_delta_db AS pd
                      ON pd.plan_handle = w.plan_handle
                    WHERE w.query_hash = r.query_hash
                    ORDER BY
                        w.cpu_us DESC
                ) AS rep
                OUTER APPLY sys.dm_exec_sql_text(rep.sql_handle) AS st
                OUTER APPLY
                (
                    SELECT
                        module_name = QUOTENAME(sc.name) + N'.' + QUOTENAME(o.name)
                    FROM sys.objects AS o
                    JOIN sys.schemas AS sc
                      ON sc.schema_id = o.schema_id
                    WHERE o.object_id = st.objectid
                    AND   st.dbid = @db_id
                ) AS mo
                WHERE r.cpu_rank <= @top_n
                OR    r.exec_rank <= @top_n;
            END TRY
            BEGIN CATCH
                UPDATE #emit SET error_message = LEFT(ERROR_MESSAGE(), 4000) WHERE result_key = @rk;
            END CATCH;

            UPDATE #emit SET duration_ms = DATEDIFF_BIG(MILLISECOND, @t0, SYSDATETIME()) WHERE result_key = @rk;
        END;
    END;

    /* ============================================================================================
       1100 sessions_by_app
       ============================================================================================ */
    IF @do_sessions = 1
    BEGIN
        SELECT
            @rk = N'sessions_by_app',
            @t0 = SYSDATETIME();

        INSERT #emit (section_order, section_key, result_key, result_name, table_name, empty_message)
        VALUES (1100, N'sessions', @rk, N'USER SESSIONS BY PROGRAM, HOST AND LOGIN (largest groups first)', N'#o_sessions_by_app', N'No user sessions in this database.');

        BEGIN TRY
            WITH
                s AS
                (
                    SELECT
                        program_name = ISNULL(ss.program_name, N''),
                        host_name = ISNULL(ss.host_name, N''),
                        login_name = ISNULL(ss.login_name, N''),
                        ss.client_interface_name,
                        ss.client_net_address,
                        ss.login_time,
                        ss.cpu_time,
                        ss.logical_reads,
                        ss.writes,
                        ss.memory_usage_pages,
                        is_running = CASE WHEN rq.request_count > 0 THEN 1 ELSE 0 END,
                        is_blocked = CASE WHEN rq.blocked_count > 0 THEN 1 ELSE 0 END,
                        is_blocking =
                            CASE
                                WHEN EXISTS
                                (
                                    SELECT
                                        1/0
                                    FROM #req AS rb
                                    WHERE rb.blocking_session_id = ss.session_id
                                    AND   rb.session_id <> ss.session_id
                                )
                                THEN 1
                                ELSE 0
                            END,
                        idle_open_tran = CASE WHEN rq.request_count = 0 AND ss.open_transaction_count > 0 THEN 1 ELSE 0 END,
                        idle_30_min =
                            CASE
                                WHEN rq.request_count = 0
                                AND  DATEDIFF_BIG(SECOND, ISNULL(ss.last_request_end_time, ss.login_time), @now) >= 1800
                                THEN 1
                                ELSE 0
                            END
                    FROM #sess AS ss
                    CROSS APPLY
                    (
                        SELECT
                            request_count = COUNT(*),
                            blocked_count = SUM(CASE WHEN r.blocking_session_id > 0 AND r.blocking_session_id <> r.session_id THEN 1 ELSE 0 END)
                        FROM #req AS r
                        WHERE r.session_id = ss.session_id
                    ) AS rq
                    WHERE ss.is_user_process = 1
                    AND   ss.database_id = @db_id
                ),
                g AS
                (
                    SELECT
                        s.program_name,
                        s.host_name,
                        s.login_name,
                        sessions = COUNT(*),
                        running = SUM(s.is_running),
                        sleeping = SUM(1 - s.is_running),
                        idle_with_open_tran = SUM(s.idle_open_tran),
                        blocked = SUM(s.is_blocked),
                        blocking_others = SUM(s.is_blocking),
                        idle_over_30_min = SUM(s.idle_30_min),
                        oldest_login = MIN(s.login_time),
                        newest_login = MAX(s.login_time),
                        cpu_ms = SUM(s.cpu_time),
                        logical_reads = SUM(s.logical_reads),
                        writes = SUM(s.writes),
                        memory_mb = CONVERT(decimal(19, 1), SUM(s.memory_usage_pages) * 8 / 1024.0),
                        client_interface = MAX(s.client_interface_name),
                        all_sessions = SUM(COUNT(*)) OVER ()
                    FROM s
                    GROUP BY
                        s.program_name,
                        s.host_name,
                        s.login_name
                ),
                a AS
                (
                    SELECT
                        x.program_name,
                        x.host_name,
                        x.login_name,
                        client_addresses = STRING_AGG(CONVERT(nvarchar(max), x.client_net_address), N', ') WITHIN GROUP (ORDER BY x.client_net_address)
                    FROM
                    (
                        SELECT DISTINCT
                            s.program_name,
                            s.host_name,
                            s.login_name,
                            s.client_net_address
                        FROM s
                        WHERE s.client_net_address IS NOT NULL
                    ) AS x
                    GROUP BY
                        x.program_name,
                        x.host_name,
                        x.login_name
                )
            SELECT TOP (@top_n)
                rn = ROW_NUMBER() OVER (ORDER BY g.sessions DESC, g.program_name, g.host_name, g.login_name),
                program_name = g.program_name,
                host_name = g.host_name,
                login_name = g.login_name,
                sessions = g.sessions,
                pct_of_sessions = CONVERT(decimal(9, 1), 100.0 * g.sessions / NULLIF(g.all_sessions, 0)),
                pct_of_session_limit = CONVERT(decimal(9, 1), 100.0 * g.sessions / NULLIF(@rg_max_sessions, 0)),
                running = g.running,
                sleeping = g.sleeping,
                idle_with_open_tran = g.idle_with_open_tran,
                blocked = g.blocked,
                blocking_others = g.blocking_others,
                idle_over_30_min = g.idle_over_30_min,
                oldest_login = g.oldest_login,
                newest_login = g.newest_login,
                cpu_ms = g.cpu_ms,
                logical_reads = g.logical_reads,
                writes = g.writes,
                memory_mb = g.memory_mb,
                client_interface = g.client_interface,
                client_addresses = LEFT(a.client_addresses, 400) + CASE WHEN LEN(a.client_addresses) > 400 THEN N' ...' ELSE N'' END,
                notes =
                    ISNULL(STUFF(CONCAT(
                        CASE WHEN g.blocking_others > 0 THEN N'; blocking other sessions' END,
                        CASE WHEN g.idle_with_open_tran > 0 THEN CONCAT(N'; ', g.idle_with_open_tran, N' idle session(s) with an open transaction') END,
                        CASE WHEN @rg_max_sessions > 0 AND g.sessions * 2 >= @rg_max_sessions THEN N'; uses half or more of the session limit' END,
                        CASE WHEN g.sessions >= 20 AND g.idle_over_30_min * 2 >= g.sessions THEN N'; mostly long-idle connections (pool larger than needed?)' END
                    ), 1, 2, N''), N'')
            INTO #o_sessions_by_app
            FROM g
            LEFT JOIN a
              ON  a.program_name = g.program_name
              AND a.host_name = g.host_name
              AND a.login_name = g.login_name
            ORDER BY
                g.sessions DESC,
                g.program_name,
                g.host_name,
                g.login_name;
        END TRY
        BEGIN CATCH
            UPDATE #emit SET error_message = LEFT(ERROR_MESSAGE(), 4000) WHERE result_key = @rk;
        END CATCH;

        UPDATE #emit SET duration_ms = DATEDIFF_BIG(MILLISECOND, @t0, SYSDATETIME()) WHERE result_key = @rk;
    END;

    /* ============================================================================================
       Forced plans and Query Store hints (also feed the summary). A forced plan or a hint that
       cannot be applied fails silently: the query runs with another plan.
       Dynamic SQL on purpose: plan_forcing_type_desc and sys.query_store_query_hints are newer
       than the rest of Query Store, and a column that is not there must become a message.
       ============================================================================================ */
    IF @do_config = 1 OR @do_summary = 1
    BEGIN
        SET @t0 = SYSDATETIME();

        SET @sql = N'
INSERT #forcing (kind, query_id, plan_id, forcing_type, failure_count, last_failure_reason, last_execution)
SELECT
    N''forced plan'',
    p.query_id,
    p.plan_id,
    p.plan_forcing_type_desc,
    p.force_failure_count,
    p.last_force_failure_reason_desc,
    p.last_execution_time
FROM sys.query_store_plan AS p
WHERE p.is_forced_plan = 1;';

        BEGIN TRY
            IF @debug = 1 PRINT @sql;
            EXEC sys.sp_executesql @sql;
        END TRY
        BEGIN CATCH
            INSERT #messages (msg_type, section, message)
            VALUES ('INFO', N'config', LEFT(N'Forced plans: ' + ERROR_MESSAGE(), 4000));
        END CATCH;

        SET @sql = N'
INSERT #forcing (kind, query_id, forcing_type, failure_count, last_failure_reason, hint_text)
SELECT
    N''query hint'',
    h.query_id,
    h.source_desc,
    h.query_hint_failure_count,
    h.last_query_hint_failure_reason_desc,
    h.query_hint_text
FROM sys.query_store_query_hints AS h;';

        BEGIN TRY
            IF @debug = 1 PRINT @sql;
            EXEC sys.sp_executesql @sql;
        END TRY
        BEGIN CATCH
            INSERT #messages (msg_type, section, message)
            VALUES ('INFO', N'config', LEFT(N'Query Store hints: ' + ERROR_MESSAGE(), 4000));
        END CATCH;

        IF @debug = 1
            INSERT #messages (msg_type, section, message)
            VALUES ('DEBUG', N'config', CONCAT(N'plan forcing collection: ', DATEDIFF_BIG(MILLISECOND, @t0, SYSDATETIME()), N' ms'));
    END;

    /* ============================================================================================
       1200 configuration, 1210 tuning_recommendations
       ============================================================================================ */
    IF @do_config = 1
    BEGIN
        SELECT
            @rk = N'configuration',
            @t0 = SYSDATETIME();

        INSERT #emit (section_order, section_key, result_key, result_name, table_name, empty_message)
        VALUES (1200, N'config', @rk, N'CONFIGURATION (service objective, database options, scoped configurations, automatic tuning, Query Store)', N'#o_configuration', N'No configuration information available.');

        CREATE TABLE #cfg
        (
            sort_group int NOT NULL,
            sort_order bigint NOT NULL,
            area nvarchar(60) COLLATE DATABASE_DEFAULT NOT NULL,
            setting nvarchar(128) COLLATE DATABASE_DEFAULT NOT NULL,
            value nvarchar(4000) COLLATE DATABASE_DEFAULT NULL,
            value_for_secondary nvarchar(4000) COLLATE DATABASE_DEFAULT NULL,
            is_default bit NULL,
            note nvarchar(4000) COLLATE DATABASE_DEFAULT NULL
        );

        BEGIN TRY
            INSERT #cfg (sort_group, sort_order, area, setting, value, note)
            SELECT
                1,
                v.sort_order,
                N'database',
                v.setting,
                v.value,
                v.note
            FROM sys.databases AS d
            LEFT JOIN sys.database_service_objectives AS so
              ON so.database_id = d.database_id
            CROSS APPLY
            (
                SELECT
                    max_size_bytes = CONVERT(bigint, DATABASEPROPERTYEX(@db_name, 'MaxSizeInBytes')),
                    optimized_locking = CONVERT(int, DATABASEPROPERTYEX(@db_name, 'IsOptimizedLockingOn')),
                    updateability = CONVERT(nvarchar(30), DATABASEPROPERTYEX(@db_name, 'Updateability'))
            ) AS p
            CROSS APPLY
            (
                VALUES
                    (1, N'edition', so.edition COLLATE DATABASE_DEFAULT, NULL),
                    (2, N'service_objective', so.service_objective COLLATE DATABASE_DEFAULT, NULL),
                    (3, N'elastic_pool', ISNULL(so.elastic_pool_name COLLATE DATABASE_DEFAULT, N'(none)'), NULL),
                    (4, N'max_size_gb',
                        CASE WHEN p.max_size_bytes > 0 THEN CONVERT(nvarchar(30), CONVERT(decimal(19, 1), p.max_size_bytes / 1073741824.0)) ELSE N'no fixed limit' END,
                        CASE WHEN p.max_size_bytes <= 0 THEN N'No fixed max size (Hyperscale storage grows automatically).' END),
                    (5, N'updateability', p.updateability,
                        CASE WHEN p.updateability = N'READ_ONLY' THEN N'Connected to a read-only replica or a read-only database: write activity is elsewhere.' END),
                    (6, N'compatibility_level', CONVERT(nvarchar(10), d.compatibility_level),
                        CASE WHEN d.compatibility_level < 150 THEN N'Older level: intelligent query processing features (batch mode on rowstore, memory grant feedback) are off.' END),
                    (7, N'collation', d.collation_name COLLATE DATABASE_DEFAULT, NULL),
                    (8, N'read_committed_snapshot', CASE WHEN d.is_read_committed_snapshot_on = 1 THEN N'ON' ELSE N'OFF' END,
                        CASE WHEN d.is_read_committed_snapshot_on = 0 THEN N'Readers and writers block each other under READ COMMITTED. The Azure SQL Database default is ON.' END),
                    (9, N'snapshot_isolation', d.snapshot_isolation_state_desc COLLATE DATABASE_DEFAULT, NULL),
                    (10, N'accelerated_database_recovery', CASE WHEN d.is_accelerated_database_recovery_on = 1 THEN N'ON' ELSE N'OFF' END, NULL),
                    (11, N'optimized_locking', CASE p.optimized_locking WHEN 1 THEN N'ON' WHEN 0 THEN N'OFF' ELSE N'unknown' END, NULL),
                    (12, N'auto_create_statistics', CASE WHEN d.is_auto_create_stats_on = 1 THEN N'ON' ELSE N'OFF' END,
                        CASE WHEN d.is_auto_create_stats_on = 0 THEN N'OFF: the optimizer may lack column statistics.' END),
                    (13, N'auto_update_statistics', CASE WHEN d.is_auto_update_stats_on = 1 THEN N'ON' ELSE N'OFF' END,
                        CASE WHEN d.is_auto_update_stats_on = 0 THEN N'OFF: statistics go stale unless a job maintains them.' END),
                    (14, N'auto_update_statistics_async', CASE WHEN d.is_auto_update_stats_async_on = 1 THEN N'ON' ELSE N'OFF' END, NULL),
                    (15, N'parameterization', CASE WHEN d.is_parameterization_forced = 1 THEN N'FORCED' ELSE N'SIMPLE' END,
                        CASE WHEN d.is_parameterization_forced = 1 THEN N'Literals are replaced by parameters, so one cached plan serves many values (watch for parameter-sensitive plans).' END),
                    (16, N'delayed_durability', d.delayed_durability_desc COLLATE DATABASE_DEFAULT,
                        CASE WHEN d.delayed_durability > 0 THEN N'Commits may not be durable: the latest transactions can be lost on failover.' END),
                    (17, N'auto_shrink', CASE WHEN d.is_auto_shrink_on = 1 THEN N'ON' ELSE N'OFF' END,
                        CASE WHEN d.is_auto_shrink_on = 1 THEN N'Auto shrink causes fragmentation and repeated growth. Turn it off.' END),
                    (18, N'page_verify', d.page_verify_option_desc COLLATE DATABASE_DEFAULT, NULL),
                    (19, N'target_recovery_time_s', CONVERT(nvarchar(10), d.target_recovery_time_in_seconds), NULL),
                    (20, N'transparent_data_encryption', CASE WHEN d.is_encrypted = 1 THEN N'ON' ELSE N'OFF' END, NULL),
                    (21, N'change_data_capture', CASE WHEN d.is_cdc_enabled = 1 THEN N'ON' ELSE N'OFF' END, NULL)
            ) AS v (sort_order, setting, value, note)
            WHERE d.database_id = @db_id;
        END TRY
        BEGIN CATCH
            INSERT #messages (msg_type, section, message)
            VALUES ('INFO', N'config', LEFT(N'Database options: ' + ERROR_MESSAGE(), 4000));
        END CATCH;

        BEGIN TRY
            INSERT #cfg (sort_group, sort_order, area, setting, value, value_for_secondary, is_default, note)
            SELECT
                2,
                sc.configuration_id,
                N'scoped configuration',
                sc.name COLLATE DATABASE_DEFAULT,
                CONVERT(nvarchar(4000), sc.value),
                CONVERT(nvarchar(4000), sc.value_for_secondary),
                sc.is_value_default,
                CASE
                    WHEN sc.name = N'MAXDOP' AND TRY_CONVERT(int, sc.value) = 0
                    THEN N'MAXDOP 0 lets one query use every core. The Azure SQL Database default is 8.'
                    WHEN sc.name = N'MAXDOP' AND TRY_CONVERT(int, sc.value) = 1
                    THEN N'Parallelism is disabled for the whole database.'
                    WHEN sc.name = N'LEGACY_CARDINALITY_ESTIMATION' AND TRY_CONVERT(int, sc.value) = 1
                    THEN N'The legacy cardinality estimator is in use.'
                    WHEN sc.name = N'PARAMETER_SNIFFING' AND TRY_CONVERT(int, sc.value) = 0
                    THEN N'Parameter sniffing is disabled: plans are built for average values.'
                    WHEN sc.is_value_default = 0
                    THEN N'Changed from the default.'
                END
            FROM sys.database_scoped_configurations AS sc
            WHERE @slow = 1
            OR    sc.is_value_default = 0
            OR    sc.name IN
                  (
                      N'MAXDOP', N'LEGACY_CARDINALITY_ESTIMATION', N'PARAMETER_SNIFFING', N'QUERY_OPTIMIZER_HOTFIXES',
                      N'OPTIMIZE_FOR_AD_HOC_WORKLOADS', N'PARAMETER_SENSITIVE_PLAN_OPTIMIZATION', N'LAST_QUERY_PLAN_STATS',
                      N'LIGHTWEIGHT_QUERY_PROFILING', N'ELEVATE_ONLINE', N'ELEVATE_RESUMABLE', N'OPTIMIZED_PLAN_FORCING'
                  );
        END TRY
        BEGIN CATCH
            INSERT #messages (msg_type, section, message)
            VALUES ('INFO', N'config', LEFT(N'sys.database_scoped_configurations: ' + ERROR_MESSAGE(), 4000));
        END CATCH;

        BEGIN TRY
            INSERT #cfg (sort_group, sort_order, area, setting, value, note)
            SELECT
                3,
                0,
                N'automatic tuning',
                N'mode',
                CONCAT(m.desired_state_desc, N' (actual ', m.actual_state_desc, N')') COLLATE DATABASE_DEFAULT,
                NULL
            FROM sys.database_automatic_tuning_mode AS m

            UNION ALL

            SELECT
                3,
                ROW_NUMBER() OVER (ORDER BY o.name),
                N'automatic tuning',
                o.name COLLATE DATABASE_DEFAULT,
                CONCAT(o.desired_state_desc, N' (actual ', o.actual_state_desc, N')') COLLATE DATABASE_DEFAULT,
                CASE
                    WHEN o.desired_state IN (0, 1) AND o.desired_state <> o.actual_state
                    THEN CONCAT(N'Desired and actual state differ', N': ' + o.reason_desc COLLATE DATABASE_DEFAULT)
                    WHEN o.name = N'FORCE_LAST_GOOD_PLAN' AND o.actual_state = 0
                    THEN N'Automatic plan correction is OFF: regressed plans are not reverted automatically.'
                END
            FROM sys.database_automatic_tuning_options AS o;
        END TRY
        BEGIN CATCH
            INSERT #messages (msg_type, section, message)
            VALUES ('INFO', N'config', LEFT(N'Automatic tuning options: ' + ERROR_MESSAGE(), 4000));
        END CATCH;

        BEGIN TRY
            INSERT #cfg (sort_group, sort_order, area, setting, value, note)
            SELECT
                4,
                v.sort_order,
                N'query store',
                v.setting,
                v.value,
                v.note
            FROM sys.database_query_store_options AS q
            CROSS APPLY
            (
                SELECT
                    pct_used = CONVERT(decimal(9, 1), 100.0 * q.current_storage_size_mb / NULLIF(q.max_storage_size_mb, 0)),
                    readonly_reasons =
                        ISNULL(STUFF(CONCAT(
                            CASE WHEN q.readonly_reason & 1 = 1 THEN N', the database is read-only' END,
                            CASE WHEN q.readonly_reason & 2 = 2 THEN N', single-user mode' END,
                            CASE WHEN q.readonly_reason & 4 = 4 THEN N', emergency mode' END,
                            CASE WHEN q.readonly_reason & 8 = 8 THEN N', secondary replica' END,
                            CASE WHEN q.readonly_reason & 65536 = 65536 THEN N', MAX_STORAGE_SIZE_MB reached' END,
                            CASE WHEN q.readonly_reason & 131072 = 131072 THEN N', statement count reached the internal memory limit' END,
                            CASE WHEN q.readonly_reason & 262144 = 262144 THEN N', unflushed data reached the internal memory limit' END,
                            CASE WHEN q.readonly_reason & 524288 = 524288 THEN N', the database reached its size limit' END
                        ), 1, 2, N''), CONCAT(N'reason code ', q.readonly_reason))
            ) AS c
            CROSS APPLY
            (
                VALUES
                    (1, N'state', CONCAT(q.desired_state_desc, N' (actual ', q.actual_state_desc, N')') COLLATE DATABASE_DEFAULT,
                        CASE
                            WHEN q.actual_state = 1 AND q.desired_state = 1
                            THEN N'READ_ONLY by configuration: new query data is not captured.'
                            WHEN q.actual_state = 1
                            THEN CONCAT(N'Query Store switched to READ_ONLY (', c.readonly_reasons, N'): new query data is not captured.',
                                        CASE WHEN (q.readonly_reason & 9) <> 0 THEN N' This is expected on a read-only database or replica.' END)
                            WHEN q.actual_state = 0
                            THEN N'Query Store is OFF: no query history for troubleshooting or automatic plan correction.'
                            WHEN q.actual_state = 3
                            THEN CONCAT(N'Query Store is in ERROR state', N': ' + q.actual_state_additional_info COLLATE DATABASE_DEFAULT)
                            WHEN q.desired_state <> q.actual_state
                            THEN N'Desired and actual state differ.'
                        END),
                    (2, N'storage_used_mb', CONCAT(q.current_storage_size_mb, N' of ', q.max_storage_size_mb, N' MB (', c.pct_used, N'%)'),
                        CASE
                            WHEN c.pct_used >= 90 THEN N'90% or more used: size-based cleanup is removing queries, and Query Store becomes READ_ONLY when full.'
                            WHEN c.pct_used >= 80 THEN N'80% or more used: size-based cleanup starts at 90%.'
                        END),
                    (3, N'query_capture_mode', q.query_capture_mode_desc COLLATE DATABASE_DEFAULT,
                        CASE q.query_capture_mode
                            WHEN 1 THEN N'ALL captures every query, including one-off statements, which fills Query Store faster. AUTO is the default.'
                            WHEN 3 THEN N'NONE: new queries are not captured.'
                        END),
                    (4, N'custom_capture_policy',
                        CASE
                            WHEN q.query_capture_mode = 4
                            THEN CONCAT(N'execution_count ', q.capture_policy_execution_count,
                                        N', total_compile_cpu_ms ', q.capture_policy_total_compile_cpu_time_ms,
                                        N', total_execution_cpu_ms ', q.capture_policy_total_execution_cpu_time_ms,
                                        N', stale_threshold_hours ', q.capture_policy_stale_threshold_hours)
                        END, NULL),
                    (5, N'size_based_cleanup_mode', q.size_based_cleanup_mode_desc COLLATE DATABASE_DEFAULT,
                        CASE WHEN q.size_based_cleanup_mode = 0 THEN N'OFF: Query Store becomes READ_ONLY when it is full.' END),
                    (6, N'stale_query_threshold_days', CONVERT(nvarchar(10), q.stale_query_threshold_days), NULL),
                    (7, N'wait_stats_capture_mode', q.wait_stats_capture_mode_desc COLLATE DATABASE_DEFAULT,
                        CASE WHEN q.wait_stats_capture_mode = 0 THEN N'Per-query wait statistics are not captured.' END),
                    (8, N'interval_length_minutes', CONVERT(nvarchar(10), q.interval_length_minutes), NULL),
                    (9, N'flush_interval_seconds', CONVERT(nvarchar(10), q.flush_interval_seconds), NULL),
                    (10, N'max_plans_per_query', CONVERT(nvarchar(10), q.max_plans_per_query), NULL)
            ) AS v (sort_order, setting, value, note)
            WHERE v.value IS NOT NULL;
        END TRY
        BEGIN CATCH
            INSERT #messages (msg_type, section, message)
            VALUES ('INFO', N'config', LEFT(N'sys.database_query_store_options: ' + ERROR_MESSAGE(), 4000));
        END CATCH;

        BEGIN TRY
            SELECT
                rn = ROW_NUMBER() OVER (ORDER BY c.sort_group, c.sort_order, c.setting),
                area = c.area,
                setting = c.setting,
                value = c.value,
                value_for_secondary = c.value_for_secondary,
                is_default = c.is_default,
                note = c.note
            INTO #o_configuration
            FROM #cfg AS c;
        END TRY
        BEGIN CATCH
            UPDATE #emit SET error_message = LEFT(ERROR_MESSAGE(), 4000) WHERE result_key = @rk;
        END CATCH;

        UPDATE #emit SET duration_ms = DATEDIFF_BIG(MILLISECOND, @t0, SYSDATETIME()) WHERE result_key = @rk;

        SELECT
            @rk = N'tuning_recommendations',
            @t0 = SYSDATETIME();

        INSERT #emit (section_order, section_key, result_key, result_name, table_name, empty_message)
        VALUES (1210, N'config', @rk, N'AUTOMATIC TUNING RECOMMENDATIONS (plan regressions and index suggestions from the engine, active first)', N'#o_tuning_recommendations', N'No automatic tuning recommendations (none detected, or Query Store is off).');

        BEGIN TRY
            SELECT TOP (@top_n)
                rn = ROW_NUMBER() OVER (ORDER BY o.state_order, tr.score DESC, tr.last_refresh DESC),
                name = tr.name COLLATE DATABASE_DEFAULT,
                type = tr.type COLLATE DATABASE_DEFAULT,
                state = j.current_state COLLATE DATABASE_DEFAULT,
                state_reason = j.state_reason COLLATE DATABASE_DEFAULT,
                score = tr.score,
                reason =
                    COALESCE
                    (
                        NULLIF(tr.reason, N''),
                        CASE
                            WHEN j.index_table IS NOT NULL
                            THEN CONCAT(j.index_type + N' ', N'index on ', j.index_schema + N'.', j.index_table, N' (', j.index_columns, N')',
                                        N' INCLUDE (' + NULLIF(j.included_columns, N'') + N')')
                        END
                    ) COLLATE DATABASE_DEFAULT,
                object_name = CONCAT(j.index_schema + N'.', j.index_table) COLLATE DATABASE_DEFAULT,
                estimated_size_mb = CASE WHEN j.impact_dimension = N'SpaceChange' THEN CONVERT(decimal(19, 1), j.impact_value) END,
                query_id = j.query_id,
                query_hash = j.query_hash COLLATE DATABASE_DEFAULT,
                regressed_plan_id = j.regressed_plan_id,
                recommended_plan_id = j.recommended_plan_id,
                regressed_avg_cpu_ms = CONVERT(decimal(19, 2), j.regressed_cpu_us / 1000.0),
                recommended_avg_cpu_ms = CONVERT(decimal(19, 2), j.recommended_cpu_us / 1000.0),
                regressed_executions = j.regressed_execs,
                recommended_executions = j.recommended_execs,
                estimated_cpu_saving_s =
                    CONVERT(decimal(19, 1), (ISNULL(j.regressed_execs, 0) + ISNULL(j.recommended_execs, 0)) * (j.regressed_cpu_us - j.recommended_cpu_us) / 1000000.0),
                valid_since = tr.valid_since,
                last_refresh = tr.last_refresh,
                executed_by = NULLIF(tr.execute_action_initiated_by, N'') COLLATE DATABASE_DEFAULT,
                executed_at = CASE WHEN tr.execute_action_start_time > '19000101' THEN tr.execute_action_start_time END,
                reverted_by = NULLIF(tr.revert_action_initiated_by, N'') COLLATE DATABASE_DEFAULT,
                reverted_at = CASE WHEN tr.revert_action_start_time > '19000101' THEN tr.revert_action_start_time END,
                notes =
                    CONCAT(
                        CASE
                            WHEN j.query_id IS NOT NULL
                            THEN
                                CASE j.current_state
                                    WHEN N'Active' THEN CONCAT(N'Plan regression not corrected', N' (' + j.state_reason + N')', N': review the script before forcing the plan manually.')
                                    WHEN N'Verifying' THEN N'The engine forced the last good plan and is verifying the improvement.'
                                    WHEN N'Success' THEN N'The engine forced the last good plan and verified the improvement.'
                                    WHEN N'Reverted' THEN CONCAT(N'Plan forcing was reverted', N' (' + j.state_reason + N')', N'.')
                                    WHEN N'Expired' THEN CONCAT(N'Expired', N' (' + j.state_reason + N')', N'.')
                                END
                            WHEN j.current_state = N'Active'
                            THEN N'Not applied: check overlap with existing indexes and the extra write cost before running the script.'
                            ELSE CONCAT(j.current_state, N' (' + j.state_reason + N')')
                        END,
                        CASE WHEN j.regressed_errors > ISNULL(j.recommended_errors, 0) THEN N' The regressed plan has more errors or timeouts.' END
                    ) COLLATE DATABASE_DEFAULT,
                script = j.script COLLATE DATABASE_DEFAULT
            INTO #o_tuning_recommendations
            FROM sys.dm_db_tuning_recommendations AS tr
            CROSS APPLY
            (
                SELECT
                    current_state = JSON_VALUE(tr.state, '$.currentValue'),
                    state_reason = JSON_VALUE(tr.state, '$.reason'),
                    query_id = TRY_CONVERT(bigint, JSON_VALUE(tr.details, '$.planForceDetails.queryId')),
                    query_hash = JSON_VALUE(tr.details, '$.planForceDetails.queryHash'),
                    regressed_plan_id = TRY_CONVERT(bigint, JSON_VALUE(tr.details, '$.planForceDetails.regressedPlanId')),
                    recommended_plan_id = TRY_CONVERT(bigint, JSON_VALUE(tr.details, '$.planForceDetails.recommendedPlanId')),
                    regressed_cpu_us = TRY_CONVERT(float, JSON_VALUE(tr.details, '$.planForceDetails.regressedPlanCpuTimeAverage')),
                    recommended_cpu_us = TRY_CONVERT(float, JSON_VALUE(tr.details, '$.planForceDetails.recommendedPlanCpuTimeAverage')),
                    regressed_execs = TRY_CONVERT(bigint, JSON_VALUE(tr.details, '$.planForceDetails.regressedPlanExecutionCount')),
                    recommended_execs = TRY_CONVERT(bigint, JSON_VALUE(tr.details, '$.planForceDetails.recommendedPlanExecutionCount')),
                    regressed_errors = TRY_CONVERT(bigint, JSON_VALUE(tr.details, '$.planForceDetails.regressedPlanErrorCount')),
                    recommended_errors = TRY_CONVERT(bigint, JSON_VALUE(tr.details, '$.planForceDetails.recommendedPlanErrorCount')),
                    index_type = COALESCE(JSON_VALUE(tr.details, '$.createIndexDetails.indexType'), JSON_VALUE(tr.details, '$.dropIndexDetails.indexType')),
                    index_schema = COALESCE(JSON_VALUE(tr.details, '$.createIndexDetails.schema'), JSON_VALUE(tr.details, '$.dropIndexDetails.schema')),
                    index_table = COALESCE(JSON_VALUE(tr.details, '$.createIndexDetails.table'), JSON_VALUE(tr.details, '$.dropIndexDetails.table')),
                    index_columns = COALESCE(JSON_VALUE(tr.details, '$.createIndexDetails.indexColumns'), JSON_VALUE(tr.details, '$.dropIndexDetails.indexColumns')),
                    included_columns = COALESCE(JSON_VALUE(tr.details, '$.createIndexDetails.includedColumns'), JSON_VALUE(tr.details, '$.dropIndexDetails.includedColumns')),
                    impact_dimension = JSON_VALUE(tr.details, '$.estimatedImpact[0].dimensionName'),
                    impact_value = TRY_CONVERT(float, JSON_VALUE(tr.details, '$.estimatedImpact[0].absoluteValue')),
                    script = JSON_VALUE(tr.details, '$.implementationDetails.script')
            ) AS j
            CROSS APPLY
            (
                SELECT
                    state_order =
                        CASE j.current_state
                            WHEN N'Active' THEN 1
                            WHEN N'Verifying' THEN 2
                            WHEN N'Success' THEN 3
                            WHEN N'Reverted' THEN 4
                            ELSE 5
                        END
            ) AS o
            ORDER BY
                o.state_order,
                tr.score DESC,
                tr.last_refresh DESC;
        END TRY
        BEGIN CATCH
            UPDATE #emit SET error_message = LEFT(ERROR_MESSAGE(), 4000) WHERE result_key = @rk;
        END CATCH;

        UPDATE #emit SET duration_ms = DATEDIFF_BIG(MILLISECOND, @t0, SYSDATETIME()) WHERE result_key = @rk;

        SELECT
            @rk = N'plan_forcing',
            @t0 = SYSDATETIME();

        INSERT #emit (section_order, section_key, result_key, result_name, table_name, empty_message)
        VALUES (1220, N'config', @rk, N'FORCED PLANS AND QUERY STORE HINTS (those that failed to apply first)', N'#o_plan_forcing', N'No forced plans and no Query Store hints in this database.');

        BEGIN TRY
            SELECT
                rn = t.rn,
                kind = t.kind,
                status = CASE WHEN t.failure_count > 0 THEN CONCAT(N'FAILED ', t.failure_count, N' time(s)') ELSE N'OK' END,
                query_id = t.query_id,
                plan_id = t.plan_id,
                forcing_type = t.forcing_type,
                failure_count = t.failure_count,
                last_failure_reason = NULLIF(t.last_failure_reason, N'NONE'),
                last_execution = CONVERT(datetime, t.last_execution),
                hint_text = t.hint_text,
                notes =
                    CASE
                        WHEN t.failure_count > 0 AND t.kind = N'forced plan'
                        THEN N'The query does not run with the forced plan. Unforce it, or force a plan that still can be built. Usual causes: an index that the plan needs was dropped or changed, or the schema changed.'
                        WHEN t.failure_count > 0
                        THEN N'The hint could not be applied. Clear it or correct it.'
                        WHEN t.forcing_type = N'AUTO'
                        THEN N'Forced by automatic tuning (FORCE_LAST_GOOD_PLAN).'
                    END,
                script =
                    CASE t.kind
                        WHEN N'forced plan' THEN CONCAT(N'EXEC sys.sp_query_store_unforce_plan @query_id = ', t.query_id, N', @plan_id = ', t.plan_id, N';')
                        ELSE CONCAT(N'EXEC sys.sp_query_store_clear_hints @query_id = ', t.query_id, N';')
                    END,
                statement_text = qt.query_sql_text
            INTO #o_plan_forcing
            FROM
            (
                SELECT TOP (@top_n)
                    f.kind,
                    f.query_id,
                    f.plan_id,
                    f.forcing_type,
                    f.failure_count,
                    f.last_failure_reason,
                    f.last_execution,
                    f.hint_text,
                    rn = ROW_NUMBER() OVER (ORDER BY CASE WHEN f.failure_count > 0 THEN 0 ELSE 1 END, f.failure_count DESC, f.last_execution DESC, f.query_id, f.plan_id)
                FROM #forcing AS f
                ORDER BY
                    rn
            ) AS t
            LEFT JOIN sys.query_store_query AS q
              ON q.query_id = t.query_id
            LEFT JOIN sys.query_store_query_text AS qt
              ON qt.query_text_id = q.query_text_id;
        END TRY
        BEGIN CATCH
            UPDATE #emit SET error_message = LEFT(ERROR_MESSAGE(), 4000) WHERE result_key = @rk;
        END CATCH;

        UPDATE #emit SET duration_ms = DATEDIFF_BIG(MILLISECOND, @t0, SYSDATETIME()) WHERE result_key = @rk;
    END;

    /* ============================================================================================
       1010 query_store_top, 1020 query_store_waits (slow)
       ============================================================================================ */
    IF @do_querystore = 1
    BEGIN
        SELECT
            @rk = N'query_store_top',
            @t0 = SYSDATETIME();

        INSERT #emit (section_order, section_key, result_key, result_name, table_name, empty_message)
        VALUES (1010, N'querystore', @rk, CONCAT(N'QUERY STORE TOP QUERIES (by CPU, reads and duration; Query Store intervals overlapping the last ', @lookback_minutes, N' minutes)'), N'#o_query_store_top', N'No Query Store runtime statistics in the window (Query Store may be OFF or not capturing).');

        CREATE TABLE #qsp
        (
            query_id bigint NOT NULL,
            plan_id bigint NOT NULL,
            executions bigint NULL,
            cpu_us float NULL,
            duration_us float NULL,
            max_duration_us bigint NULL,
            min_cpu_us bigint NULL,
            max_cpu_us bigint NULL,
            logical_reads float NULL,
            physical_reads float NULL,
            page_server_reads float NULL,
            writes float NULL,
            rows_returned float NULL,
            max_memory_pages bigint NULL,
            max_tempdb_pages bigint NULL,
            log_bytes float NULL,
            max_dop bigint NULL,
            aborted bigint NULL,
            exceptions bigint NULL,
            last_execution datetimeoffset(7) NULL,
            PRIMARY KEY (query_id, plan_id)
        );

        BEGIN TRY
            INSERT #qsp
            (
                query_id, plan_id, executions, cpu_us, duration_us, max_duration_us, min_cpu_us, max_cpu_us, logical_reads, physical_reads,
                page_server_reads, writes, rows_returned, max_memory_pages, max_tempdb_pages, log_bytes, max_dop,
                aborted, exceptions, last_execution
            )
            SELECT
                p.query_id,
                rs.plan_id,
                SUM(rs.count_executions),
                SUM(rs.avg_cpu_time * rs.count_executions),
                SUM(rs.avg_duration * rs.count_executions),
                MAX(rs.max_duration),
                MIN(rs.min_cpu_time),
                MAX(rs.max_cpu_time),
                SUM(rs.avg_logical_io_reads * rs.count_executions),
                SUM(rs.avg_physical_io_reads * rs.count_executions),
                SUM(rs.avg_page_server_io_reads * rs.count_executions),
                SUM(rs.avg_logical_io_writes * rs.count_executions),
                SUM(rs.avg_rowcount * rs.count_executions),
                MAX(rs.max_query_max_used_memory),
                MAX(rs.max_tempdb_space_used),
                SUM(rs.avg_log_bytes_used * rs.count_executions),
                MAX(rs.max_dop),
                SUM(CASE WHEN rs.execution_type = 3 THEN rs.count_executions ELSE 0 END),
                SUM(CASE WHEN rs.execution_type = 4 THEN rs.count_executions ELSE 0 END),
                MAX(rs.last_execution_time)
            FROM sys.query_store_runtime_stats_interval AS rsi
            JOIN sys.query_store_runtime_stats AS rs
              ON rs.runtime_stats_interval_id = rsi.runtime_stats_interval_id
            JOIN sys.query_store_plan AS p
              ON p.plan_id = rs.plan_id
            WHERE rsi.end_time > @window_start_dto
            GROUP BY
                p.query_id,
                rs.plan_id;

            WITH
                agg AS
                (
                    SELECT
                        p.query_id,
                        executions = SUM(p.executions),
                        cpu_us = SUM(p.cpu_us),
                        duration_us = SUM(p.duration_us),
                        max_duration_us = MAX(p.max_duration_us),
                        logical_reads = SUM(p.logical_reads),
                        physical_reads = SUM(p.physical_reads),
                        page_server_reads = SUM(p.page_server_reads),
                        writes = SUM(p.writes),
                        rows_returned = SUM(p.rows_returned),
                        max_memory_pages = MAX(p.max_memory_pages),
                        max_tempdb_pages = MAX(p.max_tempdb_pages),
                        log_bytes = SUM(p.log_bytes),
                        max_dop = MAX(p.max_dop),
                        aborted = SUM(p.aborted),
                        exceptions = SUM(p.exceptions),
                        last_execution = MAX(p.last_execution),
                        plans = COUNT(*),
                        best_plan_avg_cpu_us = MIN(CASE WHEN p.executions >= 5 THEN p.cpu_us / p.executions END),
                        worst_plan_avg_cpu_us = MAX(CASE WHEN p.executions >= 5 THEN p.cpu_us / p.executions END),
                        /* One plan whose CPU differs more than 10 times its average between executions, 100 ms or more at the top */
                        vary_min_cpu_us = MIN(CASE WHEN p.executions >= 10 AND p.max_cpu_us >= 100000 AND (p.max_cpu_us - p.min_cpu_us) > 10 * (p.cpu_us / p.executions) THEN p.min_cpu_us END),
                        vary_max_cpu_us = MAX(CASE WHEN p.executions >= 10 AND p.max_cpu_us >= 100000 AND (p.max_cpu_us - p.min_cpu_us) > 10 * (p.cpu_us / p.executions) THEN p.max_cpu_us END)
                    FROM #qsp AS p
                    GROUP BY
                        p.query_id
                ),
                ranked AS
                (
                    SELECT
                        agg.*,
                        cpu_rank = ROW_NUMBER() OVER (ORDER BY agg.cpu_us DESC),
                        reads_rank = ROW_NUMBER() OVER (ORDER BY agg.logical_reads DESC),
                        duration_rank = ROW_NUMBER() OVER (ORDER BY agg.duration_us DESC),
                        all_cpu_us = SUM(agg.cpu_us) OVER (),
                        all_reads = SUM(agg.logical_reads) OVER ()
                    FROM agg
                )
            SELECT
                rn = ROW_NUMBER() OVER (ORDER BY br.best_rank, r.cpu_rank),
                ranked_by =
                    ISNULL(STUFF(CONCAT(
                        CASE WHEN r.cpu_rank <= @top_n THEN CONCAT(N', cpu #', r.cpu_rank) END,
                        CASE WHEN r.reads_rank <= @top_n THEN CONCAT(N', reads #', r.reads_rank) END,
                        CASE WHEN r.duration_rank <= @top_n THEN CONCAT(N', duration #', r.duration_rank) END), 1, 2, N''), N''),
                query_id = r.query_id,
                module_name = mo.module_name,
                query_hash = CONVERT(varchar(20), q.query_hash, 1),
                executions = r.executions,
                cpu_ms = CONVERT(bigint, r.cpu_us / 1000.0),
                pct_of_cpu = CONVERT(decimal(9, 1), 100.0 * r.cpu_us / NULLIF(r.all_cpu_us, 0)),
                avg_cpu_ms = CONVERT(decimal(19, 2), r.cpu_us / 1000.0 / NULLIF(r.executions, 0)),
                duration_ms = CONVERT(bigint, r.duration_us / 1000.0),
                avg_duration_ms = CONVERT(decimal(19, 2), r.duration_us / 1000.0 / NULLIF(r.executions, 0)),
                max_duration_ms = r.max_duration_us / 1000,
                logical_reads = CONVERT(bigint, r.logical_reads),
                pct_of_reads = CONVERT(decimal(9, 1), 100.0 * r.logical_reads / NULLIF(r.all_reads, 0)),
                avg_logical_reads = CONVERT(bigint, r.logical_reads / NULLIF(r.executions, 0)),
                physical_reads = CONVERT(bigint, r.physical_reads),
                page_server_reads = CONVERT(bigint, r.page_server_reads),
                writes = CONVERT(bigint, r.writes),
                avg_rows = CONVERT(bigint, r.rows_returned / NULLIF(r.executions, 0)),
                max_memory_mb = CONVERT(decimal(19, 1), r.max_memory_pages * 8 / 1024.0),
                max_tempdb_mb = CONVERT(decimal(19, 1), r.max_tempdb_pages * 8 / 1024.0),
                log_mb = CONVERT(decimal(19, 1), r.log_bytes / 1048576.0),
                max_dop = r.max_dop,
                plans = r.plans,
                plan_cpu_spread = CONVERT(decimal(19, 1), r.worst_plan_avg_cpu_us / NULLIF(r.best_plan_avg_cpu_us, 0)),
                forced_plan_id = fp.plan_id,
                aborted = r.aborted,
                exceptions = r.exceptions,
                last_execution = CONVERT(datetime, r.last_execution),
                notes =
                    ISNULL(STUFF(CONCAT(
                        CASE
                            WHEN q.is_internal_query = 1 AND qt.query_sql_text LIKE N'%StatMan(%' THEN N'; internal statistics update (auto or manual UPDATE STATISTICS)'
                            WHEN q.is_internal_query = 1 THEN N'; internal query'
                        END,
                        CASE WHEN r.worst_plan_avg_cpu_us >= 2 * r.best_plan_avg_cpu_us THEN N'; plans differ a lot in CPU (parameter sensitivity?)' END,
                        CASE
                            WHEN r.vary_max_cpu_us IS NOT NULL
                            THEN CONCAT(N'; CPU of one plan ranges from ', CONVERT(decimal(19, 1), r.vary_min_cpu_us / 1000.0), N' ms to ', CONVERT(decimal(19, 1), r.vary_max_cpu_us / 1000.0), N' ms between executions (one plan for very different parameter values?)')
                        END,
                        CASE WHEN fp.plan_id IS NOT NULL THEN CONCAT(N'; plan forced', N' (forcing failures: ' + NULLIF(CONCAT(fp.force_failure_count, N', ', fp.last_force_failure_reason_desc COLLATE DATABASE_DEFAULT), N'0, NONE') + N')') END,
                        CASE WHEN r.aborted > 0 THEN CONCAT(N'; ', r.aborted, N' aborted (timeout or cancel)') END,
                        CASE WHEN r.exceptions > 0 THEN CONCAT(N'; ', r.exceptions, N' failed with an error') END,
                        CASE WHEN r.max_memory_pages >= 131072 THEN N'; used 1 GB or more of memory grant' END,
                        CASE WHEN r.max_tempdb_pages >= 131072 THEN N'; used 1 GB or more of tempdb' END,
                        CASE WHEN @is_hyperscale = 1 AND r.logical_reads >= 100000 AND r.page_server_reads * 2 >= r.logical_reads THEN N'; most reads came from page servers (data not in the local cache)' END,
                        CASE WHEN ISNULL(r.max_dop, 1) <= 1 AND r.cpu_us > 0 AND r.duration_us > 3 * r.cpu_us THEN N'; mostly waiting (see query_store_waits)' END
                    ), 1, 2, N''), N''),
                top_plan_id = tp.plan_id,
                statement_text = qt.query_sql_text,
                query_plan = qp.query_plan
            INTO #o_query_store_top
            FROM ranked AS r
            CROSS APPLY
            (
                SELECT
                    best_rank = MIN(v.x)
                FROM (VALUES (r.cpu_rank), (r.reads_rank), (r.duration_rank)) AS v (x)
            ) AS br
            LEFT JOIN sys.query_store_query AS q
              ON q.query_id = r.query_id
            LEFT JOIN sys.query_store_query_text AS qt
              ON qt.query_text_id = q.query_text_id
            OUTER APPLY
            (
                SELECT TOP (1)
                    p.plan_id
                FROM #qsp AS p
                WHERE p.query_id = r.query_id
                ORDER BY
                    p.cpu_us DESC
            ) AS tp
            OUTER APPLY
            (
                SELECT TOP (1)
                    f.plan_id,
                    f.force_failure_count,
                    f.last_force_failure_reason_desc
                FROM sys.query_store_plan AS f
                WHERE f.query_id = r.query_id
                AND   f.is_forced_plan = 1
            ) AS fp
            OUTER APPLY
            (
                SELECT
                    module_name = QUOTENAME(sc.name) + N'.' + QUOTENAME(o.name)
                FROM sys.objects AS o
                JOIN sys.schemas AS sc
                  ON sc.schema_id = o.schema_id
                WHERE o.object_id = q.object_id
                AND   q.object_id > 0
            ) AS mo
            OUTER APPLY
            (
                SELECT
                    query_plan = TRY_CONVERT(xml, pp.query_plan)
                FROM sys.query_store_plan AS pp
                WHERE pp.plan_id = tp.plan_id
                AND   @include_plans = 1
            ) AS qp
            WHERE r.cpu_rank <= @top_n
            OR    r.reads_rank <= @top_n
            OR    r.duration_rank <= @top_n;

            IF @include_plans = 0
                ALTER TABLE #o_query_store_top DROP COLUMN query_plan;
        END TRY
        BEGIN CATCH
            UPDATE #emit SET error_message = LEFT(ERROR_MESSAGE(), 4000) WHERE result_key = @rk;
        END CATCH;

        UPDATE #emit SET duration_ms = DATEDIFF_BIG(MILLISECOND, @t0, SYSDATETIME()) WHERE result_key = @rk;

        /* ---- 1020 query_store_waits: what the queries in the window waited on (wait_stats_capture_mode = ON) ---- */
        DECLARE
            @qs_from datetimeoffset(7) = NULL,
            @qs_covered_s bigint = NULL;

        SELECT
            @rk = N'query_store_waits',
            @t0 = SYSDATETIME();

        INSERT #emit (section_order, section_key, result_key, result_name, table_name, empty_message)
        VALUES (1020, N'querystore', @rk, CONCAT(N'QUERY STORE WAITS BY CATEGORY (what queries waited on; Query Store intervals overlapping the last ', @lookback_minutes, N' minutes)'), N'#o_query_store_waits', N'No Query Store wait statistics in the window (wait statistics capture may be OFF; see configuration).');

        BEGIN TRY
            SELECT
                @qs_from = MIN(rsi.start_time)
            FROM sys.query_store_runtime_stats_interval AS rsi
            WHERE rsi.end_time > @window_start_dto;

            SET @qs_covered_s = NULLIF(DATEDIFF_BIG(SECOND, @qs_from, SYSDATETIMEOFFSET()), 0);

            IF @qs_from IS NOT NULL
                UPDATE #emit
                SET result_name = CONCAT(result_name, N' [intervals from ', CONVERT(nvarchar(19), CONVERT(datetime2(0), @qs_from), 120), N' UTC]')
                WHERE result_key IN (N'query_store_top', N'query_store_waits');

            WITH
                w AS
                (
                    SELECT
                        ws.wait_category,
                        wait_category_desc = MAX(ws.wait_category_desc),
                        p.query_id,
                        wait_ms = SUM(ws.total_query_wait_time_ms),
                        max_wait_ms = MAX(ws.max_query_wait_time_ms)
                    FROM sys.query_store_runtime_stats_interval AS rsi
                    JOIN sys.query_store_wait_stats AS ws
                      ON ws.runtime_stats_interval_id = rsi.runtime_stats_interval_id
                    JOIN sys.query_store_plan AS p
                      ON p.plan_id = ws.plan_id
                    WHERE rsi.end_time > @window_start_dto
                    AND   ws.wait_category <> 11 /* Idle */
                    GROUP BY
                        ws.wait_category,
                        p.query_id
                ),
                r AS
                (
                    SELECT
                        w.wait_category,
                        w.wait_category_desc,
                        w.query_id,
                        w.wait_ms,
                        w.max_wait_ms,
                        qrn = ROW_NUMBER() OVER (PARTITION BY w.wait_category ORDER BY w.wait_ms DESC)
                    FROM w
                ),
                c AS
                (
                    SELECT
                        r.wait_category,
                        wait_category_desc = MAX(r.wait_category_desc),
                        wait_ms = SUM(r.wait_ms),
                        max_wait_ms = MAX(r.max_wait_ms),
                        queries = COUNT(*),
                        top_queries =
                            STRING_AGG(CASE WHEN r.qrn <= 3 THEN CONCAT(r.query_id, N' (', CONVERT(decimal(19, 1), r.wait_ms / 1000.0), N' s)') END, N', ')
                                WITHIN GROUP (ORDER BY r.qrn)
                    FROM r
                    GROUP BY
                        r.wait_category
                )
            SELECT
                rn = ROW_NUMBER() OVER (ORDER BY c.wait_ms DESC),
                wait_category = c.wait_category_desc COLLATE DATABASE_DEFAULT,
                wait_s = CONVERT(decimal(19, 1), c.wait_ms / 1000.0),
                pct_of_waits = CONVERT(decimal(9, 1), 100.0 * c.wait_ms / NULLIF(SUM(c.wait_ms) OVER (), 0)),
                avg_queries_waiting = CONVERT(decimal(19, 2), c.wait_ms / 1000.0 / @qs_covered_s),
                max_wait_per_execution_s = CONVERT(decimal(19, 1), c.max_wait_ms / 1000.0),
                queries = c.queries,
                top_query_ids = c.top_queries,
                explanation =
                    CONCAT
                    (
                        CASE c.wait_category
                            WHEN 0 THEN N'Waits that Query Store does not categorize.'
                            WHEN 1 THEN N'Runnable and waiting for a CPU (SOS_SCHEDULER_YIELD): CPU pressure. Tune the top CPU queries or add vCores.'
                            WHEN 2 THEN N'Waiting for a worker thread (THREADPOOL): too many concurrent requests, often caused by blocking or parallel queries.'
                            WHEN 3 THEN N'Blocked by locks held by other sessions. See the blocking results; keep transactions short and index the rows being changed.'
                            WHEN 4 THEN N'Internal (non-page) latches, such as parallel scan or allocation structures.'
                            WHEN 5 THEN N'Contention on pages already in memory (PAGELATCH), such as last-page inserts on ascending keys or tempdb allocation pages.'
                            WHEN 6 THEN N'Reading data pages from storage (PAGEIOLATCH): the data is not in memory. Reduce reads with better indexes or queries, or use a larger service objective for more memory.'
                            WHEN 7 THEN N'Waiting for compile memory (RESOURCE_SEMAPHORE_QUERY_COMPILE): many large compilations at once. Parameterize ad hoc queries.'
                            WHEN 8 THEN N'Running SQL CLR code.'
                            WHEN 9 THEN N'Database mirroring.'
                            WHEN 10 THEN N'Transaction management (XACT, DTC, TRANSACTION_MUTEX): distributed or very many concurrent transactions.'
                            WHEN 12 THEN N'Calls outside SQL Server (OS, external data, authentication). The query does not use SQL Server CPU while it waits.'
                            WHEN 13 THEN N'Service Broker.'
                            WHEN 14 THEN N'Writing the transaction log (WRITELOG, LOGBUFFER): many small commits or large writes. Batch small transactions; check log_write_pct.'
                            WHEN 15 THEN N'The client reads results slowly (ASYNC_NETWORK_IO): row-by-row processing in the application or a slow network. Not a database resource problem.'
                            WHEN 16 THEN N'Parallel threads waiting for each other (CXPACKET, CXCONSUMER): usually large scans or uneven parallel work. Tune those queries or review MAXDOP.'
                            WHEN 17 THEN N'Waiting for memory grants or memory allocations (RESOURCE_SEMAPHORE): large sorts and hashes. See memory_grants; tune queries with large grants.'
                            WHEN 18 THEN N'WAITFOR or similar in application code: not a resource problem.'
                            WHEN 19 THEN N'Trace or Extended Events overhead.'
                            WHEN 20 THEN N'Full-text search.'
                            WHEN 21 THEN N'Non-page IO (IO_COMPLETION, ASYNC_IO_COMPLETION): spills to tempdb, sorts, file growth or bulk operations.'
                            WHEN 22 THEN N'Replica and log transport waits (HADR_*): high write volume with replicas or geo-replication.'
                            WHEN 23 THEN N'Throttled by the service objective log rate limit: the workload writes log faster than the tier allows. Batch writes, reduce index maintenance, or scale up.'
                            ELSE N''
                        END,
                        CASE WHEN c.wait_category = 6 AND @is_hyperscale = 1 THEN N' On Hyperscale these reads come from the local SSD cache or remote page servers.' END
                    )
            INTO #o_query_store_waits
            FROM c;
        END TRY
        BEGIN CATCH
            UPDATE #emit SET error_message = LEFT(ERROR_MESSAGE(), 4000) WHERE result_key = @rk;
        END CATCH;

        UPDATE #emit SET duration_ms = DATEDIFF_BIG(MILLISECOND, @t0, SYSDATETIME()) WHERE result_key = @rk;
    END;

    /* ============================================================================================
       210 blocking_history (slow): blocked_process_report events from running database Extended
       Events sessions with a ring_buffer target. Blocking that has ended is in no DMV, so this is
       the only way to answer "what blocked us ten minutes ago". The service raises a report only
       when a block lasts longer than its blocked process threshold, and repeats it while the
       block lasts: the reports of one block are shown as one row.
       ============================================================================================ */
    DECLARE
        @bh_sessions nvarchar(4000) = NULL,
        @bh_count int = NULL,
        @bh_worst nvarchar(600) = NULL;

    IF @do_blocking = 1 AND @slow = 1
    BEGIN
        SELECT
            @rk = N'blocking_history',
            @t0 = SYSDATETIME();

        INSERT #emit (section_order, section_key, result_key, result_name, table_name, empty_message)
        VALUES (210, N'blocking', @rk, CONCAT(N'BLOCKING HISTORY (last ', @lookback_minutes, N' minutes, times in UTC; blocked process reports from database Extended Events sessions with a ring_buffer target)'), N'#o_blocking_history', N'No blocked process report captured in the window. See the messages for the Extended Events session that was read, or how to create one.');

        CREATE TABLE #bh
        (
            bh_id int IDENTITY(1, 1) NOT NULL PRIMARY KEY,
            session_name nvarchar(128) NOT NULL,
            event_time_utc datetime2(3) NULL,
            report xml NULL
        );

        BEGIN TRY
            SELECT
                @bh_sessions = LEFT(STRING_AGG(CONVERT(nvarchar(max), QUOTENAME(s.name)), N', '), 4000)
            FROM sys.dm_xe_database_sessions AS s
            WHERE EXISTS
            (
                SELECT
                    1
                FROM sys.dm_xe_database_session_events AS e
                WHERE CONVERT(binary(8), e.event_session_address) = CONVERT(binary(8), s.address)
                AND   e.event_name = N'blocked_process_report'
            )
            AND EXISTS
            (
                SELECT
                    1
                FROM sys.dm_xe_database_session_targets AS t
                WHERE CONVERT(binary(8), t.event_session_address) = CONVERT(binary(8), s.address)
                AND   t.target_name = N'ring_buffer'
            );

            IF @bh_sessions IS NULL
            BEGIN
                INSERT #messages (msg_type, section, message)
                VALUES
                (
                    'INFO', N'blocking',
                    N'No running database Extended Events session with a ring_buffer target captures blocked process reports, so blocking that has ended cannot be shown. To capture them (up to 4 MB of memory; keeps the most recent events): '
                    + N'CREATE EVENT SESSION [blocking] ON DATABASE ADD EVENT sqlserver.blocked_process_report ADD TARGET package0.ring_buffer WITH (STARTUP_STATE = ON, MAX_MEMORY = 4 MB); '
                    + N'ALTER EVENT SESSION [blocking] ON DATABASE STATE = START;'
                );
            END
            ELSE
            BEGIN
                INSERT #bh (session_name, event_time_utc, report)
                SELECT
                    s.name,
                    en.n.value('(@timestamp)[1]', 'datetime2(3)'),
                    en.n.query('(data[@name="blocked_process"]/value/blocked-process-report)[1]')
                FROM sys.dm_xe_database_sessions AS s
                JOIN sys.dm_xe_database_session_targets AS t
                  ON CONVERT(binary(8), t.event_session_address) = CONVERT(binary(8), s.address)
                CROSS APPLY (SELECT target_xml = TRY_CONVERT(xml, t.target_data)) AS tx
                CROSS APPLY tx.target_xml.nodes('/RingBufferTarget/event[@name="blocked_process_report"]') AS en (n)
                WHERE t.target_name = N'ring_buffer';

                DELETE #bh
                WHERE event_time_utc IS NULL
                OR    event_time_utc < DATEADD(MINUTE, -@lookback_minutes, CONVERT(datetime2(3), @now_utc));

                /* One row per report */
                SELECT
                    b.bh_id,
                    b.session_name,
                    b.event_time_utc,
                    blocked_spid = bd.n.value('@spid', 'int'),
                    blocked_batch_started = bd.n.value('@lastbatchstarted', 'nvarchar(40)'),
                    wait_ms = bd.n.value('@waittime', 'bigint'),
                    lock_mode = bd.n.value('@lockMode', 'nvarchar(20)'),
                    wait_resource = bd.n.value('@waitresource', 'nvarchar(512)'),
                    blocked_isolation = bd.n.value('@isolationlevel', 'nvarchar(100)'),
                    blocked_app = bd.n.value('@clientapp', 'nvarchar(256)'),
                    blocked_host = bd.n.value('@hostname', 'nvarchar(256)'),
                    blocked_login = bd.n.value('@loginname', 'nvarchar(256)'),
                    blocked_input = bd.n.value('(inputbuf/text())[1]', 'nvarchar(max)'),
                    blocking_spid = bg.n.value('@spid', 'int'),
                    blocking_status = bg.n.value('@status', 'nvarchar(30)'),
                    blocking_trancount = bg.n.value('@trancount', 'int'),
                    blocking_isolation = bg.n.value('@isolationlevel', 'nvarchar(100)'),
                    blocking_app = bg.n.value('@clientapp', 'nvarchar(256)'),
                    blocking_host = bg.n.value('@hostname', 'nvarchar(256)'),
                    blocking_login = bg.n.value('@loginname', 'nvarchar(256)'),
                    blocking_input = bg.n.value('(inputbuf/text())[1]', 'nvarchar(max)')
                INTO #bh_rows
                FROM #bh AS b
                OUTER APPLY b.report.nodes('/blocked-process-report/blocked-process/process') AS bd (n)
                OUTER APPLY b.report.nodes('/blocked-process-report/blocking-process/process') AS bg (n);

                /* The reports of one block (same waiter, blocker and batch of the waiter) as one row: the last and longest */
                WITH
                    e AS
                    (
                        SELECT
                            r.*,
                            rnk = ROW_NUMBER() OVER (PARTITION BY r.blocked_spid, r.blocking_spid, r.blocked_batch_started ORDER BY r.wait_ms DESC, r.bh_id DESC),
                            reports = COUNT(*) OVER (PARTITION BY r.blocked_spid, r.blocking_spid, r.blocked_batch_started),
                            first_report_utc = MIN(r.event_time_utc) OVER (PARTITION BY r.blocked_spid, r.blocking_spid, r.blocked_batch_started)
                        FROM #bh_rows AS r
                        WHERE r.blocked_spid IS NOT NULL
                    )
                SELECT TOP (@top_n)
                    rn = ROW_NUMBER() OVER (ORDER BY e.event_time_utc DESC, e.bh_id DESC),
                    last_report_utc = CONVERT(datetime2(0), e.event_time_utc),
                    minutes_ago = DATEDIFF(MINUTE, e.event_time_utc, CONVERT(datetime2(3), @now_utc)),
                    blocked_session_id = e.blocked_spid,
                    blocking_session_id = e.blocking_spid,
                    blocked_for_s = CONVERT(decimal(19, 1), e.wait_ms / 1000.0),
                    reports = e.reports,
                    first_report_utc = CONVERT(datetime2(0), e.first_report_utc),
                    lock_mode = e.lock_mode,
                    wait_resource = e.wait_resource,
                    blocking_status = e.blocking_status,
                    blocking_open_transactions = e.blocking_trancount,
                    blocked_isolation_level = e.blocked_isolation,
                    blocking_isolation_level = e.blocking_isolation,
                    blocked_app = e.blocked_app,
                    blocked_host = e.blocked_host,
                    blocked_login = e.blocked_login,
                    blocking_app = e.blocking_app,
                    blocking_host = e.blocking_host,
                    blocking_login = e.blocking_login,
                    notes =
                        ISNULL(STUFF(CONCAT(
                            CASE WHEN e.blocking_status = N'sleeping' THEN N'; the blocker was idle with an open transaction: the application did not commit' END,
                            CASE WHEN e.blocking_isolation LIKE N'%serializable%' OR e.blocking_isolation LIKE N'%repeatable%' THEN N'; the blocker ran at REPEATABLE READ or SERIALIZABLE' END,
                            CASE WHEN e.lock_mode IN (N'S', N'IS') THEN N'; a reader was blocked by a writer' END,
                            CASE WHEN e.wait_resource LIKE N'%COMPILE%' THEN N'; compile lock' END,
                            CASE WHEN e.blocked_spid = e.blocking_spid THEN N'; a parallel query that waited on its own threads' END
                        ), 1, 2, N''), N''),
                    xe_session = e.session_name,
                    blocked_input_buffer_text = LTRIM(RTRIM(e.blocked_input)),
                    blocking_input_buffer_text = LTRIM(RTRIM(e.blocking_input))
                INTO #o_blocking_history
                FROM e
                WHERE e.rnk = 1
                ORDER BY
                    e.event_time_utc DESC,
                    e.bh_id DESC;

                SELECT
                    @bh_count = COUNT(*)
                FROM #o_blocking_history;

                SELECT TOP (1)
                    @bh_worst =
                        LEFT
                        (
                            CONCAT
                            (
                                N'longest: session ', h.blocked_session_id, N' was blocked by session ', h.blocking_session_id, N' for ', h.blocked_for_s, N' s, ',
                                h.minutes_ago, N' min ago; blocker ', ISNULL(h.blocking_status, N'n/a'), N', ', ISNULL(h.blocking_login, N'n/a'), N' (' + h.blocking_app + N')'
                            ),
                            600
                        )
                FROM #o_blocking_history AS h
                ORDER BY
                    h.blocked_for_s DESC;

                INSERT #messages (msg_type, section, message)
                VALUES
                (
                    'INFO', N'blocking',
                    LEFT(CONCAT(N'Blocked process reports read from ', @bh_sessions, N': ', @bh_count, N' block(s) in the last ', @lookback_minutes,
                        N' minutes. A ring_buffer keeps only the most recent events (bounded by its MAX_MEMORY), so older reports may be gone.'), 4000)
                );
            END;
        END TRY
        BEGIN CATCH
            UPDATE #emit SET error_message = LEFT(ERROR_MESSAGE(), 4000) WHERE result_key = @rk;
        END CATCH;

        UPDATE #emit SET duration_ms = DATEDIFF_BIG(MILLISECOND, @t0, SYSDATETIME()) WHERE result_key = @rk;
    END;

    /* ============================================================================================
       1300 deadlocks (slow): database_xml_deadlock_report events from running database Extended
       Events sessions with a ring_buffer target. A user database cannot read Azure's own deadlock
       telemetry, so without such a session the messages explain how to create one.
       ============================================================================================ */
    DECLARE
        @deadlock_count int = NULL,
        @stats_recent int = NULL,
        @stats_recent_list nvarchar(1600) = NULL,
        @dl_sessions nvarchar(4000) = NULL,
        @dl_total int = 0,
        @dl_latest datetime2(3) = NULL,
        @crlf nvarchar(2) = NCHAR(13) + NCHAR(10),
        @dl_sep nvarchar(4) = NCHAR(13) + NCHAR(10) + NCHAR(13) + NCHAR(10);

    IF @do_deadlocks = 1
    BEGIN
        SELECT
            @rk = N'deadlocks',
            @t0 = SYSDATETIME();

        INSERT #emit (section_order, section_key, result_key, result_name, table_name, empty_message)
        VALUES (1300, N'deadlocks', @rk, CONCAT(N'DEADLOCKS (last ', @lookback_minutes, N' minutes, times in UTC; from database Extended Events sessions with a ring_buffer target)'), N'#o_deadlocks', N'No deadlocks captured in the window. See the messages for the Extended Events session that was read, or how to create one.');

        CREATE TABLE #dl
        (
            dl_id int IDENTITY(1, 1) NOT NULL PRIMARY KEY,
            session_name nvarchar(128) NOT NULL,
            event_time_utc datetime2(3) NULL,
            deadlock_cycle_id bigint NULL,
            deadlock_graph xml NULL
        );

        CREATE TABLE #dl_proc
        (
            dl_id int NOT NULL,
            spid int NULL,
            is_victim bit NULL,
            app nvarchar(256) NULL,
            host nvarchar(256) NULL,
            login_name nvarchar(256) NULL,
            isolation_level nvarchar(100) NULL,
            lock_mode nvarchar(20) NULL,
            wait_resource nvarchar(512) NULL,
            proc_name nvarchar(512) NULL,
            input_buffer nvarchar(max) NULL
        );

        CREATE TABLE #dl_res
        (
            dl_id int NOT NULL,
            resource_type nvarchar(60) NULL,
            object_name nvarchar(512) NULL,
            index_name nvarchar(256) NULL
        );

        CREATE TABLE #dl_attr
        (
            dl_id int NOT NULL,
            attr nvarchar(20) NOT NULL,
            value nvarchar(800) NOT NULL
        );

        BEGIN TRY
            SELECT
                @dl_sessions = LEFT(STRING_AGG(CONVERT(nvarchar(max), QUOTENAME(s.name)), N', '), 4000)
            FROM sys.dm_xe_database_sessions AS s
            WHERE EXISTS
            (
                SELECT
                    1
                FROM sys.dm_xe_database_session_events AS e
                WHERE CONVERT(binary(8), e.event_session_address) = CONVERT(binary(8), s.address)
                AND   e.event_name = N'database_xml_deadlock_report'
            )
            AND EXISTS
            (
                SELECT
                    1
                FROM sys.dm_xe_database_session_targets AS t
                WHERE CONVERT(binary(8), t.event_session_address) = CONVERT(binary(8), s.address)
                AND   t.target_name = N'ring_buffer'
            );

            IF @dl_sessions IS NULL
            BEGIN
                SELECT
                    @msg =
                        LEFT(STRING_AGG(CONVERT(nvarchar(max), CONCAT(QUOTENAME(des.name),
                            CASE
                                WHEN ds.name IS NULL THEN N' is stopped (start it with ALTER EVENT SESSION ' + QUOTENAME(des.name) + N' ON DATABASE STATE = START;)'
                                ELSE N' is running without a ring_buffer target (this procedure does not read event_file targets)'
                            END)), N'; '), 4000)
                FROM sys.database_event_sessions AS des
                LEFT JOIN sys.dm_xe_database_sessions AS ds
                  ON ds.name COLLATE DATABASE_DEFAULT = des.name COLLATE DATABASE_DEFAULT
                WHERE EXISTS
                (
                    SELECT
                        1
                    FROM sys.database_event_session_events AS e
                    WHERE e.event_session_id = des.event_session_id
                    AND   e.name = N'database_xml_deadlock_report'
                );

                INSERT #messages (msg_type, section, message)
                VALUES
                (
                    'INFO', N'deadlocks',
                    LEFT
                    (
                        CASE
                            WHEN @msg IS NOT NULL
                            THEN N'Deadlock capture sessions exist but cannot be read: ' + @msg
                            ELSE N'No database Extended Events session captures deadlocks, so none can be shown. To capture them (up to 4 MB of memory; keeps the most recent events): '
                               + N'CREATE EVENT SESSION [deadlocks] ON DATABASE ADD EVENT sqlserver.database_xml_deadlock_report ADD TARGET package0.ring_buffer WITH (STARTUP_STATE = ON, MAX_MEMORY = 4 MB); '
                               + N'ALTER EVENT SESSION [deadlocks] ON DATABASE STATE = START;'
                        END,
                        4000
                    )
                );
            END
            ELSE
            BEGIN
                /* Every deadlock in the buffers; sessions that capture the same event are de-duplicated */
                WITH
                    ev AS
                    (
                        SELECT
                            session_name = s.name,
                            event_time_utc = en.n.value('(@timestamp)[1]', 'datetime2(3)'),
                            deadlock_cycle_id = en.n.value('(data[@name="deadlock_cycle_id"]/value/text())[1]', 'bigint'),
                            deadlock_graph = en.n.query('(data[@name="xml_report"]/value/deadlock)[1]')
                        FROM sys.dm_xe_database_sessions AS s
                        JOIN sys.dm_xe_database_session_targets AS t
                          ON CONVERT(binary(8), t.event_session_address) = CONVERT(binary(8), s.address)
                        CROSS APPLY (SELECT target_xml = TRY_CONVERT(xml, t.target_data)) AS tx
                        CROSS APPLY tx.target_xml.nodes('/RingBufferTarget/event[@name="database_xml_deadlock_report"]') AS en (n)
                        WHERE t.target_name = N'ring_buffer'
                    ),
                    d AS
                    (
                        SELECT
                            ev.session_name,
                            ev.event_time_utc,
                            ev.deadlock_cycle_id,
                            ev.deadlock_graph,
                            dup = ROW_NUMBER() OVER (PARTITION BY ev.event_time_utc, ev.deadlock_cycle_id ORDER BY ev.session_name)
                        FROM ev
                    )
                INSERT #dl (session_name, event_time_utc, deadlock_cycle_id, deadlock_graph)
                SELECT
                    d.session_name,
                    d.event_time_utc,
                    d.deadlock_cycle_id,
                    d.deadlock_graph
                FROM d
                WHERE d.dup = 1;

                SELECT
                    @dl_total = COUNT(*),
                    @dl_latest = MAX(d.event_time_utc)
                FROM #dl AS d;

                DELETE #dl
                WHERE event_time_utc IS NULL
                OR    event_time_utc < DATEADD(MINUTE, -@lookback_minutes, CONVERT(datetime2(3), @now_utc));

                SELECT
                    @deadlock_count = COUNT(*)
                FROM #dl;

                INSERT #messages (msg_type, section, message)
                VALUES
                (
                    'INFO', N'deadlocks',
                    LEFT(CONCAT(N'Deadlocks read from ', @dl_sessions, N': ', @dl_total, N' in the ring buffer, ', @deadlock_count, N' in the last ', @lookback_minutes, N' minutes',
                        CASE WHEN @dl_latest IS NOT NULL THEN CONCAT(N'; latest at ', CONVERT(nvarchar(19), CONVERT(datetime2(0), @dl_latest), 120), N' UTC') END,
                        N'. A ring_buffer keeps only the most recent events (bounded by its MAX_MEMORY), so older deadlocks may be gone.'), 4000)
                );

                INSERT #dl_proc (dl_id, spid, is_victim, app, host, login_name, isolation_level, lock_mode, wait_resource, proc_name, input_buffer)
                SELECT
                    d.dl_id,
                    p.n.value('@spid', 'int'),
                    d.deadlock_graph.exist('/deadlock/victim-list/victimProcess[@id = sql:column("pid")]'),
                    p.n.value('@clientapp', 'nvarchar(256)'),
                    p.n.value('@hostname', 'nvarchar(256)'),
                    p.n.value('@loginname', 'nvarchar(256)'),
                    p.n.value('@isolationlevel', 'nvarchar(100)'),
                    p.n.value('@lockMode', 'nvarchar(20)'),
                    p.n.value('@waitresource', 'nvarchar(512)'),
                    p.n.value('(executionStack/frame/@procname[. != "adhoc" and . != "unknown"])[1]', 'nvarchar(512)'),
                    p.n.value('(inputbuf/text())[1]', 'nvarchar(max)')
                FROM #dl AS d
                CROSS APPLY d.deadlock_graph.nodes('/deadlock/process-list/process') AS p (n)
                CROSS APPLY (SELECT pid = p.n.value('@id', 'nvarchar(100)')) AS i;

                /* objectname is <database>.<schema>.<object>; Azure shows the database as a GUID, so drop that part */
                INSERT #dl_res (dl_id, resource_type, object_name, index_name)
                SELECT
                    d.dl_id,
                    r.n.value('local-name(.)', 'nvarchar(60)'),
                    CASE
                        WHEN LEN(rw.raw_name) - LEN(REPLACE(rw.raw_name, N'.', N'')) >= 2
                        THEN SUBSTRING(rw.raw_name, CHARINDEX(N'.', rw.raw_name) + 1, 512)
                        ELSE rw.raw_name
                    END,
                    r.n.value('@indexname', 'nvarchar(256)')
                FROM #dl AS d
                CROSS APPLY d.deadlock_graph.nodes('/deadlock/resource-list/*') AS r (n)
                CROSS APPLY (SELECT raw_name = r.n.value('@objectname', 'nvarchar(512)')) AS rw;

                INSERT #dl_attr (dl_id, attr, value)
                SELECT DISTINCT
                    x.dl_id,
                    x.attr,
                    x.value
                FROM
                (
                    SELECT
                        p.dl_id,
                        v.attr,
                        v.value
                    FROM #dl_proc AS p
                    CROSS APPLY
                    (
                        VALUES
                            (N'app', p.app),
                            (N'host', p.host),
                            (N'login', p.login_name),
                            (N'isolation', p.isolation_level),
                            (N'mode', p.lock_mode),
                            (N'proc', CASE WHEN p.proc_name NOT IN (N'unknown', N'adhoc') THEN p.proc_name END)
                    ) AS v (attr, value)
                    UNION ALL
                    SELECT
                        r.dl_id,
                        v.attr,
                        v.value
                    FROM #dl_res AS r
                    CROSS APPLY
                    (
                        VALUES
                            (N'object', r.object_name + ISNULL(N' (' + r.index_name + N')', N'')),
                            (N'resource', r.resource_type)
                    ) AS v (attr, value)
                ) AS x
                WHERE x.value IS NOT NULL;

                SELECT
                    rn = ROW_NUMBER() OVER (ORDER BY d.event_time_utc DESC, d.dl_id),
                    event_time_utc = CONVERT(datetime2(0), d.event_time_utc),
                    minutes_ago = DATEDIFF(MINUTE, d.event_time_utc, CONVERT(datetime2(3), @now_utc)),
                    sessions = sp.sessions,
                    spids = sp.spids,
                    objects = at.objects,
                    resource_types = at.resource_types,
                    lock_modes = at.lock_modes,
                    isolation_levels = at.isolation_levels,
                    procedures = at.procedures,
                    apps = at.apps,
                    hosts = at.hosts,
                    logins = at.logins,
                    notes =
                        ISNULL(STUFF(CONCAT(
                            CASE
                                WHEN at.isolation_levels LIKE N'%serializable%' OR at.isolation_levels LIKE N'%repeatable read%'
                                THEN N'; serializable or repeatable read isolation keeps range or shared locks until commit (often an ORM or TransactionScope default); use read committed where possible'
                            END,
                            CASE WHEN at.resource_types LIKE N'%exchangeEvent%' THEN N'; intra-query parallelism deadlock: tune the query or lower its MAXDOP' END,
                            CASE WHEN at.resource_types LIKE N'%objectlock%' THEN N'; object-level lock (lock escalation or a table lock hint): check large updates and escalation' END,
                            CASE WHEN rc.tables = 1 AND rc.indexes > 1 THEN N'; one table, different indexes: often a lookup or update-order conflict that a covering index removes' END,
                            CASE WHEN rc.tables = 1 AND rc.indexes = 1 THEN N'; one index: often the same rows changed in a different order, or read-then-update without UPDLOCK' END
                        ), 1, 2, N''), N''),
                    xe_session = d.session_name,
                    input_buffers_text = ib.input_buffers,
                    deadlock_graph = d.deadlock_graph
                INTO #o_deadlocks
                FROM #dl AS d
                OUTER APPLY
                (
                    SELECT
                        sessions = COUNT(*),
                        spids = STRING_AGG(CONVERT(nvarchar(max), CONCAT(x.spid, CASE WHEN x.is_victim = 1 THEN N' (victim)' END)), N', ') WITHIN GROUP (ORDER BY x.spid)
                    FROM
                    (
                        SELECT
                            p.spid,
                            is_victim = MAX(CONVERT(int, p.is_victim))
                        FROM #dl_proc AS p
                        WHERE p.dl_id = d.dl_id
                        GROUP BY
                            p.spid
                    ) AS x
                ) AS sp
                OUTER APPLY
                (
                    SELECT
                        input_buffers =
                            STRING_AGG(CONVERT(nvarchar(max), CONCAT(N'-- spid ', y.spid, CASE WHEN y.is_victim = 1 THEN N' (victim)' END, N' | ', y.isolation_level, N' | waits for ', y.lock_mode, N' on ', y.wait_resource, @crlf, y.input_buffer)), @dl_sep)
                                WITHIN GROUP (ORDER BY y.is_victim DESC, y.spid)
                    FROM
                    (
                        SELECT
                            p.spid,
                            is_victim = MAX(CONVERT(int, p.is_victim)),
                            isolation_level = MAX(p.isolation_level),
                            lock_mode = MAX(p.lock_mode),
                            wait_resource = MAX(p.wait_resource),
                            input_buffer = LTRIM(RTRIM(MAX(p.input_buffer)))
                        FROM #dl_proc AS p
                        WHERE p.dl_id = d.dl_id
                        GROUP BY
                            p.spid
                    ) AS y
                ) AS ib
                OUTER APPLY
                (
                    SELECT
                        objects = LEFT(STRING_AGG(CONVERT(nvarchar(max), CASE WHEN a.attr = N'object' THEN a.value END), N', ') WITHIN GROUP (ORDER BY a.value), 4000),
                        resource_types = LEFT(STRING_AGG(CONVERT(nvarchar(max), CASE WHEN a.attr = N'resource' THEN a.value END), N', ') WITHIN GROUP (ORDER BY a.value), 4000),
                        lock_modes = LEFT(STRING_AGG(CONVERT(nvarchar(max), CASE WHEN a.attr = N'mode' THEN a.value END), N', ') WITHIN GROUP (ORDER BY a.value), 4000),
                        isolation_levels = LEFT(STRING_AGG(CONVERT(nvarchar(max), CASE WHEN a.attr = N'isolation' THEN a.value END), N', ') WITHIN GROUP (ORDER BY a.value), 4000),
                        procedures = LEFT(STRING_AGG(CONVERT(nvarchar(max), CASE WHEN a.attr = N'proc' THEN a.value END), N', ') WITHIN GROUP (ORDER BY a.value), 4000),
                        apps = LEFT(STRING_AGG(CONVERT(nvarchar(max), CASE WHEN a.attr = N'app' THEN a.value END), N', ') WITHIN GROUP (ORDER BY a.value), 4000),
                        hosts = LEFT(STRING_AGG(CONVERT(nvarchar(max), CASE WHEN a.attr = N'host' THEN a.value END), N', ') WITHIN GROUP (ORDER BY a.value), 4000),
                        logins = LEFT(STRING_AGG(CONVERT(nvarchar(max), CASE WHEN a.attr = N'login' THEN a.value END), N', ') WITHIN GROUP (ORDER BY a.value), 4000)
                    FROM #dl_attr AS a
                    WHERE a.dl_id = d.dl_id
                ) AS at
                OUTER APPLY
                (
                    SELECT
                        tables = COUNT(DISTINCT r.object_name),
                        indexes = COUNT(DISTINCT r.index_name)
                    FROM #dl_res AS r
                    WHERE r.dl_id = d.dl_id
                ) AS rc;
            END;
        END TRY
        BEGIN CATCH
            UPDATE #emit SET error_message = LEFT(ERROR_MESSAGE(), 4000) WHERE result_key = @rk;
        END CATCH;

        UPDATE #emit SET duration_ms = DATEDIFF_BIG(MILLISECOND, @t0, SYSDATETIME()) WHERE result_key = @rk;
    END;

    /* ============================================================================================
       1400 stale_statistics (slow): statistics with the most changes since their last update.
       Auto-update threshold: MIN(500 + 20% of rows, SQRT(1000 * rows)) from compatibility level
       130, and 500 + 20% of rows below it.
       ============================================================================================ */
    IF @do_stats = 1
    BEGIN
        SELECT
            @rk = N'stale_statistics',
            @t0 = SYSDATETIME();

        INSERT #emit (section_order, section_key, result_key, result_name, table_name, empty_message)
        VALUES (1400, N'stats', @rk, N'STALE STATISTICS (past the auto-update threshold first, then by modifications; at most 3 per table)', N'#o_stale_statistics', N'No statistics have modifications since their last update.');

        BEGIN TRY
            /* Staged once: the stale list and the list of recent updates both read it */
            SELECT
                        s.object_id,
                        s.stats_id,
                        schema_name = sc.name,
                        table_name = o.name,
                        stats_name = s.name,
                        stats_type = CASE WHEN s.auto_created = 1 THEN N'auto-created' WHEN s.user_created = 1 THEN N'user-created' ELSE N'index' END,
                        table_rows = ISNULL(sp.rows, 0),
                        sp.rows_sampled,
                        sp.modification_counter,
                        sp.last_updated,
                        sp.steps,
                        sp.persisted_sample_percent,
                        s.no_recompute,
                        s.has_filter,
                        s.is_incremental,
                        threshold =
                            CASE
                                WHEN ISNULL(sp.rows, 0) <= 500 THEN 500.0
                                WHEN ISNULL(@compat_level, 130) >= 130 AND SQRT(1000.0 * sp.rows) < 500 + 0.20 * sp.rows THEN SQRT(1000.0 * sp.rows)
                                ELSE 500 + 0.20 * sp.rows
                            END
                    INTO #st
                    FROM sys.stats AS s
                    JOIN sys.objects AS o
                      ON o.object_id = s.object_id
                    JOIN sys.schemas AS sc
                      ON sc.schema_id = o.schema_id
                    CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) AS sp
                    WHERE o.is_ms_shipped = 0
                    AND   o.type IN ('U', 'V')
                    AND
                    (
                        sp.modification_counter > 0
                        OR sp.last_updated >= DATEADD(MINUTE, -15, @now)
                    );

            WITH
                st AS
                (
                    SELECT
                        x.*
                    FROM #st AS x
                    WHERE x.modification_counter > 0
                ),
                ranked AS
                (
                    SELECT
                        st.*,
                        is_due = CASE WHEN st.modification_counter >= st.threshold THEN 1 ELSE 0 END,
                        table_rank =
                            ROW_NUMBER() OVER
                            (
                                PARTITION BY st.object_id
                                ORDER BY CASE WHEN st.modification_counter >= st.threshold THEN 0 ELSE 1 END, st.modification_counter DESC
                            ),
                        due_on_table = SUM(CASE WHEN st.modification_counter >= st.threshold THEN 1 ELSE 0 END) OVER (PARTITION BY st.object_id),
                        due_in_database = SUM(CASE WHEN st.modification_counter >= st.threshold THEN 1 ELSE 0 END) OVER ()
                    FROM st
                ),
                top_rows AS
                (
                    SELECT TOP (@top_n)
                        r.*
                    FROM ranked AS r
                    WHERE r.table_rank <= 3
                    ORDER BY
                        r.is_due DESC,
                        r.modification_counter DESC
                )
            SELECT
                rn = ROW_NUMBER() OVER (ORDER BY t.is_due DESC, t.modification_counter DESC),
                object_name = QUOTENAME(t.schema_name) + N'.' + QUOTENAME(t.table_name),
                stats_name = t.stats_name,
                stats_type = t.stats_type,
                stats_columns = sc2.stats_columns,
                rows_at_update = t.table_rows,
                modifications = t.modification_counter,
                auto_update_threshold = CONVERT(bigint, t.threshold),
                pct_of_threshold = CONVERT(decimal(19, 1), 100.0 * t.modification_counter / t.threshold),
                last_updated = t.last_updated,
                days_since_update = DATEDIFF(DAY, t.last_updated, @now),
                sample_pct = CONVERT(decimal(9, 1), 100.0 * t.rows_sampled / NULLIF(t.table_rows, 0)),
                persisted_sample_pct = NULLIF(CONVERT(decimal(9, 1), t.persisted_sample_percent), 0),
                histogram_steps = t.steps,
                stats_due_on_table = t.due_on_table,
                stats_due_in_database = t.due_in_database,
                notes =
                    ISNULL(STUFF(CONCAT(
                        CASE
                            WHEN t.is_due = 1 AND db.is_auto_update_stats_on = 1 AND t.no_recompute = 0 AND db.is_auto_update_stats_async_on = 1
                            THEN N'; past the threshold: the next compile that uses it starts a background update'
                            WHEN t.is_due = 1 AND db.is_auto_update_stats_on = 1 AND t.no_recompute = 0
                            THEN N'; past the threshold: the next compile that uses it waits for an update first'
                        END,
                        CASE WHEN db.is_auto_update_stats_on = 0 THEN N'; AUTO_UPDATE_STATISTICS is OFF for the database' END,
                        CASE WHEN t.no_recompute = 1 THEN N'; NORECOMPUTE: never updated automatically' END,
                        CASE WHEN t.has_filter = 1 THEN N'; filtered: the threshold counts changes to the whole table, so it can stay stale' END,
                        CASE WHEN t.is_incremental = 1 THEN N'; incremental (per partition)' END,
                        CASE WHEN t.last_updated IS NULL THEN N'; never updated (the table was empty when it was created)' END,
                        CASE WHEN t.due_on_table > 3 THEN CONCAT(N'; ', t.due_on_table, N' statistics on this table are past the threshold') END
                    ), 1, 2, N''), N''),
                script = N'UPDATE STATISTICS ' + QUOTENAME(t.schema_name) + N'.' + QUOTENAME(t.table_name) + N' (' + QUOTENAME(t.stats_name) + N');'
            INTO #o_stale_statistics
            FROM top_rows AS t
            OUTER APPLY
            (
                SELECT
                    stats_columns = STRING_AGG(CONVERT(nvarchar(max), c.name), N', ') WITHIN GROUP (ORDER BY scl.stats_column_id)
                FROM sys.stats_columns AS scl
                JOIN sys.columns AS c
                  ON  c.object_id = scl.object_id
                  AND c.column_id = scl.column_id
                WHERE scl.object_id = t.object_id
                AND   scl.stats_id = t.stats_id
            ) AS sc2
            OUTER APPLY
            (
                SELECT
                    d.is_auto_update_stats_on,
                    d.is_auto_update_stats_async_on
                FROM sys.databases AS d
                WHERE d.database_id = @db_id
            ) AS db;

            SELECT
                @stats_recent = COUNT(*),
                @stats_recent_list =
                    LEFT
                    (
                        STRING_AGG
                        (
                            CASE
                                WHEN x.rnk <= 5
                                THEN CONVERT(nvarchar(max), CONCAT(QUOTENAME(x.schema_name), N'.', QUOTENAME(x.table_name), N' (', x.stats_name, N') at ', CONVERT(nvarchar(8), x.last_updated, 108)))
                            END,
                            N'; '
                        ) WITHIN GROUP (ORDER BY x.rnk),
                        1600
                    )
            FROM
            (
                SELECT
                    s.schema_name,
                    s.table_name,
                    s.stats_name,
                    s.last_updated,
                    rnk = ROW_NUMBER() OVER (ORDER BY s.last_updated DESC)
                FROM #st AS s
                WHERE s.last_updated >= DATEADD(MINUTE, -15, @now)
            ) AS x;
        END TRY
        BEGIN CATCH
            UPDATE #emit SET error_message = LEFT(ERROR_MESSAGE(), 4000) WHERE result_key = @rk;
        END CATCH;

        UPDATE #emit SET duration_ms = DATEDIFF_BIG(MILLISECOND, @t0, SYSDATETIME()) WHERE result_key = @rk;
    END;

    /* ============================================================================================
       1500 index_usage (slow): most read, most written, written but never read, never used.
       Counters reset when the database restarts, fails over or changes service objective, and
       each replica keeps its own: "never read" here says nothing about readable secondaries.
       ============================================================================================ */
    IF @do_indexes = 1
    BEGIN
        SELECT
            @rk = N'index_usage',
            @t0 = SYSDATETIME();

        INSERT #emit (section_order, section_key, result_key, result_name, table_name, empty_message)
        VALUES
        (
            1500,
            N'indexes',
            @rk,
            CONCAT
            (
                N'INDEX USAGE (top ', @top_n, N' per category; counters ',
                CASE
                    WHEN @instance_start IS NULL THEN N'since the last restart'
                    ELSE CONCAT(N'since ', CONVERT(nvarchar(19), @instance_start, 120), N' UTC, ', DATEDIFF(HOUR, @instance_start, @now) / 24, N' days')
                END,
                N'; this replica only)'
            ),
            N'#o_index_usage',
            N'No user indexes found.'
        );

        BEGIN TRY
            /* Stage the DMVs first: joined directly to the catalog views they can land on the inner side
               of nested loops and be re-evaluated for every index (seen timing out on 2,600 indexes). */
            SELECT
                p.object_id,
                p.index_id,
                used_pages = SUM(p.used_page_count),
                row_count = SUM(p.row_count)
            INTO #ix_size
            FROM sys.dm_db_partition_stats AS p
            GROUP BY
                p.object_id,
                p.index_id;

            SELECT
                us.object_id,
                us.index_id,
                us.user_seeks,
                us.user_scans,
                us.user_lookups,
                us.user_updates,
                us.last_user_seek,
                us.last_user_scan,
                us.last_user_lookup,
                us.last_user_update
            INTO #ix_usage
            FROM sys.dm_db_index_usage_stats AS us
            WHERE us.database_id = @db_id;

            SELECT
                i.object_id,
                i.index_id,
                index_type_code = i.type,
                schema_name = sc.name,
                table_name = o.name,
                index_name = i.name,
                index_type = i.type_desc,
                i.is_unique,
                i.has_filter,
                reads = ISNULL(us.user_seeks, 0) + ISNULL(us.user_scans, 0) + ISNULL(us.user_lookups, 0),
                seeks = ISNULL(us.user_seeks, 0),
                scans = ISNULL(us.user_scans, 0),
                lookups = ISNULL(us.user_lookups, 0),
                writes = ISNULL(us.user_updates, 0),
                last_read =
                (
                    SELECT MAX(v.x)
                    FROM (VALUES (us.last_user_seek), (us.last_user_scan), (us.last_user_lookup)) AS v (x)
                ),
                last_write = us.last_user_update,
                used_pages = ISNULL(ps.used_pages, 0),
                index_rows = ps.row_count
            INTO #ix
            FROM sys.indexes AS i
            JOIN sys.objects AS o
              ON o.object_id = i.object_id
            JOIN sys.schemas AS sc
              ON sc.schema_id = o.schema_id
            LEFT JOIN #ix_size AS ps
              ON  ps.object_id = i.object_id
              AND ps.index_id = i.index_id
            LEFT JOIN #ix_usage AS us
              ON  us.object_id = i.object_id
              AND us.index_id = i.index_id
            WHERE o.is_ms_shipped = 0
            AND   o.type IN ('U', 'V')
            AND   i.is_hypothetical = 0
            AND   i.is_disabled = 0;

            WITH
                c AS
                (
                    SELECT
                        u.*,
                        category = N'most read',
                        sort_cat = 1,
                        cat_rank = ROW_NUMBER() OVER (ORDER BY u.reads DESC, u.used_pages DESC),
                        cat_total = COUNT_BIG(*) OVER ()
                    FROM #ix AS u
                    WHERE u.reads > 0

                    UNION ALL

                    SELECT u.*, N'most written', 2, ROW_NUMBER() OVER (ORDER BY u.writes DESC, u.used_pages DESC), COUNT_BIG(*) OVER ()
                    FROM #ix AS u
                    WHERE u.writes > 0

                    UNION ALL

                    /* Unique indexes enforce constraints even when nothing reads them, so they are never "unused". */
                    SELECT u.*, N'written, never read', 3, ROW_NUMBER() OVER (ORDER BY u.writes DESC, u.used_pages DESC), COUNT_BIG(*) OVER ()
                    FROM #ix AS u
                    WHERE u.index_id > 1
                    AND   u.is_unique = 0
                    AND   u.reads = 0
                    AND   u.writes > 0

                    UNION ALL

                    SELECT u.*, N'never used, largest first', 4, ROW_NUMBER() OVER (ORDER BY u.used_pages DESC), COUNT_BIG(*) OVER ()
                    FROM #ix AS u
                    WHERE u.index_id > 1
                    AND   u.is_unique = 0
                    AND   u.reads = 0
                    AND   u.writes = 0
                )
            SELECT
                rn = ROW_NUMBER() OVER (ORDER BY c.sort_cat, c.cat_rank),
                category = c.category,
                category_rank = c.cat_rank,
                category_total = c.cat_total,
                object_name = QUOTENAME(c.schema_name) + N'.' + QUOTENAME(c.table_name),
                index_name = c.index_name,
                index_type = c.index_type,
                key_columns = k.key_columns,
                included_columns = CASE WHEN c.index_type_code <> 5 THEN k.included_columns END,
                size_mb = CONVERT(decimal(19, 1), c.used_pages / 128.0),
                index_rows = c.index_rows,
                reads = c.reads,
                seeks = c.seeks,
                scans = c.scans,
                lookups = c.lookups,
                writes = c.writes,
                writes_per_read = CONVERT(decimal(19, 1), 1.0 * c.writes / NULLIF(c.reads, 0)),
                last_read = c.last_read,
                last_write = c.last_write,
                notes =
                    ISNULL(STUFF(CONCAT(
                        CASE WHEN c.sort_cat IN (3, 4) THEN N'; no reads on this replica since the counters reset: check readable secondaries, named replicas and month-end jobs before dropping it' END,
                        CASE WHEN c.sort_cat = 3 THEN N'; every insert, update and delete on the table still maintains it' END,
                        CASE
                            WHEN c.index_id = 0 AND c.lookups >= 1000
                            THEN CONCAT(N'; ', c.lookups, N' RID lookups: nonclustered indexes on this heap do not cover their queries')
                            WHEN c.index_id = 1 AND c.lookups >= 1000 AND c.lookups >= c.reads / 10
                            THEN CONCAT(N'; ', c.lookups, N' key lookups (', CONVERT(int, 100.0 * c.lookups / NULLIF(c.reads, 0)), N'% of reads): covering nonclustered indexes could remove them')
                        END,
                        CASE
                            WHEN c.scans > 0 AND c.used_pages >= 131072
                            THEN CONCAT(N'; ', c.scans, N' scans (range or full) of a ', CONVERT(decimal(19, 1), c.used_pages / 131072.0), N' GB index')
                        END,
                        CASE
                            WHEN c.index_id > 1 AND c.reads > 0 AND c.writes >= 100 * c.reads
                            THEN CONCAT(N'; written ', c.writes / NULLIF(c.reads, 0), N' times per read')
                        END,
                        CASE WHEN c.has_filter = 1 THEN N'; filtered index' END
                    ), 1, 2, N''), N'')
            INTO #o_index_usage
            FROM c
            OUTER APPLY
            (
                SELECT
                    key_columns =
                        STRING_AGG(CASE WHEN ic.key_ordinal > 0 THEN CONVERT(nvarchar(max), col.name) + CASE WHEN ic.is_descending_key = 1 THEN N' DESC' ELSE N'' END END, N', ')
                            WITHIN GROUP (ORDER BY ic.key_ordinal, ic.index_column_id),
                    included_columns =
                        STRING_AGG(CASE WHEN ic.key_ordinal = 0 THEN CONVERT(nvarchar(max), col.name) END, N', ')
                            WITHIN GROUP (ORDER BY ic.key_ordinal, ic.index_column_id)
                FROM sys.index_columns AS ic
                JOIN sys.columns AS col
                  ON  col.object_id = ic.object_id
                  AND col.column_id = ic.column_id
                WHERE ic.object_id = c.object_id
                AND   ic.index_id = c.index_id
            ) AS k
            WHERE c.cat_rank <= @top_n;

            IF @instance_start > DATEADD(DAY, -7, @now)
                INSERT #messages (msg_type, section, message)
                VALUES
                (
                    'INFO',
                    N'indexes',
                    LEFT(CONCAT(N'Index usage counters only cover the time since ', CONVERT(nvarchar(19), @instance_start, 120), N' UTC. Indexes used by weekly or monthly jobs can look unused.'), 4000)
                );
        END TRY
        BEGIN CATCH
            UPDATE #emit SET error_message = LEFT(ERROR_MESSAGE(), 4000) WHERE result_key = @rk;
        END CATCH;

        UPDATE #emit SET duration_ms = DATEDIFF_BIG(MILLISECOND, @t0, SYSDATETIME()) WHERE result_key = @rk;
    END;

    /* ============================================================================================
       1520 index_fragmentation (explicit only): LIMITED scan of rowstore partitions over 2,500
       pages, largest first, one partition at a time (a lock timeout skips one partition, not the
       result), within a time budget. LIMITED reads only the levels above the leaf: it reports
       logical fragmentation but not page density.
       ============================================================================================ */
    IF @do_fragmentation = 1
    BEGIN
        DECLARE
            @fr_budget_s int = 300,
            @fr_id int = 0,
            @fr_object_id int,
            @fr_index_id int,
            @fr_partition int,
            @fr_total int = 0,
            @fr_done int = 0,
            @fr_failed int = 0,
            @fr_error nvarchar(2048),
            @fr_t0 datetime2(7);

        SELECT
            @rk = N'index_fragmentation',
            @t0 = SYSDATETIME();

        INSERT #emit (section_order, section_key, result_key, result_name, table_name, empty_message)
        VALUES
        (
            1520,
            N'fragmentation',
            @rk,
            CONCAT(N'INDEX FRAGMENTATION (LIMITED scan of rowstore partitions over 2,500 pages, largest first, ', @fr_budget_s, N'-second budget; most fragmented first)'),
            N'#o_index_fragmentation',
            N'No rowstore index partition over 2,500 pages was scanned.'
        );

        CREATE TABLE #fr_cand
        (
            cand_id int IDENTITY(1, 1) NOT NULL PRIMARY KEY,
            object_id int NOT NULL,
            index_id int NOT NULL,
            partition_number int NOT NULL,
            used_pages bigint NOT NULL
        );

        CREATE TABLE #fr
        (
            object_id int NOT NULL,
            index_id int NOT NULL,
            partition_number int NOT NULL,
            avg_fragmentation_pct float NULL,
            fragment_count bigint NULL,
            avg_fragment_size_pages float NULL,
            page_count bigint NULL,
            index_depth tinyint NULL
        );

        BEGIN TRY
            INSERT #fr_cand (object_id, index_id, partition_number, used_pages)
            SELECT
                p.object_id,
                p.index_id,
                p.partition_number,
                p.in_row_used_page_count
            FROM sys.dm_db_partition_stats AS p
            JOIN sys.indexes AS i
              ON  i.object_id = p.object_id
              AND i.index_id = p.index_id
            JOIN sys.objects AS o
              ON o.object_id = p.object_id
            WHERE o.is_ms_shipped = 0
            AND   o.type IN ('U', 'V')
            AND   i.type IN (1, 2)
            AND   i.is_disabled = 0
            AND   i.is_hypothetical = 0
            AND   p.in_row_used_page_count > 2500
            ORDER BY
                p.in_row_used_page_count DESC;

            SELECT
                @fr_total = @@ROWCOUNT,
                @fr_t0 = SYSDATETIME();

            WHILE 1 = 1
            BEGIN
                IF DATEDIFF(SECOND, @fr_t0, SYSDATETIME()) >= @fr_budget_s
                    BREAK;

                SELECT TOP (1)
                    @fr_id = c.cand_id,
                    @fr_object_id = c.object_id,
                    @fr_index_id = c.index_id,
                    @fr_partition = c.partition_number
                FROM #fr_cand AS c
                WHERE c.cand_id > @fr_id
                ORDER BY
                    c.cand_id;

                IF @@ROWCOUNT = 0
                    BREAK;

                BEGIN TRY
                    INSERT #fr (object_id, index_id, partition_number, avg_fragmentation_pct, fragment_count, avg_fragment_size_pages, page_count, index_depth)
                    SELECT
                        @fr_object_id,
                        @fr_index_id,
                        @fr_partition,
                        ps.avg_fragmentation_in_percent,
                        ps.fragment_count,
                        ps.avg_fragment_size_in_pages,
                        ps.page_count,
                        ps.index_depth
                    FROM sys.dm_db_index_physical_stats(@db_id, @fr_object_id, @fr_index_id, @fr_partition, N'LIMITED') AS ps
                    WHERE ps.alloc_unit_type_desc = N'IN_ROW_DATA'
                    AND   ps.index_level = 0;

                    SET @fr_done += 1;
                END TRY
                BEGIN CATCH
                    SELECT
                        @fr_failed += 1,
                        @fr_error = ISNULL(@fr_error, LEFT(ERROR_MESSAGE(), 2048));
                END CATCH;
            END;

            SELECT TOP (@top_n)
                rn = ROW_NUMBER() OVER (ORDER BY f.avg_fragmentation_pct DESC, f.page_count DESC),
                object_name = QUOTENAME(sc.name) + N'.' + QUOTENAME(o.name),
                index_name = i.name,
                index_type = i.type_desc,
                partition_number = f.partition_number,
                fragmentation_pct = CONVERT(decimal(9, 1), f.avg_fragmentation_pct),
                size_mb = CONVERT(decimal(19, 1), f.page_count / 128.0),
                page_count = f.page_count,
                fragment_count = f.fragment_count,
                avg_fragment_size_pages = CONVERT(decimal(19, 1), f.avg_fragment_size_pages),
                index_depth = f.index_depth,
                fill_factor = i.fill_factor,
                allow_page_locks = i.allow_page_locks,
                filter_definition = i.filter_definition,
                notes =
                    ISNULL(STUFF(CONCAT(
                        CASE WHEN i.allow_page_locks = 0 THEN N'; page locks are disallowed, so ALTER INDEX ... REORGANIZE fails' END,
                        CASE WHEN i.fill_factor BETWEEN 1 AND 79 THEN CONCAT(N'; fill factor ', i.fill_factor, N'%: pages are left ', 100 - i.fill_factor, N'% empty on purpose') END,
                        CASE WHEN f.avg_fragmentation_pct >= 30 AND f.page_count >= 128000 THEN N'; large: check page density with the script first, a rebuild this size is heavy on log, IO and secondaries' END
                    ), 1, 2, N''), N''),
                density_check_script =
                    CONCAT
                    (
                        N'SELECT avg_page_space_used_in_percent, avg_fragmentation_in_percent, page_count FROM sys.dm_db_index_physical_stats(DB_ID(), OBJECT_ID(N''',
                        REPLACE(QUOTENAME(sc.name) + N'.' + QUOTENAME(o.name), N'''', N''''''),
                        N'''), ', f.index_id, N', ', f.partition_number, N', N''SAMPLED'');'
                    )
            INTO #o_index_fragmentation
            FROM #fr AS f
            JOIN sys.indexes AS i
              ON  i.object_id = f.object_id
              AND i.index_id = f.index_id
            JOIN sys.objects AS o
              ON o.object_id = f.object_id
            JOIN sys.schemas AS sc
              ON sc.schema_id = o.schema_id
            ORDER BY
                rn;

            INSERT #messages (msg_type, section, message)
            VALUES
            (
                'INFO',
                N'fragmentation',
                LEFT(CONCAT(
                    N'Fragmentation: scanned ', @fr_done, N' of ', @fr_total, N' rowstore partitions over 2,500 pages in ',
                    DATEDIFF(SECOND, @fr_t0, SYSDATETIME()), N' s, largest first',
                    CASE WHEN @fr_done + @fr_failed < @fr_total THEN CONCAT(N'; stopped at the ', @fr_budget_s, N'-second budget') END,
                    N'.',
                    CASE WHEN @fr_failed > 0 THEN CONCAT(N' ', @fr_failed, N' partition(s) could not be read (first error: ', @fr_error, N').') END,
                    N' LIMITED mode reports page order only. On Azure SQL storage, low page density (wasted memory and IO) matters more than order: run the density_check_script (SAMPLED mode) before rebuilding.',
                    CASE WHEN @is_hyperscale = 1 THEN N' On Hyperscale, pages that are not cached locally are read from page servers.' END
                ), 4000)
            );
        END TRY
        BEGIN CATCH
            UPDATE #emit SET error_message = LEFT(ERROR_MESSAGE(), 4000) WHERE result_key = @rk;
        END CATCH;

        UPDATE #emit SET duration_ms = DATEDIFF_BIG(MILLISECOND, @t0, SYSDATETIME()) WHERE result_key = @rk;
    END;

    /* ============================================================================================
       1600 buffer_usage (explicit only): what this database holds in memory now, by index.
       One pass over sys.dm_os_buffer_descriptors (every database on the instance), aggregated by
       allocation unit before any join. Empty space in cached pages is a free page density probe.
       ============================================================================================ */
    IF @do_buffer = 1
    BEGIN
        DECLARE
            @buf_db_pages bigint,
            @buf_all_pages bigint,
            @buf_db_free_bytes bigint;

        SELECT
            @rk = N'buffer_usage',
            @t0 = SYSDATETIME();

        INSERT #emit (section_order, section_key, result_key, result_name, table_name, empty_message)
        VALUES
        (
            1600,
            N'buffer',
            @rk,
            N'BUFFER POOL USAGE BY INDEX (pages in memory now'
                + CASE WHEN @is_hyperscale = 1 THEN N'; the Hyperscale local SSD cache (RBPEX) is not included' ELSE N'' END
                + N')',
            N'#o_buffer_usage',
            N'No pages of this database are in the buffer pool.'
        );

        CREATE TABLE #buf
        (
            allocation_unit_id bigint NOT NULL PRIMARY KEY,
            pages bigint NOT NULL,
            dirty_pages bigint NOT NULL,
            free_bytes bigint NOT NULL
        );

        BEGIN TRY
            /* -1 = pages of other databases (tempdb, master, internal), kept only for the total. */
            INSERT #buf (allocation_unit_id, pages, dirty_pages, free_bytes)
            SELECT
                allocation_unit_id = CASE WHEN bd.database_id = @db_id THEN ISNULL(bd.allocation_unit_id, -2) ELSE -1 END,
                pages = COUNT_BIG(*),
                dirty_pages = COUNT_BIG(CASE WHEN bd.is_modified = 1 THEN 1 END),
                free_bytes = ISNULL(SUM(CONVERT(bigint, bd.free_space_in_bytes)), 0)
            FROM sys.dm_os_buffer_descriptors AS bd
            GROUP BY
                CASE WHEN bd.database_id = @db_id THEN ISNULL(bd.allocation_unit_id, -2) ELSE -1 END;

            SELECT
                @buf_all_pages = SUM(b.pages),
                @buf_db_pages = SUM(CASE WHEN b.allocation_unit_id <> -1 THEN b.pages END),
                @buf_db_free_bytes = SUM(CASE WHEN b.allocation_unit_id <> -1 THEN b.free_bytes END)
            FROM #buf AS b;

            SELECT
                p.object_id,
                p.index_id,
                used_pages = SUM(p.used_page_count),
                row_count = SUM(p.row_count)
            INTO #buf_size
            FROM sys.dm_db_partition_stats AS p
            GROUP BY
                p.object_id,
                p.index_id;

            WITH
                a AS
                (
                    SELECT
                        p.object_id,
                        p.index_id,
                        pages = SUM(b.pages),
                        dirty_pages = SUM(b.dirty_pages),
                        free_bytes = SUM(b.free_bytes)
                    FROM #buf AS b
                    JOIN sys.allocation_units AS au
                      ON au.allocation_unit_id = b.allocation_unit_id
                    JOIN sys.partitions AS p
                      ON p.partition_id = au.container_id
                    GROUP BY
                        p.object_id,
                        p.index_id
                ),
                r AS
                (
                    SELECT TOP (@top_n)
                        a.*
                    FROM a
                    ORDER BY
                        a.pages DESC
                )
            SELECT
                rn = ROW_NUMBER() OVER (ORDER BY r.pages DESC),
                object_name = ISNULL(QUOTENAME(sc.name) + N'.' + QUOTENAME(o.name), CONCAT(N'object_id ', r.object_id)),
                object_type = o.type_desc,
                index_name = i.name,
                index_type = i.type_desc,
                cached_mb = CONVERT(decimal(19, 1), r.pages / 128.0),
                pct_of_db_cache = CONVERT(decimal(9, 1), 100.0 * r.pages / NULLIF(@buf_db_pages, 0)),
                pct_of_buffer_pool = CONVERT(decimal(9, 1), 100.0 * r.pages / NULLIF(@buf_all_pages, 0)),
                index_size_mb = CONVERT(decimal(19, 1), s.used_pages / 128.0),
                pct_of_index_cached = CONVERT(decimal(9, 1), 100.0 * r.pages / NULLIF(s.used_pages, 0)),
                cached_page_density_pct = CONVERT(decimal(9, 1), 100.0 - 100.0 * r.free_bytes / NULLIF(r.pages * 8096.0, 0)),
                empty_space_mb = CONVERT(decimal(19, 1), r.free_bytes / 1048576.0),
                dirty_mb = CONVERT(decimal(19, 1), r.dirty_pages / 128.0),
                index_rows = s.row_count,
                compression = pc.compression,
                fill_factor = NULLIF(i.fill_factor, 0),
                notes =
                    ISNULL(STUFF(CONCAT(
                        CASE
                            WHEN r.pages >= 12800 AND 100.0 * r.free_bytes / NULLIF(r.pages * 8096.0, 0) >= 30
                            THEN CONCAT
                                 (
                                     N'; cached pages are ', CONVERT(int, 100.0 * r.free_bytes / NULLIF(r.pages * 8096.0, 0)),
                                     N'% empty: ', r.free_bytes / 1048576, N' MB of memory holds no rows',
                                     CASE WHEN i.fill_factor BETWEEN 1 AND 99 THEN CONCAT(N' (fill factor ', i.fill_factor, N'%)') END,
                                     CASE WHEN r.index_id = 0 THEN N'; heap: space freed by deletes is reused poorly until ALTER TABLE ... REBUILD' END
                                 )
                        END,
                        CASE WHEN s.used_pages >= 131072 AND r.pages >= 0.9 * s.used_pages THEN N'; almost the whole index is in memory: read in full regularly, or all of it is hot' END,
                        CASE WHEN r.dirty_pages >= 131072 THEN N'; over 1 GB of changed pages not yet written to storage' END,
                        CASE WHEN o.type IN ('S', 'IT') THEN N'; system or internal table (Query Store, change tracking, columnstore internals)' END
                    ), 1, 2, N''), N'')
            INTO #o_buffer_usage
            FROM r
            LEFT JOIN sys.objects AS o
              ON o.object_id = r.object_id
            LEFT JOIN sys.schemas AS sc
              ON sc.schema_id = o.schema_id
            LEFT JOIN sys.indexes AS i
              ON  i.object_id = r.object_id
              AND i.index_id = r.index_id
            LEFT JOIN #buf_size AS s
              ON  s.object_id = r.object_id
              AND s.index_id = r.index_id
            OUTER APPLY
            (
                SELECT
                    compression =
                        CASE
                            WHEN MIN(p2.data_compression_desc) = MAX(p2.data_compression_desc) THEN MIN(p2.data_compression_desc)
                            ELSE N'MIXED'
                        END
                FROM sys.partitions AS p2
                WHERE p2.object_id = r.object_id
                AND   p2.index_id = r.index_id
            ) AS pc;

            IF @buf_db_pages > 0
                INSERT #messages (msg_type, section, message)
                VALUES
                (
                    'INFO',
                    N'buffer',
                    LEFT(CONCAT(
                        N'Buffer pool: this database has ', CONVERT(decimal(19, 1), @buf_db_pages / 128.0), N' MB in memory (',
                        CONVERT(decimal(9, 1), 100.0 * @buf_db_pages / NULLIF(@buf_all_pages, 0)), N'% of the ',
                        CONVERT(decimal(19, 1), @buf_all_pages / 128.0), N' MB cached for all databases, tempdb included). ',
                        CONVERT(decimal(19, 1), @buf_db_free_bytes / 1048576.0), N' MB of it (',
                        CONVERT(decimal(9, 1), 100.0 * @buf_db_free_bytes / NULLIF(@buf_db_pages * 8096.0, 0)),
                        N'%) is empty space inside cached pages: low page density costs memory as well as IO.'
                    ), 4000)
                );
        END TRY
        BEGIN CATCH
            UPDATE #emit SET error_message = LEFT(ERROR_MESSAGE(), 4000) WHERE result_key = @rk;
        END CATCH;

        UPDATE #emit SET duration_ms = DATEDIFF_BIG(MILLISECOND, @t0, SYSDATETIME()) WHERE result_key = @rk;
    END;

    /* ============================================================================================
       100 summary, 110 findings. The facts come from cheap DMVs and from the live snapshots taken
       above, so the summary is complete even when it is the only section requested. Findings are
       ranked 1 critical, 2 high, 3 medium, 4 low, 5 info; the status is the worst of them.
       ============================================================================================ */
    DECLARE
        @f_rs_latest datetime,
        @f_rs_samples int,
        @f_cpu_now decimal(9, 2),
        @f_cpu_avg5 decimal(9, 2),
        @f_cpu_max5 decimal(9, 2),
        @f_io_now decimal(9, 2),
        @f_io_avg5 decimal(9, 2),
        @f_log_now decimal(9, 2),
        @f_log_avg5 decimal(9, 2),
        @f_workers_now decimal(9, 2),
        @f_workers_max5 decimal(9, 2),
        @f_sessions_now decimal(9, 2),
        @f_sessions_max5 decimal(9, 2),
        @f_mem_now decimal(9, 2),
        @f_icpu_now decimal(9, 2),
        @f_icpu_avg5 decimal(9, 2),
        @f_wg_active_workers int,
        @f_wg_queued int,
        @f_work_queue bigint,
        @f_runnable_avg decimal(9, 2),
        @f_workers_live_pct decimal(9, 2),
        @f_workers_pct decimal(9, 2),
        @f_data_used_mb decimal(19, 1),
        @f_data_alloc_mb decimal(19, 1),
        @f_data_max_mb decimal(19, 1),
        @f_data_pct decimal(9, 2),
        @f_log_used_pct decimal(9, 2),
        @f_log_file_pct decimal(9, 2),
        @f_log_used_mb decimal(19, 1),
        @f_log_size_mb decimal(19, 1),
        @f_log_basis nvarchar(200),
        @f_log_reuse_wait nvarchar(60),
        @f_updateability nvarchar(30),
        @f_auto_create_stats bit,
        @f_auto_update_stats bit,
        @f_auto_shrink bit,
        @f_compat int,
        @f_qs_actual smallint,
        @f_qs_desired smallint,
        @f_qs_state nvarchar(60),
        @f_qs_readonly_reason int,
        @f_qs_used_mb bigint,
        @f_qs_max_mb bigint,
        @f_qs_pct decimal(9, 2),
        @f_qs_cleanup_auto bit,
        @f_at_mismatch nvarchar(2000),
        @f_regressions int,
        @f_force_total int,
        @f_force_failed int,
        @f_force_example nvarchar(400),
        @f_pvs_mb decimal(19, 1),
        @f_pvs_aborted bigint,
        @f_pvs_oldest_xact bigint,
        @f_pvs_oldest_session int,
        @f_mh_level int,
        @f_mh_desc nvarchar(60),
        @f_mh_clerks nvarchar(1000),
        @f_mh_high int,
        @f_blocked int,
        @f_blk_max_wait_ms bigint,
        @f_blk_heads int,
        @f_blk_sleeping_heads int,
        @f_blk_cycle int,
        @f_head_session int,
        @f_head_total int,
        @f_head_open_tran int,
        @f_head_idle_s bigint,
        @f_head_who nvarchar(600),
        @f_head_state nvarchar(400),
        @f_req_active int,
        @f_req_running int,
        @f_req_runnable int,
        @f_req_suspended int,
        @f_req_parallel int,
        @f_req_pageio int,
        @f_req_long int,
        @f_long_s bigint,
        @f_long_desc nvarchar(600),
        @f_tran_open int,
        @f_tran_oldest_session int,
        @f_tran_oldest_s bigint,
        @f_tran_oldest_state nvarchar(30),
        @f_tran_oldest_log_mb decimal(19, 1),
        @f_idle_tran int,
        @f_idle_tran_max_s bigint,
        @f_idle_work int,
        @f_idle_work_max_s bigint,
        @f_idle_tran_session int,
        @f_idle_tran_session_s bigint,
        @f_idle_tran_who nvarchar(600),
        @f_idle_tran_blocking int,
        @f_idle_tran_age_s bigint,
        @f_sess_user int,
        @f_sess_db int,
        @f_sess_sleeping int,
        @f_grants_pending int,
        @f_grants_active int,
        @f_grant_wait_ms bigint,
        @f_granted_mb decimal(19, 1),
        @f_grant_big_session int,
        @f_grant_big_mb decimal(19, 1),
        @f_grant_big_used_mb decimal(19, 1),
        @f_grant_big_s bigint,
        @f_grant_big_dop int,
        @f_grant_target_mb decimal(19, 1),
        @f_threadpool_tasks int,
        @f_waits_now nvarchar(2000),
        @f_top_wait_now nvarchar(128),
        @f_gov_now int,
        @f_gov_now_types nvarchar(1000),
        @f_waits_delta nvarchar(2000),
        @f_top_wait_delta nvarchar(128),
        @f_wait_total_ms bigint,
        @f_wait_gov_ms bigint,
        @f_wait_threadpool_ms bigint,
        @f_tdb_data_used_mb decimal(19, 1),
        @f_tdb_data_max_mb decimal(19, 1),
        @f_tdb_data_pct decimal(9, 2),
        @f_tdb_log_pct decimal(9, 2),
        @f_tdb_top_session int,
        @f_tdb_top_mb decimal(19, 1),
        @f_io_data_ios bigint,
        @f_io_data_stall_ms bigint,
        @f_io_data_queued_ms bigint,
        @f_io_log_writes bigint,
        @f_io_log_stall_ms bigint,
        @f_replica_rows int,
        @f_geo_lag_s bigint,
        @f_geo_partner nvarchar(600),
        @f_ha_bad int,
        @f_ha_sev tinyint,
        @f_ha_desc nvarchar(2000),
        @f_batches bigint,
        @f_compiles bigint,
        @f_recompiles bigint,
        @f_attentions bigint,
        @f_io_read_count bigint,
        @f_io_read_stall_ms bigint,
        @f_rollback int,
        @f_rollback_blocking int,
        @f_rollback_desc nvarchar(600),
        @f_identity_count int,
        @f_identity_max_pct decimal(9, 1),
        @f_identity_list nvarchar(1600),
        @f_wait_compile_ms bigint,
        @f_wait_ioretry_ms bigint,
        @f_compile_now int,
        @f_idle_implicit int,
        @f_deadlocks_delta bigint,
        @f_counter_s decimal(18, 3),
        @f_n_crit int,
        @f_n_high int,
        @f_n_med int,
        @f_n_low int,
        @f_status nvarchar(20);

    /* Azure IO and log rate governance waits (CPU capping shows up as CPU percent instead) */
    DECLARE @f_gov table
    (
        pattern nvarchar(60) NOT NULL PRIMARY KEY
    );

    /* Sampled wait deltas (non-benign waits only) */
    DECLARE @f_wd table
    (
        wait_type nvarchar(128) NOT NULL PRIMARY KEY,
        wait_ms bigint NOT NULL,
        tasks bigint NULL,
        is_gov bit NOT NULL
    );

    IF @do_summary = 1
    BEGIN
        INSERT @f_gov (pattern)
        VALUES
            (N'LOG_RATE_GOVERNOR'), (N'POOL_LOG_RATE_GOVERNOR'), (N'INSTANCE_LOG_RATE_GOVERNOR'),
            (N'HADR_THROTTLE_LOG_RATE%'), (N'RBIO_RG%'), (N'IO_QUEUE_LIMIT'), (N'RESMGR_THROTTLED');

        /* Resource usage: the latest 15-second row and the 5 minutes before it */
        BEGIN TRY
            SELECT TOP (1)
                @f_rs_latest = s.end_time,
                @f_cpu_now = s.avg_cpu_percent,
                @f_io_now = s.avg_data_io_percent,
                @f_log_now = s.avg_log_write_percent,
                @f_workers_now = s.max_worker_percent,
                @f_sessions_now = s.max_session_percent,
                @f_mem_now = s.avg_memory_usage_percent,
                @f_icpu_now = s.avg_instance_cpu_percent
            FROM sys.dm_db_resource_stats AS s
            ORDER BY
                s.end_time DESC;

            SELECT
                @f_rs_samples = COUNT(*),
                @f_cpu_avg5 = AVG(s.avg_cpu_percent),
                @f_cpu_max5 = MAX(s.avg_cpu_percent),
                @f_io_avg5 = AVG(s.avg_data_io_percent),
                @f_log_avg5 = AVG(s.avg_log_write_percent),
                @f_workers_max5 = MAX(s.max_worker_percent),
                @f_sessions_max5 = MAX(s.max_session_percent),
                @f_icpu_avg5 = AVG(s.avg_instance_cpu_percent)
            FROM sys.dm_db_resource_stats AS s
            WHERE s.end_time > DATEADD(MINUTE, -5, @f_rs_latest);
        END TRY
        BEGIN CATCH
            INSERT #messages (msg_type, section, message)
            VALUES ('INFO', N'summary', LEFT(N'sys.dm_db_resource_stats: ' + ERROR_MESSAGE(), 4000));
        END CATCH;

        /* Workers: the workload group of this database and the scheduler queues */
        BEGIN TRY
            SELECT TOP (1)
                @f_wg_active_workers = w.active_worker_count,
                @f_wg_queued = w.queued_request_count
            FROM sys.dm_resource_governor_workload_groups AS w
            WHERE w.group_id = @primary_group_id
            OR    (@primary_group_id IS NULL AND w.name = CONCAT(N'UserPrimaryGroup.DBId', @db_id))
            ORDER BY
                CASE WHEN w.group_id = @primary_group_id THEN 0 ELSE 1 END;

            SELECT
                @f_work_queue = SUM(CONVERT(bigint, s.work_queue_count)),
                @f_runnable_avg = AVG(1.0 * s.runnable_tasks_count)
            FROM sys.dm_os_schedulers AS s
            WHERE s.status = N'VISIBLE ONLINE';
        END TRY
        BEGIN CATCH
            INSERT #messages (msg_type, section, message)
            VALUES ('INFO', N'summary', LEFT(N'Workload group and scheduler DMVs: ' + ERROR_MESSAGE(), 4000));
        END CATCH;

        SET @f_workers_live_pct = 100.0 * @f_wg_active_workers / NULLIF(@rg_max_workers, 0);

        SELECT
            @f_workers_pct = MAX(v.pct)
        FROM
        (
            VALUES
                (@f_workers_now),
                (@f_workers_max5),
                (@f_workers_live_pct)
        ) AS v (pct);

        /* Storage and database options */
        BEGIN TRY
            SELECT
                @f_data_used_mb = SUM(fsu.allocated_extent_page_count) / 128.0,
                @f_data_alloc_mb = SUM(fsu.total_page_count) / 128.0
            FROM sys.dm_db_file_space_usage AS fsu
            WHERE fsu.database_id = @db_id;

            /* Hyperscale reports no fixed maximum (0) */
            SELECT
                @f_data_max_mb = CASE WHEN m.max_bytes > 0 THEN m.max_bytes / 1048576.0 END
            FROM
            (
                SELECT
                    max_bytes = CONVERT(bigint, DATABASEPROPERTYEX(@db_name, 'MaxSizeInBytes'))
            ) AS m;

            SET @f_data_pct = 100.0 * @f_data_used_mb / NULLIF(@f_data_max_mb, 0);

            SELECT TOP (1)
                @f_log_file_pct = l.used_log_space_in_percent,
                @f_log_used_mb = l.used_log_space_in_bytes / 1048576.0,
                @f_log_size_mb = l.total_log_size_in_bytes / 1048576.0
            FROM sys.dm_db_log_space_usage AS l;

            /* Percent of the maximum log size when it is known: the log file grows on demand, so a
               small file that is nearly full is not a log that is nearly full. */
            SELECT
                @f_log_used_pct =
                    CASE
                        WHEN @log_max_mb >= @f_log_size_mb THEN 100.0 * @f_log_used_mb / @log_max_mb
                        ELSE @f_log_file_pct
                    END,
                @f_log_basis =
                    CASE
                        WHEN @log_max_mb >= @f_log_size_mb
                        THEN CONCAT(N'the ', @log_max_mb, N' MB maximum log size (the log file is ', @f_log_size_mb, N' MB now, ', @f_log_file_pct, N'% used)')
                        ELSE CONCAT(N'the ', @f_log_size_mb, N' MB log file (maximum log size not known)')
                    END;

            SELECT
                @f_log_reuse_wait = d.log_reuse_wait_desc,
                @f_auto_create_stats = d.is_auto_create_stats_on,
                @f_auto_update_stats = d.is_auto_update_stats_on,
                @f_auto_shrink = d.is_auto_shrink_on,
                @f_compat = d.compatibility_level
            FROM sys.databases AS d
            WHERE d.database_id = @db_id;

            SET @f_updateability = CONVERT(nvarchar(30), DATABASEPROPERTYEX(@db_name, 'Updateability'));
        END TRY
        BEGIN CATCH
            INSERT #messages (msg_type, section, message)
            VALUES ('INFO', N'summary', LEFT(N'Storage and database options: ' + ERROR_MESSAGE(), 4000));
        END CATCH;

        /* Query Store and automatic tuning */
        BEGIN TRY
            SELECT TOP (1)
                @f_qs_actual = q.actual_state,
                @f_qs_desired = q.desired_state,
                @f_qs_state = q.actual_state_desc,
                @f_qs_readonly_reason = q.readonly_reason,
                @f_qs_used_mb = q.current_storage_size_mb,
                @f_qs_max_mb = q.max_storage_size_mb,
                @f_qs_cleanup_auto = CASE WHEN q.size_based_cleanup_mode = 1 THEN 1 ELSE 0 END
            FROM sys.database_query_store_options AS q;

            SET @f_qs_pct = 100.0 * @f_qs_used_mb / NULLIF(@f_qs_max_mb, 0);

            SELECT
                @f_at_mismatch =
                    STRING_AGG
                    (
                        CONVERT(nvarchar(max),
                            CONCAT(
                                o.name COLLATE DATABASE_DEFAULT,
                                N': desired ', o.desired_state_desc COLLATE DATABASE_DEFAULT,
                                N', actual ', o.actual_state_desc COLLATE DATABASE_DEFAULT,
                                N' (' + o.reason_desc COLLATE DATABASE_DEFAULT + N')'
                            )),
                        N'; '
                    )
            FROM sys.database_automatic_tuning_options AS o
            WHERE o.desired_state IN (0, 1)
            AND   o.desired_state <> o.actual_state;

            SELECT
                @f_regressions = COUNT(*)
            FROM sys.dm_db_tuning_recommendations AS r
            WHERE r.type = N'FORCE_LAST_GOOD_PLAN'
            AND   JSON_VALUE(r.state, '$.currentValue') = N'Active';
        END TRY
        BEGIN CATCH
            INSERT #messages (msg_type, section, message)
            VALUES ('INFO', N'summary', LEFT(N'Query Store and automatic tuning: ' + ERROR_MESSAGE(), 4000));
        END CATCH;

        /* ADR persistent version store and the session holding its oldest transaction */
        BEGIN TRY
            SELECT TOP (1)
                @f_pvs_mb = v.persistent_version_store_size_kb / 1024.0,
                @f_pvs_aborted = v.current_aborted_transaction_count,
                @f_pvs_oldest_xact = v.oldest_active_transaction_id
            FROM sys.dm_tran_persistent_version_store_stats AS v
            WHERE v.database_id = @db_id;

            SELECT TOP (1)
                @f_pvs_oldest_session = t.session_id
            FROM #trn AS t
            WHERE t.transaction_id = @f_pvs_oldest_xact;
        END TRY
        BEGIN CATCH
            INSERT #messages (msg_type, section, message)
            VALUES ('INFO', N'summary', LEFT(N'sys.dm_tran_persistent_version_store_stats: ' + ERROR_MESSAGE(), 4000));
        END CATCH;

        /* Memory health history: dynamic SQL because the view is not available everywhere */
        SET @sql = N'
SELECT TOP (1)
    @lvl = mh.severity_level,
    @lvl_desc = mh.severity_level_desc,
    @clerks = LEFT(CONVERT(nvarchar(max), mh.top_memory_clerks), 1000)
FROM sys.dm_os_memory_health_history AS mh
ORDER BY
    mh.snapshot_time DESC;

SELECT
    @high = COUNT(*)
FROM sys.dm_os_memory_health_history AS mh
WHERE mh.snapshot_time >= @window_start
AND   mh.severity_level >= 3;';

        BEGIN TRY
            IF @debug = 1 PRINT @sql;

            EXEC sys.sp_executesql
                @sql,
                N'@window_start datetime, @lvl int OUTPUT, @lvl_desc nvarchar(60) OUTPUT, @clerks nvarchar(1000) OUTPUT, @high int OUTPUT',
                @window_start,
                @f_mh_level OUTPUT,
                @f_mh_desc OUTPUT,
                @f_mh_clerks OUTPUT,
                @f_mh_high OUTPUT;
        END TRY
        BEGIN CATCH
            INSERT #messages (msg_type, section, message)
            VALUES ('INFO', N'summary', LEFT(N'sys.dm_os_memory_health_history: ' + ERROR_MESSAGE(), 4000));
        END CATCH;

        /* Blocking: chain size, head blockers and the worst head */
        BEGIN TRY
            SELECT
                @f_blocked = COUNT(DISTINCT e.waiter),
                @f_blk_max_wait_ms = MAX(e.wait_ms)
            FROM #blk_edges AS e;

            SELECT
                @f_blk_heads = COUNT(DISTINCT CASE WHEN n.is_head = 1 THEN n.session_id END),
                @f_blk_sleeping_heads = COUNT(DISTINCT CASE WHEN n.is_head = 1 AND r.session_id IS NULL THEN n.session_id END),
                @f_blk_cycle = COUNT(DISTINCT CASE WHEN n.in_cycle = 1 THEN n.session_id END)
            FROM #blk_nodes AS n
            LEFT JOIN
            (
                SELECT DISTINCT
                    rq.session_id
                FROM #req AS rq
            ) AS r
              ON r.session_id = n.session_id;

            SELECT TOP (1)
                @f_head_session = c.session_id,
                @f_head_total = c.total_blocked,
                @f_head_open_tran = s.open_transaction_count,
                @f_head_idle_s =
                    CASE
                        WHEN r.session_id IS NULL
                        THEN DATEDIFF_BIG(SECOND, ISNULL(s.last_request_end_time, s.login_time), @now)
                    END,
                @f_head_who = LEFT(CONCAT(s.login_name, N' @ ' + s.host_name, N' (' + s.program_name + N')'), 600),
                @f_head_state =
                    LEFT
                    (
                        CASE
                            WHEN r.session_id IS NULL
                            THEN CONCAT(N'sleeping (no active request)', CASE WHEN s.open_transaction_count > 0 THEN N' with an open transaction' END)
                            ELSE CONCAT(r.status, N', ', r.command, N', waiting on ' + r.wait_type, N', running ', r.total_elapsed_time / 1000, N' s')
                        END,
                        400
                    )
            FROM #blk_counts AS c
            JOIN #blk_nodes AS h
              ON  h.session_id = c.session_id
              AND h.is_head = 1
            LEFT JOIN #sess AS s
              ON s.session_id = c.session_id
            OUTER APPLY
            (
                SELECT TOP (1)
                    rq.session_id,
                    rq.status,
                    rq.command,
                    rq.wait_type,
                    rq.total_elapsed_time
                FROM #req AS rq
                WHERE rq.session_id = c.session_id
                ORDER BY
                    rq.request_id
            ) AS r
            ORDER BY
                c.total_blocked DESC,
                c.max_wait_ms DESC,
                c.session_id;
        END TRY
        BEGIN CATCH
            INSERT #messages (msg_type, section, message)
            VALUES ('INFO', N'summary', LEFT(N'Blocking facts: ' + ERROR_MESSAGE(), 4000));
        END CATCH;

        /* Requests in this database (benign waits such as WAITFOR do not count as long running) */
        BEGIN TRY
            SELECT
                @f_req_active = COUNT(*),
                @f_req_running = SUM(CASE WHEN r.status = N'running' THEN 1 ELSE 0 END),
                @f_req_runnable = SUM(CASE WHEN r.status = N'runnable' THEN 1 ELSE 0 END),
                @f_req_suspended = SUM(CASE WHEN r.status = N'suspended' THEN 1 ELSE 0 END),
                @f_req_parallel = SUM(CASE WHEN r.dop > 1 THEN 1 ELSE 0 END),
                @f_req_pageio = SUM(CASE WHEN r.wait_type LIKE N'PAGEIOLATCH%' THEN 1 ELSE 0 END),
                @f_req_long =
                    SUM
                    (
                        CASE
                            WHEN b.wait_type IS NULL
                            AND  r.total_elapsed_time >= CONVERT(bigint, @long_running_seconds) * 1000
                            THEN 1
                            ELSE 0
                        END
                    )
            FROM #req AS r
            LEFT JOIN #sess AS s
              ON s.session_id = r.session_id
            LEFT JOIN #benign_waits AS b
              ON b.wait_type = r.wait_type
            WHERE r.database_id = @db_id
            AND   ISNULL(s.is_user_process, 1) = 1;

            SELECT TOP (1)
                @f_long_s = r.total_elapsed_time / 1000,
                @f_long_desc =
                    LEFT
                    (
                        CONCAT
                        (
                            N'session ', r.session_id, N' (', r.command, N', ', r.status,
                            N', waiting on ' + r.wait_type,
                            N', CPU ', r.cpu_time / 1000, N' s',
                            CASE WHEN ISNULL(r.blocking_session_id, 0) NOT IN (0, r.session_id) THEN CONCAT(N', blocked by ', r.blocking_session_id) END,
                            N') ', s.login_name, N' (' + s.program_name + N')'
                        ),
                        600
                    )
            FROM #req AS r
            LEFT JOIN #sess AS s
              ON s.session_id = r.session_id
            LEFT JOIN #benign_waits AS b
              ON b.wait_type = r.wait_type
            WHERE r.database_id = @db_id
            AND   ISNULL(s.is_user_process, 1) = 1
            AND   b.wait_type IS NULL
            ORDER BY
                r.total_elapsed_time DESC;
        END TRY
        BEGIN CATCH
            INSERT #messages (msg_type, section, message)
            VALUES ('INFO', N'summary', LEFT(N'Request facts: ' + ERROR_MESSAGE(), 4000));
        END CATCH;

        /* Transactions of user sessions in this database, and sessions idle with a transaction open */
        BEGIN TRY
            SELECT
                @f_tran_open = COUNT(DISTINCT t.transaction_id)
            FROM #trn AS t
            JOIN #sess AS s
              ON s.session_id = t.session_id
            WHERE s.database_id = @db_id
            AND   s.is_user_process = 1;

            SELECT TOP (1)
                @f_tran_oldest_session = t.session_id,
                @f_tran_oldest_s = DATEDIFF_BIG(SECOND, ISNULL(t.transaction_begin_time, t.db_tran_begin_time), @now),
                @f_tran_oldest_state =
                    CASE
                        WHEN t.transaction_state = 7 THEN N'rolling back'
                        WHEN r.session_id IS NULL THEN N'sleeping'
                        ELSE N'running'
                    END,
                @f_tran_oldest_log_mb = t.log_bytes_used / 1048576.0
            FROM #trn AS t
            JOIN #sess AS s
              ON s.session_id = t.session_id
            LEFT JOIN
            (
                SELECT DISTINCT
                    rq.session_id
                FROM #req AS rq
            ) AS r
              ON r.session_id = t.session_id
            WHERE s.database_id = @db_id
            AND   s.is_user_process = 1
            AND   ISNULL(t.transaction_begin_time, t.db_tran_begin_time) IS NOT NULL
            /* A sleeping transaction that has done no work is not "the oldest transaction" */
            AND   (t.holds_resources = 1 OR r.session_id IS NOT NULL)
            ORDER BY
                ISNULL(t.transaction_begin_time, t.db_tran_begin_time);

            SELECT
                @f_idle_tran = COUNT(*),
                @f_idle_tran_max_s = MAX(DATEDIFF_BIG(SECOND, ISNULL(s.last_request_end_time, s.login_time), @now)),
                @f_idle_work = ISNULL(SUM(h.holds), 0),
                @f_idle_implicit = ISNULL(SUM(h.implicit), 0),
                @f_idle_work_max_s = MAX(CASE WHEN h.holds = 1 THEN DATEDIFF_BIG(SECOND, ISNULL(s.last_request_end_time, s.login_time), @now) END)
            FROM #sess AS s
            CROSS APPLY
            (
                SELECT
                    holds =
                        CASE
                            WHEN EXISTS (SELECT 1/0 FROM #trn AS th WHERE th.session_id = s.session_id AND th.holds_resources = 1) THEN 1
                            WHEN EXISTS (SELECT 1/0 FROM #blk_counts AS ch WHERE ch.session_id = s.session_id AND ch.total_blocked > 0) THEN 1
                            ELSE 0
                        END,
                    implicit =
                        CASE
                            WHEN EXISTS (SELECT 1/0 FROM #trn AS ti WHERE ti.session_id = s.session_id AND ti.transaction_name = N'implicit_transaction') THEN 1
                            ELSE 0
                        END
            ) AS h
            WHERE s.database_id = @db_id
            AND   s.is_user_process = 1
            AND   s.open_transaction_count > 0
            AND   NOT EXISTS
            (
                SELECT
                    1/0
                FROM #req AS r
                WHERE r.session_id = s.session_id
            );

            SELECT TOP (1)
                @f_idle_tran_session = s.session_id,
                @f_idle_tran_session_s = DATEDIFF_BIG(SECOND, ISNULL(s.last_request_end_time, s.login_time), @now),
                @f_idle_tran_who = LEFT(CONCAT(s.login_name, N' @ ' + s.host_name, N' (' + s.program_name + N')'), 600),
                @f_idle_tran_blocking = ISNULL(c.total_blocked, 0),
                @f_idle_tran_age_s = ta.age_s
            FROM #sess AS s
            LEFT JOIN #blk_counts AS c
              ON c.session_id = s.session_id
            OUTER APPLY
            (
                SELECT
                    age_s = DATEDIFF_BIG(SECOND, MIN(ISNULL(t.transaction_begin_time, t.db_tran_begin_time)), @now)
                FROM #trn AS t
                WHERE t.session_id = s.session_id
            ) AS ta
            CROSS APPLY
            (
                SELECT
                    holds =
                        CASE
                            WHEN EXISTS (SELECT 1/0 FROM #trn AS th WHERE th.session_id = s.session_id AND th.holds_resources = 1) THEN 1
                            WHEN EXISTS (SELECT 1/0 FROM #blk_counts AS ch WHERE ch.session_id = s.session_id AND ch.total_blocked > 0) THEN 1
                            ELSE 0
                        END,
                    implicit =
                        CASE
                            WHEN EXISTS (SELECT 1/0 FROM #trn AS ti WHERE ti.session_id = s.session_id AND ti.transaction_name = N'implicit_transaction') THEN 1
                            ELSE 0
                        END
            ) AS h
            WHERE s.database_id = @db_id
            AND   s.is_user_process = 1
            AND   s.open_transaction_count > 0
            AND   NOT EXISTS
            (
                SELECT
                    1/0
                FROM #req AS r
                WHERE r.session_id = s.session_id
            )
            ORDER BY
                h.holds DESC,
                ISNULL(c.total_blocked, 0) DESC,
                ISNULL(s.last_request_end_time, s.login_time),
                s.session_id;

            SELECT
                @f_sess_user = SUM(CASE WHEN s.is_user_process = 1 THEN 1 ELSE 0 END),
                @f_sess_db = SUM(CASE WHEN s.is_user_process = 1 AND s.database_id = @db_id THEN 1 ELSE 0 END),
                @f_sess_sleeping = SUM(CASE WHEN s.is_user_process = 1 AND s.database_id = @db_id AND s.status = N'sleeping' THEN 1 ELSE 0 END)
            FROM #sess AS s;
        END TRY
        BEGIN CATCH
            INSERT #messages (msg_type, section, message)
            VALUES ('INFO', N'summary', LEFT(N'Transaction and session facts: ' + ERROR_MESSAGE(), 4000));
        END CATCH;

        /* Memory grants (pending = no grant_time yet) and tasks waiting for a worker thread */
        BEGIN TRY
            SELECT
                @f_grants_pending = SUM(CASE WHEN g.grant_time IS NULL THEN 1 ELSE 0 END),
                @f_grants_active = SUM(CASE WHEN g.grant_time IS NOT NULL THEN 1 ELSE 0 END),
                @f_grant_wait_ms = MAX(CASE WHEN g.grant_time IS NULL THEN g.wait_time_ms END),
                @f_granted_mb = SUM(CASE WHEN g.grant_time IS NOT NULL THEN g.granted_memory_kb ELSE 0 END) / 1024.0
            FROM #grants AS g;

            SELECT
                @f_threadpool_tasks = COUNT(*)
            FROM #wt AS w
            WHERE w.wait_type = N'THREADPOOL'
            AND   w.task_rank = 1;

            SELECT
                @f_compile_now = COUNT(*)
            FROM #wt AS w
            WHERE w.wait_type = N'RESOURCE_SEMAPHORE_QUERY_COMPILE'
            AND   w.task_rank = 1;

            /* The largest grant that has been held for a minute or more and is mostly unused, and
               the memory that the user pool can grant in total */
            SELECT TOP (1)
                @f_grant_big_session = g.session_id,
                @f_grant_big_mb = g.granted_memory_kb / 1024.0,
                @f_grant_big_used_mb = ISNULL(g.max_used_memory_kb, 0) / 1024.0,
                @f_grant_big_s = DATEDIFF_BIG(SECOND, g.grant_time, @now),
                @f_grant_big_dop = g.dop
            FROM #grants AS g
            LEFT JOIN #sess AS s
              ON s.session_id = g.session_id
            WHERE g.grant_time IS NOT NULL
            AND   g.granted_memory_kb >= 1048576
            AND   ISNULL(g.max_used_memory_kb, 0) < 0.10 * g.granted_memory_kb
            AND   DATEDIFF_BIG(SECOND, g.grant_time, @now) >= 60
            AND   ISNULL(s.database_id, @db_id) = @db_id
            ORDER BY
                g.granted_memory_kb DESC;

            SELECT
                @f_grant_target_mb = SUM(CONVERT(bigint, rs.target_memory_kb)) / 1024.0
            FROM sys.dm_exec_query_resource_semaphores AS rs
            WHERE rs.pool_id = @user_pool_id;
        END TRY
        BEGIN CATCH
            INSERT #messages (msg_type, section, message)
            VALUES ('INFO', N'summary', LEFT(N'Memory grant and worker facts: ' + ERROR_MESSAGE(), 4000));
        END CATCH;

        /* What tasks in this database are waiting on right now, and any Azure governance waits */
        BEGIN TRY
            SELECT
                @f_waits_now =
                    STRING_AGG(CONVERT(nvarchar(max), CONCAT(x.wait_type, N' x', x.tasks, N' (max ', x.max_ms, N' ms)')), N', ')
                        WITHIN GROUP (ORDER BY x.rn),
                @f_top_wait_now = MAX(CASE WHEN x.rn = 1 THEN x.wait_type END)
            FROM
            (
                SELECT TOP (5)
                    wt.wait_type,
                    tasks = COUNT(*),
                    max_ms = MAX(wt.wait_duration_ms),
                    rn = ROW_NUMBER() OVER (ORDER BY SUM(wt.wait_duration_ms) DESC, wt.wait_type)
                FROM #wt AS wt
                JOIN #sess AS s
                  ON s.session_id = wt.session_id
                LEFT JOIN #benign_waits AS b
                  ON b.wait_type = wt.wait_type
                WHERE wt.task_rank = 1
                AND   s.database_id = @db_id
                AND   s.is_user_process = 1
                AND   b.wait_type IS NULL
                GROUP BY
                    wt.wait_type
                ORDER BY
                    SUM(wt.wait_duration_ms) DESC,
                    wt.wait_type
            ) AS x;

            SELECT
                @f_gov_now = SUM(x.tasks),
                @f_gov_now_types =
                    STRING_AGG(CONVERT(nvarchar(max), CONCAT(x.wait_type, N' x', x.tasks)), N', ')
                        WITHIN GROUP (ORDER BY x.tasks DESC, x.wait_type)
            FROM
            (
                SELECT
                    wt.wait_type,
                    tasks = COUNT(*)
                FROM #wt AS wt
                JOIN #sess AS s
                  ON s.session_id = wt.session_id
                WHERE wt.task_rank = 1
                AND   s.database_id = @db_id
                AND   EXISTS
                (
                    SELECT
                        1/0
                    FROM @f_gov AS g
                    WHERE wt.wait_type LIKE g.pattern
                )
                GROUP BY
                    wt.wait_type
            ) AS x;
        END TRY
        BEGIN CATCH
            INSERT #messages (msg_type, section, message)
            VALUES ('INFO', N'summary', LEFT(N'Current wait facts: ' + ERROR_MESSAGE(), 4000));
        END CATCH;

        /* Database wait stats over the sample window (cumulative values are not "now", so skipped) */
        IF @is_sampled = 1
        BEGIN
            BEGIN TRY
                /* For each wait type the larger of two sources: the database wait statistics (they
                   include tasks without a session, such as THREADPOOL) and the session wait
                   statistics (they include requests that still run). */
                INSERT @f_wd (wait_type, wait_ms, tasks, is_gov)
                SELECT
                    y.wait_type,
                    y.wait_ms,
                    y.tasks,
                    CASE
                        WHEN EXISTS (SELECT 1/0 FROM @f_gov AS g WHERE y.wait_type LIKE g.pattern)
                        THEN 1
                        ELSE 0
                    END
                FROM
                (
                    SELECT
                        x.wait_type,
                        wait_ms = MAX(x.wait_ms),
                        tasks = MAX(x.tasks)
                    FROM
                    (
                        SELECT
                            s2.wait_type,
                            wait_ms = s2.wait_time_ms - ISNULL(s1.wait_time_ms, 0),
                            tasks = s2.waiting_tasks_count - ISNULL(s1.waiting_tasks_count, 0)
                        FROM #waits_snap AS s2
                        LEFT JOIN #waits_snap AS s1
                          ON  s1.sample_no = 1
                          AND s1.wait_type = s2.wait_type
                        WHERE s2.sample_no = 2

                        UNION ALL

                        SELECT
                            w2.wait_type,
                            SUM(w2.wait_time_ms - ISNULL(w1.wait_time_ms, 0)),
                            SUM(w2.waiting_tasks_count - ISNULL(w1.waiting_tasks_count, 0))
                        FROM #sess_waits_snap AS w2
                        LEFT JOIN #sess_waits_snap AS w1
                          ON  w1.sample_no = 1
                          AND w1.session_id = w2.session_id
                          AND w1.wait_type = w2.wait_type
                        WHERE w2.sample_no = 2
                        AND   w2.wait_time_ms - ISNULL(w1.wait_time_ms, 0) > 0
                        GROUP BY
                            w2.wait_type
                    ) AS x
                    WHERE x.wait_ms > 0
                    AND   NOT EXISTS
                    (
                        SELECT
                            1/0
                        FROM #benign_waits AS b
                        WHERE b.wait_type = x.wait_type
                    )
                    GROUP BY
                        x.wait_type
                ) AS y;

                SELECT
                    @f_wait_total_ms = SUM(d.wait_ms),
                    @f_wait_gov_ms = SUM(CASE WHEN d.is_gov = 1 THEN d.wait_ms ELSE 0 END),
                    @f_wait_threadpool_ms = SUM(CASE WHEN d.wait_type = N'THREADPOOL' THEN d.wait_ms ELSE 0 END),
                    @f_wait_compile_ms = SUM(CASE WHEN d.wait_type = N'RESOURCE_SEMAPHORE_QUERY_COMPILE' THEN d.wait_ms ELSE 0 END),
                    @f_wait_ioretry_ms = SUM(CASE WHEN d.wait_type = N'IO_RETRY' THEN d.wait_ms ELSE 0 END)
                FROM @f_wd AS d;

                SELECT
                    @f_waits_delta =
                        STRING_AGG(CONVERT(nvarchar(max), CONCAT(x.wait_type, N' ', x.wait_ms, N' ms')), N', ')
                            WITHIN GROUP (ORDER BY x.rn),
                    @f_top_wait_delta = MAX(CASE WHEN x.rn = 1 THEN x.wait_type END)
                FROM
                (
                    SELECT TOP (5)
                        d.wait_type,
                        d.wait_ms,
                        rn = ROW_NUMBER() OVER (ORDER BY d.wait_ms DESC, d.wait_type)
                    FROM @f_wd AS d
                    ORDER BY
                        d.wait_ms DESC,
                        d.wait_type
                ) AS x;
            END TRY
            BEGIN CATCH
                INSERT #messages (msg_type, section, message)
                VALUES ('INFO', N'summary', LEFT(N'Sampled wait facts: ' + ERROR_MESSAGE(), 4000));
            END CATCH;
        END;

        /* File IO for this database (delta when sampled, otherwise since instance start). Data
           includes the Hyperscale local SSD cache; Hyperscale page server writes are simulated, so
           only page server reads count. */
        BEGIN TRY
            SELECT
                @f_io_data_ios = SUM(CASE WHEN d.is_log = 0 THEN d.ios ELSE 0 END),
                @f_io_data_stall_ms = SUM(CASE WHEN d.is_log = 0 THEN d.stall_ms ELSE 0 END),
                @f_io_data_queued_ms = SUM(CASE WHEN d.is_log = 0 THEN d.queued_ms ELSE 0 END),
                @f_io_log_writes = SUM(CASE WHEN d.is_log = 1 THEN d.writes ELSE 0 END),
                @f_io_log_stall_ms = SUM(CASE WHEN d.is_log = 1 THEN d.write_stall_ms ELSE 0 END),
                @f_io_read_count = SUM(CASE WHEN d.is_log = 0 AND d.is_cache = 0 THEN d.reads ELSE 0 END),
                @f_io_read_stall_ms = SUM(CASE WHEN d.is_log = 0 AND d.is_cache = 0 THEN d.read_stall_ms ELSE 0 END)
            FROM
            (
                SELECT
                    is_log = CASE WHEN df.type = 1 THEN 1 ELSE 0 END,
                    is_cache = CASE WHEN s2.database_id = 0 THEN 1 ELSE 0 END,
                    reads = s2.num_of_reads - ISNULL(s1.num_of_reads, 0),
                    read_stall_ms = s2.io_stall_read_ms - ISNULL(s1.io_stall_read_ms, 0),
                    ios =
                        (s2.num_of_reads - ISNULL(s1.num_of_reads, 0))
                        + CASE WHEN @is_hyperscale = 1 AND s2.database_id = @db_id AND df.type = 0 THEN 0 ELSE s2.num_of_writes - ISNULL(s1.num_of_writes, 0) END,
                    stall_ms =
                        (s2.io_stall_read_ms - ISNULL(s1.io_stall_read_ms, 0))
                        + CASE WHEN @is_hyperscale = 1 AND s2.database_id = @db_id AND df.type = 0 THEN 0 ELSE s2.io_stall_write_ms - ISNULL(s1.io_stall_write_ms, 0) END,
                    queued_ms =
                        (ISNULL(s2.io_stall_queued_read_ms, 0) - ISNULL(s1.io_stall_queued_read_ms, 0))
                        + CASE WHEN @is_hyperscale = 1 AND s2.database_id = @db_id AND df.type = 0 THEN 0 ELSE ISNULL(s2.io_stall_queued_write_ms, 0) - ISNULL(s1.io_stall_queued_write_ms, 0) END,
                    writes = s2.num_of_writes - ISNULL(s1.num_of_writes, 0),
                    write_stall_ms = s2.io_stall_write_ms - ISNULL(s1.io_stall_write_ms, 0)
                FROM #file_snap AS s2
                LEFT JOIN #file_snap AS s1
                  ON  s1.sample_no = 1
                  AND s1.database_id = s2.database_id
                  AND s1.file_id = s2.file_id
                LEFT JOIN sys.database_files AS df
                  ON  s2.database_id = @db_id
                  AND df.file_id = s2.file_id
                WHERE s2.sample_no = 2
                AND
                (
                    s2.database_id = @db_id
                    OR (s2.database_id = 0 AND @is_hyperscale = 1)
                )
            ) AS d;
        END TRY
        BEGIN CATCH
            INSERT #messages (msg_type, section, message)
            VALUES ('INFO', N'summary', LEFT(N'File IO facts: ' + ERROR_MESSAGE(), 4000));
        END CATCH;

        /* Replicas, perf counter rates and tempdb */
        BEGIN TRY
            SELECT
                @f_replica_rows = COUNT(*),
                @f_geo_lag_s = MAX(CASE WHEN r.sort_group = 2 THEN r.lag_seconds END),
                @f_ha_bad =
                    SUM
                    (
                        CASE
                            WHEN r.sort_group = 1
                            AND  (r.is_suspended = 1 OR r.health IN (N'NOT_HEALTHY', N'PARTIALLY_HEALTHY'))
                            THEN 1
                            ELSE 0
                        END
                    ),
                @f_ha_sev =
                    MIN
                    (
                        CASE
                            WHEN r.sort_group = 1 AND (r.is_suspended = 1 OR r.health = N'NOT_HEALTHY') THEN 2
                            WHEN r.sort_group = 1 AND r.health = N'PARTIALLY_HEALTHY' THEN 3
                        END
                    )
            FROM #replicas AS r;

            SELECT TOP (1)
                @f_geo_partner = LEFT(CONCAT(r.replica, N' (this database is the ', r.role, N', link state ', r.state, N')'), 600)
            FROM #replicas AS r
            WHERE r.sort_group = 2
            ORDER BY
                r.lag_seconds DESC;

            SELECT
                @f_ha_desc =
                    LEFT
                    (
                        STRING_AGG
                        (
                            CONVERT(nvarchar(max),
                                CONCAT(
                                    r.replica, N' ', r.role, N': ', r.state,
                                    N', health ' + r.health,
                                    CASE WHEN r.is_suspended = 1 THEN CONCAT(N', suspended', N' (' + r.suspend_reason + N')') END
                                )),
                            N'; '
                        ) WITHIN GROUP (ORDER BY r.replica),
                        2000
                    )
            FROM #replicas AS r
            WHERE r.sort_group = 1
            AND   (r.is_suspended = 1 OR r.health IN (N'NOT_HEALTHY', N'PARTIALLY_HEALTHY'));

            SELECT
                @f_batches = SUM(CASE WHEN d.counter_name = N'Batch Requests/sec' THEN d.delta END),
                @f_compiles = SUM(CASE WHEN d.counter_name = N'SQL Compilations/sec' THEN d.delta END),
                @f_recompiles = SUM(CASE WHEN d.counter_name = N'SQL Re-Compilations/sec' THEN d.delta END),
                @f_attentions = SUM(CASE WHEN d.counter_name = N'SQL Attention rate' AND @is_sampled = 1 THEN d.delta END),
                @f_deadlocks_delta = SUM(CASE WHEN d.counter_name = N'Number of Deadlocks/sec' AND @is_sampled = 1 THEN d.delta END)
            FROM
            (
                SELECT
                    p2.counter_name,
                    delta = p2.cntr_value - ISNULL(p1.cntr_value, 0)
                FROM #perf_snap AS p2
                LEFT JOIN #perf_snap AS p1
                  ON  p1.sample_no = 1
                  AND p1.object_name = p2.object_name
                  AND p1.counter_name = p2.counter_name
                  AND ISNULL(p1.instance_name, N'') = ISNULL(p2.instance_name, N'')
                WHERE p2.sample_no = 2
                AND   p2.cntr_type = 272696576
                AND   p2.counter_name IN (N'Batch Requests/sec', N'SQL Compilations/sec', N'SQL Re-Compilations/sec', N'SQL Attention rate', N'Number of Deadlocks/sec')
                AND   (p2.counter_name <> N'Number of Deadlocks/sec' OR p2.instance_name = N'_Total')
            ) AS d;

            SET @f_counter_s =
                CASE
                    WHEN @is_sampled = 1 THEN @sample_s
                    ELSE CONVERT(decimal(18, 3), DATEDIFF_BIG(SECOND, @instance_start, @now))
                END;

            SELECT
                @f_tdb_data_used_mb = MAX(CASE WHEN t.file_type = N'data' THEN t.used_mb END),
                @f_tdb_data_max_mb = MAX(CASE WHEN t.file_type = N'data' THEN t.max_size_mb END),
                @f_tdb_data_pct = MAX(CASE WHEN t.file_type = N'data' AND t.max_size_mb > 0 THEN 100.0 * t.used_mb / t.max_size_mb END),
                @f_tdb_log_pct = MAX(CASE WHEN t.file_type = N'log' AND t.max_size_mb > 0 THEN 100.0 * t.used_mb / t.max_size_mb END)
            FROM #tempdb_space AS t;

            SELECT TOP (1)
                @f_tdb_top_session = u.session_id,
                @f_tdb_top_mb =
                    (ISNULL(u.session_user_pages, 0) + ISNULL(u.session_internal_pages, 0)
                     + ISNULL(u.task_user_pages, 0) + ISNULL(u.task_internal_pages, 0)) / 128.0
            FROM #tsu AS u
            WHERE u.session_id <> @@SPID
            AND   ISNULL(u.session_user_pages, 0) + ISNULL(u.session_internal_pages, 0)
                  + ISNULL(u.task_user_pages, 0) + ISNULL(u.task_internal_pages, 0) > 0
            ORDER BY
                ISNULL(u.session_user_pages, 0) + ISNULL(u.session_internal_pages, 0)
                + ISNULL(u.task_user_pages, 0) + ISNULL(u.task_internal_pages, 0) DESC;
        END TRY
        BEGIN CATCH
            INSERT #messages (msg_type, section, message)
            VALUES ('INFO', N'summary', LEFT(N'Replica, counter and tempdb facts: ' + ERROR_MESSAGE(), 4000));
        END CATCH;

        /* Forced plans and Query Store hints that failed to apply */
        SELECT
            @f_force_total = COUNT(*),
            @f_force_failed = ISNULL(SUM(CASE WHEN f.failure_count > 0 THEN 1 ELSE 0 END), 0)
        FROM #forcing AS f;

        SELECT TOP (1)
            @f_force_example =
                LEFT
                (
                    CONCAT
                    (
                        f.kind, N' for query_id ', f.query_id, N', plan_id ' + CONVERT(nvarchar(20), f.plan_id), N': ', f.failure_count,
                        N' failure(s), last reason ', ISNULL(NULLIF(f.last_failure_reason, N''), N'n/a')
                    ),
                    400
                )
        FROM #forcing AS f
        WHERE f.failure_count > 0
        ORDER BY
            f.failure_count DESC,
            f.query_id;

        /* Requests that are rolling back (5 seconds or more, so a normal ROLLBACK statement does not count) */
        BEGIN TRY
            SELECT
                @f_rollback = COUNT(*),
                @f_rollback_blocking = ISNULL(SUM(CASE WHEN c.total_blocked > 0 THEN 1 ELSE 0 END), 0)
            FROM #req AS r
            LEFT JOIN #blk_counts AS c
              ON c.session_id = r.session_id
            WHERE r.database_id = @db_id
            AND   r.total_elapsed_time >= 5000
            AND
            (
                r.status = N'rollback'
                OR r.command LIKE N'%ROLLBACK%'
                OR EXISTS (SELECT 1/0 FROM #trn AS t WHERE t.session_id = r.session_id AND t.transaction_state = 7)
            );

            SELECT TOP (1)
                @f_rollback_desc =
                    LEFT
                    (
                        CONCAT
                        (
                            N'session ', r.session_id, N' (', r.command, N', ', r.status, N'), running ', r.total_elapsed_time / 1000, N' s',
                            N', ' + CONVERT(nvarchar(20), CONVERT(decimal(9, 1), NULLIF(r.percent_complete, 0))) + N'% complete',
                            CASE WHEN c.total_blocked > 0 THEN CONCAT(N', blocking ', c.total_blocked, N' session(s)') END,
                            N'; ', s.login_name, N' (' + s.program_name + N')'
                        ),
                        600
                    )
            FROM #req AS r
            LEFT JOIN #blk_counts AS c
              ON c.session_id = r.session_id
            LEFT JOIN #sess AS s
              ON s.session_id = r.session_id
            WHERE r.database_id = @db_id
            AND   r.total_elapsed_time >= 5000
            AND
            (
                r.status = N'rollback'
                OR r.command LIKE N'%ROLLBACK%'
                OR EXISTS (SELECT 1/0 FROM #trn AS t WHERE t.session_id = r.session_id AND t.transaction_state = 7)
            )
            ORDER BY
                ISNULL(c.total_blocked, 0) DESC,
                r.total_elapsed_time DESC;
        END TRY
        BEGIN CATCH
            INSERT #messages (msg_type, section, message)
            VALUES ('INFO', N'summary', LEFT(N'Rollback facts: ' + ERROR_MESSAGE(), 4000));
        END CATCH;

        /* Identity columns that count up and have used 90% or more of the range of their data type */
        BEGIN TRY
            SELECT
                @f_identity_count = COUNT(*),
                @f_identity_max_pct = MAX(x.pct_used),
                @f_identity_list =
                    LEFT
                    (
                        STRING_AGG
                        (
                            CASE
                                WHEN x.rnk <= 5
                                THEN CONVERT(nvarchar(max), CONCAT(x.column_ref, N' ', CONVERT(decimal(9, 1), x.pct_used), N'% of ', x.type_name))
                            END,
                            N'; '
                        ) WITHIN GROUP (ORDER BY x.rnk),
                        1600
                    )
            FROM
            (
                SELECT
                    column_ref = QUOTENAME(sc.name) + N'.' + QUOTENAME(o.name) + N'.' + QUOTENAME(ic.name),
                    type_name = m.type_name,
                    pct_used = 100.0 * TRY_CONVERT(float, ic.last_value) / m.max_value,
                    rnk = ROW_NUMBER() OVER (ORDER BY TRY_CONVERT(float, ic.last_value) / m.max_value DESC, ic.object_id)
                FROM sys.identity_columns AS ic
                JOIN sys.objects AS o
                  ON o.object_id = ic.object_id
                JOIN sys.schemas AS sc
                  ON sc.schema_id = o.schema_id
                CROSS APPLY
                (
                    SELECT
                        max_value =
                            CASE ic.system_type_id
                                WHEN 48 THEN CONVERT(float, 255)
                                WHEN 52 THEN CONVERT(float, 32767)
                                WHEN 56 THEN CONVERT(float, 2147483647)
                                WHEN 127 THEN CONVERT(float, 9223372036854775807)
                            END,
                        type_name =
                            CASE ic.system_type_id
                                WHEN 48 THEN N'tinyint'
                                WHEN 52 THEN N'smallint'
                                WHEN 56 THEN N'int'
                                WHEN 127 THEN N'bigint'
                            END
                ) AS m
                WHERE o.is_ms_shipped = 0
                AND   o.type = 'U'
                AND   ic.system_type_id IN (48, 52, 56, 127)
                AND   TRY_CONVERT(float, ic.increment_value) > 0
                AND   TRY_CONVERT(float, ic.last_value) >= 0.90 * m.max_value
            ) AS x;
        END TRY
        BEGIN CATCH
            INSERT #messages (msg_type, section, message)
            VALUES ('INFO', N'summary', LEFT(N'Identity column facts: ' + ERROR_MESSAGE(), 4000));
        END CATCH;

        /* ----------------------------------------------------------------------------------------
           Findings. Severity: 1 critical, 2 high, 3 medium, 4 low, 5 info. Each group is
           isolated so a problem in one rule cannot suppress the others.
           ---------------------------------------------------------------------------------------- */
        BEGIN TRY
            INSERT #findings (severity_rank, area, finding, evidence, recommended_action, see_section, code)
            SELECT
                v.sev,
                v.area,
                LEFT(v.finding, 400),
                LEFT(v.evidence, 2000),
                LEFT(v.action, 2000),
                v.see,
                v.code
            FROM
            (
                VALUES
                (
                    CASE
                        WHEN @f_cpu_now >= 90 OR @f_cpu_avg5 >= 85 THEN 2
                        WHEN @f_cpu_avg5 >= 75 THEN 3
                    END,
                    N'CPU',
                    CASE
                        WHEN @f_cpu_now >= 90 OR @f_cpu_avg5 >= 85 THEN N'CPU is at or near the service objective limit'
                        ELSE N'CPU usage is high'
                    END,
                    CONCAT
                    (
                        N'avg_cpu_percent latest ', @f_cpu_now, N'%, 5-min avg ', @f_cpu_avg5, N'%, 5-min max ', @f_cpu_max5,
                        N'% (', @f_rs_samples, N' samples); vCores ', @rg_cpu_limit,
                        N'; requests running ', ISNULL(@f_req_running, 0), N', runnable ', ISNULL(@f_req_runnable, 0),
                        N', parallel ', ISNULL(@f_req_parallel, 0),
                        N'; runnable tasks per scheduler ', ISNULL(CONVERT(nvarchar(20), @f_runnable_avg), N'n/a')
                    ),
                    N'Find the top CPU consumers in requests (cpu_time, or the CPU delta with @sample_seconds) and in plan_cache_top / query_store_top. Look for plan regressions, missing indexes and excessive parallelism; scale up if the load is legitimate.',
                    N'resource_stats, requests, plan_cache_top, query_store_top',
                    N'CPU_LIMIT'
                ),
                (
                    CASE WHEN @f_icpu_avg5 >= 90 AND ISNULL(@f_cpu_avg5, 0) < 75 THEN 2 END,
                    N'CPU',
                    N'SQL instance CPU is high although the user workload CPU is not',
                    CONCAT(N'avg_instance_cpu_percent 5-min avg ', @f_icpu_avg5, N'%, latest ', @f_icpu_now, N'%; avg_cpu_percent 5-min avg ', @f_cpu_avg5, N'%'),
                    N'CPU is used outside this database''s user workload: other databases in the elastic pool, or background work such as ADR version cleanup, ghost cleanup, automatic statistics updates or Query Store. Check the pool and the system requests.',
                    N'resource_stats, requests',
                    N'INSTANCE_CPU_HIGH'
                ),
                (
                    CASE WHEN @f_workers_pct >= 95 THEN 1 WHEN @f_workers_pct >= 80 THEN 2 END,
                    N'Workers',
                    CASE
                        WHEN @f_workers_pct >= 95 THEN N'Worker threads are at the limit: new requests fail with error 10928 or queue'
                        ELSE N'Worker thread usage is close to the limit'
                    END,
                    CONCAT
                    (
                        N'max_worker_percent latest ', @f_workers_now, N'%, 5-min max ', @f_workers_max5,
                        N'%; active workers now ', @f_wg_active_workers, N' of ', @rg_max_workers,
                        N'; requests ', ISNULL(@f_req_active, 0), N' (parallel ', ISNULL(@f_req_parallel, 0),
                        N'); blocked sessions ', ISNULL(@f_blocked, 0)
                    ),
                    N'Workers pile up behind blocking and parallel queries. Resolve blocking first (blocking_tree), reduce the DOP of heavy parallel queries, and look for connection or retry storms in sessions_by_app. A larger service objective raises the worker limit.',
                    N'blocking_tree, requests, workload_group, sessions_by_app',
                    N'WORKERS_LIMIT'
                ),
                (
                    CASE
                        WHEN @f_threadpool_tasks > 0 OR @f_wg_queued > 0 THEN 1
                        WHEN @f_wait_threadpool_ms > 0 THEN 2
                        WHEN @f_work_queue > 0 THEN 3
                    END,
                    N'Workers',
                    N'Requests are waiting for a worker thread (THREADPOOL)',
                    CONCAT
                    (
                        N'tasks waiting on THREADPOOL now ', ISNULL(@f_threadpool_tasks, 0),
                        N'; queued requests in the workload group ', ISNULL(@f_wg_queued, 0),
                        N'; scheduler work queue ', ISNULL(@f_work_queue, 0),
                        CASE WHEN @is_sampled = 1 THEN CONCAT(N'; THREADPOOL wait during the sample ', ISNULL(@f_wait_threadpool_ms, 0), N' ms') END
                    ),
                    N'Worker starvation: new requests and logins stall or time out. It is usually caused by a large blocking chain or many parallel requests holding workers; find it in blocking_tree and requests before scaling up.',
                    N'blocking_tree, requests, workload_group, schedulers',
                    N'THREADPOOL_WAITS'
                ),
                (
                    CASE WHEN @f_sessions_now >= 80 OR @f_sessions_max5 >= 80 THEN 2 END,
                    N'Sessions',
                    N'Session count is close to the service objective limit',
                    CONCAT
                    (
                        N'max_session_percent latest ', @f_sessions_now, N'%, 5-min max ', @f_sessions_max5,
                        N'%; user sessions ', ISNULL(@f_sess_user, 0), N' (', ISNULL(@f_sess_db, 0), N' in this database, ',
                        ISNULL(@f_sess_sleeping, 0), N' sleeping); limit ', ISNULL(CONVERT(nvarchar(20), @rg_max_sessions), N'n/a')
                    ),
                    N'Check sessions_by_app for a connection leak or oversized connection pools. At the limit new logins fail with error 10928.',
                    N'sessions_by_app, governance',
                    N'SESSIONS_LIMIT'
                ),
                (
                    CASE WHEN @f_log_now >= 90 OR @f_log_avg5 >= 80 THEN 2 END,
                    N'Log rate',
                    N'Transaction log generation is at the service objective log rate limit',
                    CONCAT
                    (
                        N'avg_log_write_percent latest ', @f_log_now, N'%, 5-min avg ', @f_log_avg5,
                        N'%; log rate limit ', ISNULL(CONVERT(nvarchar(20), @rg_max_log_rate_mbps), N'n/a'), N' MB/s',
                        CASE WHEN @f_gov_now > 0 THEN CONCAT(N'; governance waits now: ', @f_gov_now_types) END
                    ),
                    N'Large modifications, index rebuilds, bulk loads or bursts of small commits use up the log rate and commits slow down (LOG_RATE_GOVERNOR). Find the writers in requests (writes) and open_transactions (log used); batch or reschedule them, or scale up.',
                    N'resource_stats, requests, open_transactions, wait_stats',
                    N'LOG_RATE_LIMIT'
                ),
                (
                    CASE WHEN @f_io_now >= 90 OR @f_io_avg5 >= 80 THEN 2 END,
                    N'Data IO',
                    N'Data IO is at the service objective limit',
                    CONCAT
                    (
                        N'avg_data_io_percent latest ', @f_io_now, N'%, 5-min avg ', @f_io_avg5,
                        N'%; requests waiting on PAGEIOLATCH now ', ISNULL(@f_req_pageio, 0),
                        CASE WHEN @is_hyperscale = 1 THEN N' (Hyperscale: the percentage covers the local SSD cache and tempdb)' END
                    ),
                    N'Large scans, spills and memory pressure drive data IO. Check requests and plan_cache_top by reads, missing indexes and tempdb spills; scale up if the load is legitimate.',
                    N'resource_stats, requests, plan_cache_top, file_io',
                    N'DATA_IO_LIMIT'
                ),
                (
                    CASE
                        WHEN @f_wait_gov_ms >= 1000 AND @f_wait_gov_ms >= 0.1 * @f_wait_total_ms THEN 2
                        WHEN @f_gov_now >= 3 THEN 2
                        WHEN @f_gov_now > 0 OR @f_wait_gov_ms >= 1000 THEN 3
                    END,
                    N'Governance',
                    N'Azure resource governance is throttling this database',
                    CONCAT
                    (
                        CASE WHEN @f_gov_now > 0 THEN CONCAT(N'tasks waiting now: ', @f_gov_now_types) END,
                        CASE WHEN @f_gov_now > 0 AND @f_wait_gov_ms > 0 THEN N'; ' END,
                        CASE
                            WHEN @f_wait_gov_ms > 0
                            THEN CONCAT(N'governance waits during the sample ', @f_wait_gov_ms, N' ms of ', @f_wait_total_ms, N' ms total (',
                                        CONVERT(decimal(9, 1), 100.0 * @f_wait_gov_ms / NULLIF(@f_wait_total_ms, 0)), N'%)')
                        END
                    ),
                    N'LOG_RATE_GOVERNOR, POOL_LOG_RATE_GOVERNOR, HADR_THROTTLE_LOG_RATE_* and RBIO_RG_* mean log generation is throttled (on Hyperscale RBIO_RG_* can also mean a page server or replica is behind): batch writes, avoid huge transactions, reschedule index maintenance. IO_QUEUE_LIMIT means the data IOPS limit: reduce scans and spills. RESMGR_THROTTLED means the request limit. Scale up if the load is legitimate.',
                    N'waits_now, wait_stats, resource_stats, file_io',
                    N'GOVERNANCE_THROTTLING'
                ),
                (
                    CASE WHEN @f_grants_pending > 0 THEN 2 END,
                    N'Memory',
                    N'Queries are waiting for memory grants (RESOURCE_SEMAPHORE)',
                    CONCAT
                    (
                        @f_grants_pending, N' pending grant(s), longest wait ', ISNULL(@f_grant_wait_ms, 0), N' ms; ',
                        ISNULL(@f_grants_active, 0), N' active grant(s) holding ', ISNULL(@f_granted_mb, 0),
                        N' MB; memory usage ', ISNULL(CONVERT(nvarchar(20), @f_mem_now), N'n/a'), N'%'
                    ),
                    N'Compare requested and used memory in memory_grants: oversized grants come from bad estimates and large sorts or hashes. Fix the query or index, or cap the grant with a MAX_GRANT_PERCENT hint (a Query Store hint works without code changes).',
                    N'memory_grants, resource_semaphores, requests',
                    N'MEMORY_GRANTS_PENDING'
                ),
                (
                    CASE
                        WHEN @f_grant_big_mb >= 0.20 * @f_grant_target_mb THEN 3
                        WHEN @f_grant_big_mb >= 0.05 * @f_grant_target_mb THEN 4
                        WHEN @f_grant_target_mb IS NULL AND @f_grant_big_mb >= 10240 THEN 4
                    END,
                    N'Memory',
                    CONCAT
                    (
                        N'A query holds a ', CONVERT(decimal(19, 1), @f_grant_big_mb / 1024.0), N' GB memory grant and has used ',
                        CONVERT(decimal(9, 1), 100.0 * @f_grant_big_used_mb / NULLIF(@f_grant_big_mb, 0)), N'% of it'
                    ),
                    CONCAT
                    (
                        N'session ', @f_grant_big_session, N': granted ', @f_grant_big_mb, N' MB, most used so far ', @f_grant_big_used_mb,
                        N' MB, held for ', @f_grant_big_s, N' s, DOP ', ISNULL(CONVERT(nvarchar(12), @f_grant_big_dop), N'n/a'),
                        N'; the grant is ' + CONVERT(nvarchar(20), CONVERT(decimal(9, 1), 100.0 * @f_grant_big_mb / NULLIF(@f_grant_target_mb, 0)))
                        + N'% of the ' + CONVERT(nvarchar(30), @f_grant_target_mb) + N' MB that the user pool can grant'
                    ),
                    N'The grant stays reserved until the query ends, and other queries that need a large grant can then wait (RESOURCE_SEMAPHORE). The estimate is too high: stale statistics, a row estimate far above the real row count, or wide columns in a sort or hash. Update the statistics, return and sort fewer and narrower columns, or cap the grant with a MAX_GRANT_PERCENT hint (a Query Store hint needs no code change). Memory grant feedback, when it is enabled, lowers the grant for later executions of the same plan.',
                    N'memory_grants, requests, query_store_top',
                    N'MEMORY_GRANT_UNUSED'
                ),
                (
                    /* Snapshots arrive about every 15 seconds; one or two HIGH snapshots are a brief blip */
                    CASE WHEN @f_mh_level >= 3 THEN 2 WHEN @f_mh_high >= 4 THEN 3 WHEN @f_mh_high > 0 THEN 4 END,
                    N'Memory',
                    CASE
                        WHEN @f_mh_level >= 3 THEN N'Memory health is at HIGH severity now'
                        WHEN @f_mh_high >= 4 THEN N'Memory health reached HIGH severity repeatedly'
                        ELSE N'Memory health briefly reached HIGH severity'
                    END,
                    CONCAT
                    (
                        N'latest severity ', ISNULL(@f_mh_desc, N'n/a'), N'; HIGH snapshots in the last ', @lookback_minutes, N' min: ',
                        ISNULL(@f_mh_high, 0), CASE WHEN @f_mh_clerks IS NOT NULL THEN CONCAT(N'; top clerks: ', @f_mh_clerks) END
                    ),
                    N'Out-of-memory errors (701) become likely. Check memory_clerks for a clerk that keeps growing and memory_grants for very large grants.',
                    N'memory_health, memory_clerks, memory_grants',
                    N'MEMORY_HEALTH'
                ),
                (
                    CASE WHEN @f_compile_now > 0 OR @f_wait_compile_ms >= 1000 THEN 3 END,
                    N'Compilations',
                    N'Queries are waiting for compile memory (RESOURCE_SEMAPHORE_QUERY_COMPILE)',
                    CONCAT
                    (
                        N'tasks waiting now ', ISNULL(@f_compile_now, 0),
                        CASE WHEN @is_sampled = 1 THEN CONCAT(N'; ', ISNULL(@f_wait_compile_ms, 0), N' ms of this wait during the ', @sample_s, N' s sample') END
                    ),
                    N'Many large compilations run at the same time and wait for a compile gateway. Find the statements that compile often or are very large (notes in plan_cache_top, compilations in perf_counters), parameterize ad hoc SQL and remove needless recompiles.',
                    N'waits_now, session_waits_sampled, perf_counters',
                    N'COMPILE_MEMORY_WAITS'
                ),
                (
                    CASE WHEN @f_wait_ioretry_ms >= 1000 THEN 3 END,
                    N'Data IO',
                    N'Storage IO is being retried (IO_RETRY)',
                    CONCAT(ISNULL(@f_wait_ioretry_ms, 0), N' ms of IO_RETRY wait during the ', @sample_s, N' s sample'),
                    N'IO requests failed and were retried, which points at a storage problem on the platform side. If it continues, check Azure Resource Health and open a support case.',
                    N'session_waits_sampled, wait_stats, file_io',
                    N'IO_RETRY'
                ),
                (
                    /* A few attentions are normal: some drivers send one when they close a reader early */
                    CASE WHEN @is_sampled = 1 AND @f_attentions >= @sample_s AND @f_attentions >= 0.05 * @f_batches THEN 3 END,
                    N'Requests',
                    CONCAT(@f_attentions, N' request(s) were cancelled by the client during the sample'),
                    CONCAT
                    (
                        CONVERT(decimal(19, 1), @f_attentions / NULLIF(@sample_s, 0)), N' attentions/s vs ',
                        CONVERT(decimal(19, 1), @f_batches / NULLIF(@sample_s, 0)), N' batch requests/s over ', @sample_s, N' s'
                    ),
                    N'A client sends an attention when it cancels a request, most often because its command timeout expired. Find what runs longer than the application timeout in requests, and what blocks it in blocking_tree.',
                    N'perf_counters, requests, blocking_tree',
                    N'CLIENT_CANCELLATIONS'
                )
            ) AS v (sev, area, finding, evidence, action, see, code)
            WHERE v.sev IS NOT NULL;
        END TRY
        BEGIN CATCH
            INSERT #messages (msg_type, section, message)
            VALUES ('ERROR', N'summary', LEFT(N'Resource findings: ' + ERROR_MESSAGE(), 4000));
        END CATCH;

        BEGIN TRY
            INSERT #findings (severity_rank, area, finding, evidence, recommended_action, see_section, code)
            SELECT
                v.sev,
                v.area,
                LEFT(v.finding, 400),
                LEFT(v.evidence, 2000),
                LEFT(v.action, 2000),
                v.see,
                v.code
            FROM
            (
                VALUES
                (
                    CASE
                        WHEN @f_blocked > 0 AND @f_blk_max_wait_ms >= 300000 THEN 1
                        WHEN @f_blocked > 0 AND (@f_blk_max_wait_ms >= 30000 OR (@f_blk_sleeping_heads > 0 AND @f_blk_max_wait_ms >= 5000)) THEN 2
                        WHEN @f_blocked > 0 AND @f_blk_max_wait_ms >= 5000 THEN 3
                        WHEN @f_blocked >= 5 THEN 4
                    END,
                    N'Blocking',
                    CONCAT
                    (
                        @f_blocked, N' session(s) blocked for up to ', @f_blk_max_wait_ms / 1000, N' s',
                        CASE WHEN @f_blk_sleeping_heads > 0 THEN N'; a head blocker is an idle session holding locks' END
                    ),
                    CONCAT
                    (
                        N'head blockers ', @f_blk_heads, N'; worst head session ', @f_head_session, N' blocks ', @f_head_total,
                        N' session(s): ', @f_head_state,
                        CASE WHEN @f_head_idle_s IS NOT NULL THEN CONCAT(N', idle ', @f_head_idle_s, N' s') END,
                        CASE WHEN @f_head_open_tran > 0 THEN CONCAT(N', open transactions ', @f_head_open_tran) END,
                        N'; ', @f_head_who
                    ),
                    CASE
                        WHEN @f_blk_sleeping_heads > 0
                        THEN N'An idle session holds locks inside an open transaction: the application did not commit or roll back (missing COMMIT, an error path without ROLLBACK, or user interaction inside a transaction). Check its input buffer in blocking_tree; KILL it only after confirming the rollback is acceptable.'
                        ELSE N'Review the head blocker statement and the locks it holds in blocking_tree. Batch long modifications, keep transactions short, and check for missing indexes that turn seeks into scans that lock more rows.'
                    END,
                    N'blocking_tree, requests, open_transactions',
                    N'BLOCKING'
                ),
                (
                    CASE WHEN @f_blk_cycle > 0 THEN 3 END,
                    N'Blocking',
                    N'Sessions are blocked in or behind a cycle with no head blocker',
                    CONCAT(@f_blk_cycle, N' session(s) are in or behind a blocking cycle (listed at the end of blocking_tree)'),
                    N'A lock deadlock is resolved by the deadlock monitor within seconds; a cycle that persists usually involves parallel query threads or a resource SQL Server cannot see. Re-run to confirm and check deadlocks.',
                    N'blocking_tree, deadlocks',
                    N'BLOCKING_CYCLE'
                ),
                (
                    CASE WHEN @f_req_long > 0 THEN CASE WHEN @f_long_s >= 1800 THEN 3 ELSE 4 END END,
                    N'Requests',
                    CONCAT(@f_req_long, N' request(s) running longer than ', @long_running_seconds, N' s'),
                    CONCAT(N'longest ', @f_long_s, N' s: ', @f_long_desc),
                    N'Check the statement, plan and current wait in requests. Long requests are normal for maintenance and reporting; otherwise look for plan regressions (query_store_top, tuning_recommendations), blocking or a missing index.',
                    N'requests, blocking_tree, query_store_top',
                    N'LONG_REQUESTS'
                ),
                (
                    CASE WHEN @f_tran_oldest_s >= 3600 THEN 2 WHEN @f_tran_oldest_s >= 600 THEN 3 END,
                    N'Transactions',
                    CONCAT(N'A transaction has been open for ', @f_tran_oldest_s / 60, N' min'),
                    CONCAT
                    (
                        N'session ', @f_tran_oldest_session, N' (', @f_tran_oldest_state, N'), log used ', ISNULL(@f_tran_oldest_log_mb, 0),
                        N' MB; open transactions in this database ', ISNULL(@f_tran_open, 0),
                        CASE WHEN @f_pvs_oldest_session = @f_tran_oldest_session THEN N'; it is the oldest transaction holding back version store cleanup' END
                    ),
                    N'Long transactions hold locks and prevent log truncation and version store cleanup. See what the session is doing in open_transactions; commit or roll back, or KILL it only after weighing the rollback time.',
                    N'open_transactions, version_store, log_usage',
                    N'LONG_TRANSACTION'
                ),
                (
                    CASE
                        WHEN @f_idle_work_max_s >= 600 THEN 2
                        WHEN @f_idle_work_max_s >= 60 THEN 3
                        WHEN @f_idle_work = 0 AND @f_idle_tran_max_s >= 600 THEN 4
                    END,
                    N'Transactions',
                    CASE
                        WHEN @f_idle_work > 0
                        THEN CONCAT(@f_idle_work, N' session(s) idle with an open transaction that holds locks, log or row versions, up to ', @f_idle_work_max_s, N' s')
                        ELSE CONCAT(@f_idle_tran, N' session(s) idle with an open transaction that has done no work, up to ', @f_idle_tran_max_s, N' s')
                    END,
                    CONCAT
                    (
                        @f_idle_tran, N' idle session(s) have an open transaction; ', ISNULL(@f_idle_work, 0),
                        N' of them wrote log, read under SNAPSHOT, keep shared locks or block others; ',
                        CASE WHEN @f_idle_implicit > 0 THEN CONCAT(@f_idle_implicit, N' of them are implicit transactions (SET IMPLICIT_TRANSACTIONS ON); ') END,
                        N'session ', @f_idle_tran_session, N' idle ', @f_idle_tran_session_s, N' s',
                        CASE WHEN @f_idle_tran_age_s IS NOT NULL THEN CONCAT(N', transaction open ', @f_idle_tran_age_s, N' s') END,
                        CASE WHEN @f_idle_tran_blocking > 0 THEN CONCAT(N', blocking ', @f_idle_tran_blocking, N' session(s)') END,
                        N': ', @f_idle_tran_who
                    ),
                    CASE
                        WHEN @f_idle_work > 0
                        THEN N'The application opened a transaction and stopped sending work without committing. Check the input buffer in open_transactions and fix the code path (missing COMMIT, error handling without ROLLBACK, implicit transactions left on).'
                        ELSE N'These transactions wrote nothing and hold no locks, log or row versions, so they block nobody now. The usual cause is a driver with autocommit off (pyodbc, JDBC), which opens a transaction with the first statement. Turn autocommit on, or commit after each unit of work: such a session becomes a blocker as soon as it writes and then idles.'
                    END,
                    N'open_transactions, sessions_by_app, blocking_tree',
                    N'IDLE_IN_TRANSACTION'
                ),
                (
                    CASE WHEN @deadlock_count > 0 OR @f_deadlocks_delta > 0 THEN 3 END,
                    N'Deadlocks',
                    N'Deadlocks are occurring',
                    CONCAT
                    (
                        CASE WHEN @deadlock_count > 0 THEN CONCAT(@deadlock_count, N' deadlock(s) captured in the last ', @lookback_minutes, N' min') END,
                        CASE WHEN @deadlock_count > 0 AND @f_deadlocks_delta > 0 THEN N'; ' END,
                        CASE WHEN @f_deadlocks_delta > 0 THEN CONCAT(@f_deadlocks_delta, N' during the ', @sample_s, N' s sample') END
                    ),
                    N'Review the deadlock graphs in deadlocks for the statements and objects involved. Typical fixes: access objects in the same order, add a covering index, keep transactions short, and let readers use row versioning (RCSI or SNAPSHOT).',
                    N'deadlocks',
                    N'DEADLOCKS'
                ),
                (
                    CASE WHEN @f_rollback > 0 THEN CASE WHEN @f_rollback_blocking > 0 THEN 2 ELSE 3 END END,
                    N'Transactions',
                    CONCAT(@f_rollback, N' request(s) are rolling back'),
                    @f_rollback_desc,
                    N'A rollback cannot be cancelled, and killing the session again does not speed it up. It keeps its locks until it ends. Watch percent_complete and estimated_remaining in requests.',
                    N'requests, open_transactions, blocking_tree',
                    N'ROLLBACK_RUNNING'
                ),
                (
                    CASE WHEN @bh_count > 0 THEN 4 END,
                    N'Blocking',
                    CONCAT(@bh_count, N' block(s) were reported in the last ', @lookback_minutes, N' min'),
                    @bh_worst,
                    N'This is blocking that the service reported, including blocks that have ended. See blocking_history for the blocker, what it ran last and whether it was idle.',
                    N'blocking_history, blocking_tree',
                    N'BLOCKING_HISTORY'
                )
            ) AS v (sev, area, finding, evidence, action, see, code)
            WHERE v.sev IS NOT NULL;
        END TRY
        BEGIN CATCH
            INSERT #messages (msg_type, section, message)
            VALUES ('ERROR', N'summary', LEFT(N'Concurrency findings: ' + ERROR_MESSAGE(), 4000));
        END CATCH;

        BEGIN TRY
            INSERT #findings (severity_rank, area, finding, evidence, recommended_action, see_section, code)
            SELECT
                v.sev,
                v.area,
                LEFT(v.finding, 400),
                LEFT(v.evidence, 2000),
                LEFT(v.action, 2000),
                v.see,
                v.code
            FROM
            (
                VALUES
                (
                    CASE WHEN @f_data_pct >= 90 THEN 2 WHEN @f_data_pct >= 80 THEN 3 END,
                    N'Storage',
                    N'The database is close to its maximum data size',
                    CONCAT(N'used ', @f_data_used_mb, N' MB of ', @f_data_max_mb, N' MB (', CONVERT(decimal(9, 1), @f_data_pct), N'%); allocated ', @f_data_alloc_mb, N' MB'),
                    N'At the maximum size inserts and updates fail (error 1105). Raise MAXSIZE or the service objective, or purge or archive data.',
                    N'governance, configuration',
                    N'DATA_SIZE_LIMIT'
                ),
                (
                    CASE
                        WHEN @f_log_used_pct >= 90 THEN 2
                        WHEN @f_log_used_pct >= 70 THEN 3
                        WHEN @f_log_file_pct >= 90
                        AND  @f_log_reuse_wait NOT IN (N'NOTHING', N'CHECKPOINT', N'LOG_BACKUP', N'ACTIVE_BACKUP_OR_RESTORE')
                        THEN 4
                    END,
                    N'Log space',
                    CASE
                        WHEN @f_log_used_pct >= 70 THEN N'The transaction log is filling up'
                        ELSE N'The log file is nearly full at its current size and truncation is held up (the file can still grow)'
                    END,
                    CONCAT
                    (
                        N'log used ', @f_log_used_mb, N' MB, ', CONVERT(decimal(9, 1), @f_log_used_pct), N'% of ', @f_log_basis, N'; log_reuse_wait_desc ', ISNULL(@f_log_reuse_wait, N'n/a'),
                        CASE WHEN @f_tran_oldest_s >= 60 THEN CONCAT(N'; oldest transaction ', @f_tran_oldest_s, N' s (session ', @f_tran_oldest_session, N')') END
                    ),
                    N'The log cannot be truncated past the reason in log_reuse_wait_desc. ACTIVE_TRANSACTION: end the oldest transaction. AVAILABILITY_REPLICA: a replica or geo-secondary is behind. REPLICATION: CDC or replication is not keeping up. When the log is full every write fails (error 9002).',
                    N'log_usage, open_transactions, replicas',
                    N'LOG_SPACE'
                ),
                (
                    CASE WHEN @f_tdb_data_pct >= 80 OR @f_tdb_log_pct >= 80 THEN 2 END,
                    N'tempdb',
                    N'tempdb is filling up',
                    CONCAT
                    (
                        N'data used ', ISNULL(CONVERT(nvarchar(20), CONVERT(decimal(9, 1), @f_tdb_data_pct)), N'n/a'), N'% (', @f_tdb_data_used_mb, N' of ', @f_tdb_data_max_mb,
                        N' MB), log used ', ISNULL(CONVERT(nvarchar(20), CONVERT(decimal(9, 1), @f_tdb_log_pct)), N'n/a'), N'%',
                        CASE WHEN @f_tdb_top_session IS NOT NULL THEN CONCAT(N'; top consumer session ', @f_tdb_top_session, N' with ', CONVERT(decimal(19, 1), @f_tdb_top_mb), N' MB') END
                    ),
                    N'Find the consumer in tempdb_sessions (user objects are temp tables and table variables; internal objects are sorts, hashes, spools and spills). A long transaction can also bloat the tempdb version store. When tempdb is full, queries that need it fail.',
                    N'tempdb_space, tempdb_sessions, version_store',
                    N'TEMPDB_SPACE'
                ),
                (
                    CASE WHEN @f_pvs_mb >= 51200 OR (@f_pvs_mb >= 1024 AND @f_pvs_mb >= 0.1 * @f_data_used_mb) THEN 3 END,
                    N'Version store',
                    N'The ADR persistent version store is large',
                    CONCAT
                    (
                        N'PVS ', @f_pvs_mb, N' MB (', ISNULL(CONVERT(nvarchar(20), CONVERT(decimal(9, 1), 100.0 * @f_pvs_mb / NULLIF(@f_data_used_mb, 0))), N'n/a'),
                        N'% of used data space); aborted transactions tracked ', ISNULL(@f_pvs_aborted, 0),
                        CASE WHEN @f_pvs_oldest_session IS NOT NULL THEN CONCAT(N'; the oldest active transaction belongs to session ', @f_pvs_oldest_session) END
                    ),
                    N'Version cleanup is held back by the oldest active transaction, including long snapshot reads on readable secondaries. Find it in version_store and open_transactions and end it; cleanup then catches up on its own.',
                    N'version_store, open_transactions',
                    N'VERSION_STORE_LARGE'
                ),
                (
                    CASE
                        WHEN @f_qs_actual = 3 OR @f_qs_state = N'ERROR' THEN 2
                        WHEN @f_qs_actual = 1 AND @f_qs_desired = 2 AND (ISNULL(@f_qs_readonly_reason, 0) & 15) = 0 THEN 2
                        WHEN @f_qs_actual = 0 THEN 3
                    END,
                    N'Query Store',
                    CASE
                        WHEN @f_qs_actual = 3 OR @f_qs_state = N'ERROR' THEN N'Query Store is in ERROR state'
                        WHEN @f_qs_actual = 1 THEN N'Query Store switched to READ_ONLY and stopped capturing'
                        ELSE N'Query Store is OFF'
                    END,
                    CONCAT
                    (
                        N'actual ', @f_qs_state,
                        N', desired ', CASE @f_qs_desired WHEN 0 THEN N'OFF' WHEN 1 THEN N'READ_ONLY' WHEN 2 THEN N'READ_WRITE' ELSE N'n/a' END,
                        N', readonly_reason ', ISNULL(@f_qs_readonly_reason, 0),
                        CASE
                            WHEN (@f_qs_readonly_reason & 65536) = 65536 THEN N' (MAX_STORAGE_SIZE_MB reached)'
                            WHEN (@f_qs_readonly_reason & 131072) = 131072 THEN N' (internal statement count limit reached)'
                            WHEN (@f_qs_readonly_reason & 262144) = 262144 THEN N' (in-memory buffer limit reached)'
                            WHEN (@f_qs_readonly_reason & 524288) = 524288 THEN N' (database size limit reached)'
                        END,
                        N'; ', @f_qs_used_mb, N' of ', @f_qs_max_mb, N' MB used'
                    ),
                    CASE
                        WHEN @f_qs_actual = 1
                        THEN N'Free space first (raise MAX_STORAGE_SIZE_MB, lower STALE_QUERY_THRESHOLD_DAYS, set SIZE_BASED_CLEANUP_MODE = AUTO), then ALTER DATABASE CURRENT SET QUERY_STORE (OPERATION_MODE = READ_WRITE).'
                        WHEN @f_qs_actual = 3 OR @f_qs_state = N'ERROR'
                        THEN N'Try ALTER DATABASE CURRENT SET QUERY_STORE = OFF, then ON (OPERATION_MODE = READ_WRITE). If it stays in ERROR, QUERY_STORE CLEAR ALL (loses the history) or open a support case.'
                        ELSE N'Enable it: ALTER DATABASE CURRENT SET QUERY_STORE = ON (OPERATION_MODE = READ_WRITE). Automatic plan correction and most plan regression analysis depend on it.'
                    END,
                    N'configuration, query_store_top',
                    N'QUERY_STORE_STATE'
                ),
                (
                    CASE
                        WHEN @f_qs_actual = 2 AND @f_qs_pct >= 80
                        THEN CASE WHEN @f_qs_cleanup_auto = 0 OR @f_qs_pct >= 95 THEN 3 ELSE 4 END
                    END,
                    N'Query Store',
                    N'Query Store is nearly full',
                    CONCAT(@f_qs_used_mb, N' of ', @f_qs_max_mb, N' MB (', CONVERT(decimal(9, 1), @f_qs_pct), N'%); size-based cleanup ', CASE WHEN @f_qs_cleanup_auto = 1 THEN N'AUTO' ELSE N'OFF' END),
                    N'At 100% Query Store switches to READ_ONLY and stops capturing. Raise MAX_STORAGE_SIZE_MB, lower STALE_QUERY_THRESHOLD_DAYS or set SIZE_BASED_CLEANUP_MODE = AUTO; QUERY_CAPTURE_MODE = AUTO skips trivial ad hoc queries.',
                    N'configuration',
                    N'QUERY_STORE_NEARLY_FULL'
                ),
                (
                    CASE WHEN @f_at_mismatch IS NOT NULL THEN 3 END,
                    N'Automatic tuning',
                    N'An automatic tuning option is not in its desired state',
                    @f_at_mismatch,
                    N'The reason explains why (commonly Query Store is off or read-only, or the system disabled the option). Fix the cause: FORCE_LAST_GOOD_PLAN only protects against plan regressions while it is actually on.',
                    N'configuration, tuning_recommendations',
                    N'AUTO_TUNING_STATE'
                ),
                (
                    CASE WHEN @f_regressions > 0 THEN 3 END,
                    N'Automatic tuning',
                    CONCAT(@f_regressions, N' plan regression(s) detected and not yet corrected'),
                    CONCAT(@f_regressions, N' FORCE_LAST_GOOD_PLAN recommendation(s) in state Active'),
                    N'Review tuning_recommendations: each row includes the script that forces the last good plan. With automatic tuning FORCE_LAST_GOOD_PLAN = ON they are applied and verified automatically.',
                    N'tuning_recommendations, query_store_top',
                    N'PLAN_REGRESSIONS'
                ),
                (
                    CASE WHEN @f_auto_create_stats = 0 OR @f_auto_update_stats = 0 THEN 3 END,
                    N'Configuration',
                    N'Automatic statistics creation or update is off',
                    CONCAT
                    (
                        N'AUTO_CREATE_STATISTICS ', CASE WHEN @f_auto_create_stats = 1 THEN N'ON' ELSE N'OFF' END,
                        N', AUTO_UPDATE_STATISTICS ', CASE WHEN @f_auto_update_stats = 1 THEN N'ON' ELSE N'OFF' END
                    ),
                    N'Unless a statistics job deliberately replaces it, turn it back on: ALTER DATABASE CURRENT SET AUTO_CREATE_STATISTICS ON; ALTER DATABASE CURRENT SET AUTO_UPDATE_STATISTICS ON.',
                    N'configuration, stale_statistics',
                    N'AUTO_STATS_OFF'
                ),
                (
                    CASE WHEN @f_auto_shrink = 1 THEN 4 END,
                    N'Configuration',
                    N'AUTO_SHRINK is on',
                    N'is_auto_shrink_on = 1',
                    N'Repeated shrink and growth wastes IO and fragments indexes: ALTER DATABASE CURRENT SET AUTO_SHRINK OFF.',
                    N'configuration',
                    N'AUTO_SHRINK_ON'
                ),
                (
                    CASE WHEN @rcsi = 0 THEN 4 END,
                    N'Configuration',
                    N'READ_COMMITTED_SNAPSHOT is off',
                    N'is_read_committed_snapshot_on = 0 (the Azure SQL Database default is ON)',
                    N'Readers and writers block each other under locking read committed. If reader/writer blocking matters, test ALTER DATABASE CURRENT SET READ_COMMITTED_SNAPSHOT ON.',
                    N'configuration, blocking_tree',
                    N'RCSI_OFF'
                ),
                (
                    CASE WHEN @f_geo_lag_s >= 60 THEN 3 END,
                    N'Replicas',
                    N'Geo-replication is lagging',
                    CONCAT(N'replication lag ', @f_geo_lag_s, N' s; link ', @f_geo_partner),
                    N'Lag grows with heavy log generation (index maintenance, bulk loads) or an undersized secondary. Changes inside the lag window are lost on a forced failover. Check the log rate and the secondary service objective.',
                    N'replicas, resource_stats',
                    N'GEO_REPLICATION_LAG'
                ),
                (
                    CASE WHEN @f_ha_bad > 0 THEN @f_ha_sev END,
                    N'Replicas',
                    N'A high-availability replica is unhealthy or suspended',
                    @f_ha_desc,
                    N'Usually transient during a reconfiguration or failover. If it persists, check Azure Resource Health and open a support case.',
                    N'replicas',
                    N'HA_REPLICA_UNHEALTHY'
                ),
                (
                    CASE
                        WHEN @f_io_data_ios >= CASE WHEN @is_sampled = 1 THEN 100 ELSE 10000 END
                        AND  @f_io_data_queued_ms >= 0.1 * @f_io_data_stall_ms
                        THEN
                            CASE
                                WHEN @is_sampled = 1 AND @f_io_data_queued_ms >= 10.0 * @f_io_data_ios THEN 2
                                WHEN @f_io_data_queued_ms >= 2.0 * @f_io_data_ios THEN 3
                            END
                    END,
                    N'Data IO',
                    N'Azure IO governance is queuing data IO',
                    CONCAT
                    (
                        N'governance queuing ', CONVERT(decimal(19, 2), @f_io_data_queued_ms * 1.0 / NULLIF(@f_io_data_ios, 0)), N' ms per IO (',
                        CONVERT(decimal(9, 1), 100.0 * @f_io_data_queued_ms / NULLIF(@f_io_data_stall_ms, 0)), N'% of IO stall) over ', @f_io_data_ios, N' IOs ',
                        CASE WHEN @is_sampled = 1 THEN CONCAT(N'in the last ', @sample_s, N' s') ELSE N'since instance start' END
                    ),
                    N'The workload reaches the data IOPS limit of the service objective. Reduce reads and writes (better indexes, fewer scans, no spills) or scale up.',
                    N'file_io, resource_stats, wait_stats',
                    N'IO_GOVERNANCE_QUEUING'
                ),
                (
                    CASE
                        WHEN @f_io_log_writes >= CASE WHEN @is_sampled = 1 THEN 100 ELSE 10000 END
                        THEN
                            CASE
                                WHEN @f_io_log_stall_ms >= 20.0 * @f_io_log_writes THEN 3
                                WHEN @f_io_log_stall_ms >= 10.0 * @f_io_log_writes THEN 4
                            END
                    END,
                    N'Log IO',
                    N'Transaction log writes are slow',
                    CONCAT
                    (
                        N'average log write ', CONVERT(decimal(19, 2), @f_io_log_stall_ms * 1.0 / NULLIF(@f_io_log_writes, 0)), N' ms over ', @f_io_log_writes, N' writes ',
                        CASE WHEN @is_sampled = 1 THEN CONCAT(N'in the last ', @sample_s, N' s') ELSE N'since instance start' END
                    ),
                    N'Every commit waits for its log write (WRITELOG). Batch small transactions into fewer commits and check log rate governance (LOG_RATE_GOVERNOR, avg_log_write_percent).',
                    N'file_io, wait_stats, resource_stats',
                    N'LOG_WRITES_SLOW'
                ),
                (
                    CASE
                        WHEN @f_counter_s > 0
                        AND  @f_compiles >= 0.1 * @f_batches
                        AND  @f_compiles >= 100 * @f_counter_s
                        THEN 4
                        WHEN @f_counter_s > 0
                        AND  @f_recompiles >= 0.1 * @f_batches
                        AND  @f_recompiles >= 10 * @f_counter_s
                        THEN 4
                    END,
                    N'Compilations',
                    CASE
                        WHEN @f_compiles >= 0.1 * @f_batches AND @f_compiles >= 100 * @f_counter_s THEN N'High compilation rate'
                        ELSE N'High recompilation rate'
                    END,
                    CONCAT
                    (
                        CONVERT(decimal(19, 1), @f_recompiles / NULLIF(@f_counter_s, 0)), N' recompilations/s, ',
                        CONVERT(decimal(19, 1), @f_compiles / NULLIF(@f_counter_s, 0)), N' compilations/s vs ',
                        CONVERT(decimal(19, 1), @f_batches / NULLIF(@f_counter_s, 0)), N' batch requests/s (',
                        CONVERT(decimal(9, 1), 100.0 * @f_compiles / NULLIF(@f_batches, 0)), N'%) ',
                        CASE WHEN @is_sampled = 1 THEN CONCAT(N'over the last ', @sample_s, N' s') ELSE N'averaged since instance start' END
                    ),
                    N'Recompilations come from statistics updates, schema or temp table changes and OPTION (RECOMPILE). Non-parameterized ad hoc SQL compiles on every call and costs CPU. Parameterize in the application; otherwise test PARAMETERIZATION FORCED or OPTIMIZE_FOR_AD_HOC_WORKLOADS. Single-use plans show up in plan_cache_top.',
                    N'perf_counters, plan_cache_top',
                    N'COMPILATION_RATE'
                ),
                (
                    CASE WHEN @f_updateability = N'READ_ONLY' THEN 5 END,
                    N'Database',
                    N'This database is read-only (readable secondary, named replica or geo-secondary)',
                    N'DATABASEPROPERTYEX(Updateability) = READ_ONLY',
                    N'Write-related checks do not apply here. Run the procedure on the primary to see the write workload.',
                    N'governance, replicas',
                    N'DATABASE_READ_ONLY'
                ),
                (
                    CASE WHEN @f_rs_latest IS NULL OR @f_rs_latest < DATEADD(MINUTE, -5, @now_utc) THEN 5 END,
                    N'Resource stats',
                    N'Resource usage history (sys.dm_db_resource_stats) is missing or stale',
                    CASE
                        WHEN @f_rs_latest IS NULL THEN N'No rows returned.'
                        ELSE CONCAT(N'latest row ends at ', CONVERT(nvarchar(19), @f_rs_latest, 120), N' UTC')
                    END,
                    N'CPU, IO, log, worker and session percentages in the summary may be missing or old. The view keeps about an hour of 15-second rows; check the VIEW DATABASE STATE permission.',
                    N'resource_stats',
                    N'RESOURCE_STATS_STALE'
                ),
                (
                    CASE WHEN @f_identity_max_pct >= 98 THEN 2 WHEN @f_identity_max_pct >= 90 THEN 3 END,
                    N'Storage',
                    CONCAT(@f_identity_count, N' identity column(s) have used 90% or more of their range'),
                    @f_identity_list,
                    N'When the range ends, every insert into the table fails with error 8115 (arithmetic overflow). Change the column to a larger data type (this rewrites the table: plan it), or reseed when a large unused range exists.',
                    N'summary',
                    N'IDENTITY_RANGE'
                ),
                (
                    CASE
                        WHEN @f_io_read_count >= CASE WHEN @is_sampled = 1 THEN 100 ELSE 10000 END
                        THEN
                            CASE
                                WHEN @is_sampled = 1 AND @f_io_read_stall_ms >= 100.0 * @f_io_read_count THEN 2
                                WHEN @is_sampled = 1 AND @f_io_read_stall_ms >= 20.0 * @f_io_read_count THEN 3
                                WHEN @f_io_read_stall_ms >= 20.0 * @f_io_read_count THEN 4
                            END
                    END,
                    N'Data IO',
                    N'Data file reads are slow',
                    CONCAT
                    (
                        N'average read ', CONVERT(decimal(19, 2), @f_io_read_stall_ms * 1.0 / NULLIF(@f_io_read_count, 0)), N' ms over ', @f_io_read_count, N' reads ',
                        CASE WHEN @is_sampled = 1 THEN CONCAT(N'in the last ', @sample_s, N' s') ELSE N'since instance start' END,
                        CASE WHEN @is_hyperscale = 1 THEN N' (Hyperscale: reads from page servers, the local cache is not counted)' END
                    ),
                    N'Queries wait on PAGEIOLATCH for these reads. Reduce the reads (indexes, fewer scans) and check Data IO % and governance queuing in file_io. On Hyperscale these pages were not in the local cache.',
                    N'file_io, wait_stats, requests',
                    N'DATA_READS_SLOW'
                ),
                (
                    CASE WHEN @instance_start > DATEADD(MINUTE, -60, @now) THEN 4 END,
                    N'Database',
                    CONCAT(N'The database engine started ', DATEDIFF(MINUTE, @instance_start, @now), N' min ago'),
                    CONCAT(N'instance start ', CONVERT(nvarchar(19), @instance_start, 120), N' UTC (restart, failover or change of service objective)'),
                    N'The plan cache and the buffer pool are cold, so compilations and reads are higher than normal for a while. Results that are cumulative since the start cover only this time.',
                    N'summary, perf_counters',
                    N'RECENT_START'
                ),
                (
                    CASE WHEN @f_force_failed > 0 THEN 3 END,
                    N'Query Store',
                    CONCAT(@f_force_failed, N' forced plan(s) or Query Store hint(s) failed to apply'),
                    CONCAT(@f_force_failed, N' of ', @f_force_total, N' forced plans and hints have failures; worst: ', @f_force_example),
                    N'The query does not run with the plan or hint that was set, and the failed attempt can add compile time. See plan_forcing: the script column unforces the plan or clears the hint. Then correct the cause, or force a plan that still can be built.',
                    N'plan_forcing, query_store_top',
                    N'PLAN_FORCING_FAILED'
                ),
                (
                    CASE WHEN @stats_recent > 0 THEN 5 END,
                    N'Statistics',
                    CONCAT(@stats_recent, N' statistics were updated in the last 15 minutes'),
                    @stats_recent_list,
                    N'A statistics update makes the plans that use it compile again, and the new plan is built for the parameter values of the first caller. If a query became slow at that time, compare its plans in query_store_top.',
                    N'stale_statistics, query_store_top',
                    N'STATISTICS_UPDATED'
                )
            ) AS v (sev, area, finding, evidence, action, see, code)
            WHERE v.sev IS NOT NULL;
        END TRY
        BEGIN CATCH
            INSERT #messages (msg_type, section, message)
            VALUES ('ERROR', N'summary', LEFT(N'Storage, configuration and IO findings: ' + ERROR_MESSAGE(), 4000));
        END CATCH;

        /* Say so explicitly when nothing above INFO was found, and whether every check ran */
        DECLARE
            @f_check_failures int,
            @f_top_finding nvarchar(450);

        SELECT
            @f_check_failures = COUNT(*)
        FROM #messages AS m
        WHERE m.section = N'summary';

        IF NOT EXISTS (SELECT 1/0 FROM #findings AS f WHERE f.severity_rank <= 4)
        BEGIN
            INSERT #findings (severity_rank, area, finding, evidence, recommended_action, see_section, code)
            VALUES
            (
                5,
                N'Overall',
                CASE
                    WHEN @f_check_failures > 0
                    THEN CONCAT(N'No problems detected by the checks that completed (', @f_check_failures, N' check(s) failed; see messages)')
                    ELSE N'No problems detected'
                END,
                LEFT
                (
                    CONCAT
                    (
                        N'CPU ', ISNULL(CONVERT(nvarchar(30), @f_cpu_now), N'n/a'),
                        N'% (5-minute max ', ISNULL(CONVERT(nvarchar(30), @f_cpu_max5), N'n/a'),
                        N'%), data IO ', ISNULL(CONVERT(nvarchar(30), @f_io_now), N'n/a'),
                        N'%, log write ', ISNULL(CONVERT(nvarchar(30), @f_log_now), N'n/a'),
                        N'%, workers ', ISNULL(CONVERT(nvarchar(30), @f_workers_pct), N'n/a'),
                        N'%; ', ISNULL(@f_req_active, 0), N' active request(s), ', ISNULL(@f_blocked, 0), N' blocked, ',
                        ISNULL(@f_grants_pending, 0), N' memory grant(s) pending'
                    ),
                    2000
                ),
                CASE
                    WHEN @is_sampled = 1
                    THEN N'Nothing needs attention right now. @effort = ''slow'' adds Query Store, deadlocks, statistics and index usage.'
                    ELSE N'Nothing needs attention right now. @sample_seconds = 10 measures live waits, IO and counters; @effort = ''slow'' adds Query Store, deadlocks, statistics and index usage.'
                END,
                N'summary',
                N'NO_PROBLEMS'
            );
        END;

        /* Rollup: CRITICAL if any critical finding, WARNING if any high, ATTENTION if any medium, else OK */
        SELECT
            @f_n_crit = ISNULL(SUM(CASE WHEN f.severity_rank = 1 THEN 1 ELSE 0 END), 0),
            @f_n_high = ISNULL(SUM(CASE WHEN f.severity_rank = 2 THEN 1 ELSE 0 END), 0),
            @f_n_med = ISNULL(SUM(CASE WHEN f.severity_rank = 3 THEN 1 ELSE 0 END), 0),
            @f_n_low = ISNULL(SUM(CASE WHEN f.severity_rank = 4 THEN 1 ELSE 0 END), 0)
        FROM #findings AS f;

        SELECT TOP (1)
            @f_top_finding = CONCAT(f.area, N': ', f.finding)
        FROM #findings AS f
        WHERE f.severity_rank <= 4
        ORDER BY
            f.severity_rank,
            f.id;

        SET @f_status =
            CASE
                WHEN @f_n_crit > 0 THEN N'CRITICAL'
                WHEN @f_n_high > 0 THEN N'WARNING'
                WHEN @f_n_med > 0 THEN N'ATTENTION'
                ELSE N'OK'
            END;

        RAISERROR(N'STATUS=%s CRITICAL=%d HIGH=%d MEDIUM=%d LOW=%d', 0, 1, @f_status, @f_n_crit, @f_n_high, @f_n_med, @f_n_low) WITH NOWAIT;

        /* 110 findings */
        SELECT
            @rk = N'findings',
            @t0 = SYSDATETIME();

        INSERT #emit (section_order, section_key, result_key, result_name, table_name, empty_message)
        VALUES (110, N'summary', @rk, N'FINDINGS (most severe first, with evidence and next steps)', N'#o_findings', N'No findings.');

        BEGIN TRY
            SELECT
                rn = ROW_NUMBER() OVER (ORDER BY f.severity_rank, f.id),
                severity =
                    CONVERT
                    (
                        nvarchar(10),
                        CASE f.severity_rank
                            WHEN 1 THEN N'CRITICAL'
                            WHEN 2 THEN N'HIGH'
                            WHEN 3 THEN N'MEDIUM'
                            WHEN 4 THEN N'LOW'
                            ELSE N'INFO'
                        END
                    ),
                area = f.area,
                finding = f.finding,
                evidence = f.evidence,
                recommended_action = f.recommended_action,
                see_results = f.see_section,
                code = f.code
            INTO #o_findings
            FROM #findings AS f;
        END TRY
        BEGIN CATCH
            UPDATE #emit SET error_message = LEFT(ERROR_MESSAGE(), 4000) WHERE result_key = @rk;
        END CATCH;

        UPDATE #emit SET duration_ms = DATEDIFF_BIG(MILLISECOND, @t0, SYSDATETIME()) WHERE result_key = @rk;

        /* 100 summary: one row per area, the value first and the context after it */
        SELECT
            @rk = N'summary',
            @t0 = SYSDATETIME();

        INSERT #emit (section_order, section_key, result_key, result_name, table_name, empty_message)
        VALUES (100, N'summary', @rk, N'SUMMARY (health rollup and key metrics)', N'#o_summary', NULL);

        BEGIN TRY
            SELECT
                rn = ROW_NUMBER() OVER (ORDER BY v.ord),
                item = CONVERT(nvarchar(40), v.item),
                value = CONVERT(nvarchar(200), ISNULL(v.value, N'n/a')),
                detail = CONVERT(nvarchar(4000), v.detail)
            INTO #o_summary
            FROM
            (
                VALUES
                (
                    1, N'status', @f_status,
                    CONCAT
                    (
                        @f_n_crit, N' critical, ', @f_n_high, N' high, ', @f_n_med, N' medium, ', @f_n_low, N' low finding(s)',
                        N'; most severe: ' + @f_top_finding,
                        CASE WHEN @f_check_failures > 0 THEN CONCAT(N'; ', @f_check_failures, N' check(s) failed, see messages') END
                    )
                ),
                (
                    2, N'database', @db_name,
                    CONCAT
                    (
                        @edition, N' ', @service_objective,
                        N' (', ISNULL(CONVERT(nvarchar(30), CONVERT(decimal(9, 1), @rg_cpu_limit)), N'n/a'), N' vCores)',
                        N', compatibility level ', ISNULL(CONVERT(nvarchar(30), @f_compat), N'n/a'),
                        N', ', ISNULL(@f_updateability, N'n/a'),
                        N', RCSI ', CASE @rcsi WHEN 1 THEN N'on' WHEN 0 THEN N'off' ELSE N'n/a' END
                    )
                ),
                (
                    3, N'collected', CONVERT(nvarchar(19), @now_utc, 120) + N' UTC',
                    CONCAT
                    (
                        N'effort ', @effort_l,
                        CASE WHEN @is_sampled = 1 THEN CONCAT(N'; deltas measured over ', @sample_s, N' s') ELSE N'; point in time (@sample_seconds = 0)' END,
                        N'; resource stats as of ', ISNULL(CONVERT(nvarchar(19), @f_rs_latest, 120) + N' UTC', N'n/a'),
                        N'; instance started ', ISNULL(CONVERT(nvarchar(19), @instance_start, 120), N'n/a')
                    )
                ),
                (
                    4, N'cpu', CONVERT(nvarchar(30), @f_cpu_now) + N'%',
                    CONCAT
                    (
                        N'5-minute avg ', ISNULL(CONVERT(nvarchar(30), @f_cpu_avg5), N'n/a'),
                        N'%, max ', ISNULL(CONVERT(nvarchar(30), @f_cpu_max5), N'n/a'),
                        N'%; instance CPU ', ISNULL(CONVERT(nvarchar(30), @f_icpu_now), N'n/a'),
                        N'% (5-minute avg ', ISNULL(CONVERT(nvarchar(30), @f_icpu_avg5), N'n/a'), N'%)'
                    )
                ),
                (
                    5, N'data_io', CONVERT(nvarchar(30), @f_io_now) + N'%',
                    CONCAT
                    (
                        N'5-minute avg ', ISNULL(CONVERT(nvarchar(30), @f_io_avg5), N'n/a'), N'%',
                        CASE
                            WHEN @f_io_data_ios > 0
                            THEN CONCAT
                                 (
                                     N'; ', @f_io_data_ios, N' data IOs ', CASE WHEN @is_sampled = 1 THEN N'in the sample' ELSE N'since instance start' END,
                                     N', avg ', CONVERT(decimal(19, 2), 1.0 * @f_io_data_stall_ms / NULLIF(@f_io_data_ios, 0)),
                                     N' ms, of which governance queuing ', CONVERT(decimal(19, 2), 1.0 * ISNULL(@f_io_data_queued_ms, 0) / NULLIF(@f_io_data_ios, 0)), N' ms'
                                 )
                        END
                    )
                ),
                (
                    6, N'log_write', CONVERT(nvarchar(30), @f_log_now) + N'%',
                    CONCAT
                    (
                        N'5-minute avg ', ISNULL(CONVERT(nvarchar(30), @f_log_avg5), N'n/a'),
                        N'%; log rate limit ', ISNULL(CONVERT(nvarchar(30), @rg_max_log_rate_mbps) + N' MB/s', N'n/a'),
                        CASE
                            WHEN @f_io_log_writes > 0
                            THEN CONCAT(N'; avg log write ', CONVERT(decimal(19, 2), 1.0 * @f_io_log_stall_ms / NULLIF(@f_io_log_writes, 0)), N' ms over ', @f_io_log_writes, N' writes')
                        END
                    )
                ),
                (
                    7, N'workers', CONVERT(nvarchar(30), @f_workers_pct) + N'%',
                    CONCAT
                    (
                        ISNULL(CONVERT(nvarchar(30), @f_wg_active_workers), N'n/a'), N' of ', ISNULL(CONVERT(nvarchar(30), @rg_max_workers), N'n/a'),
                        N' workers in use, 5-minute max ', ISNULL(CONVERT(nvarchar(30), @f_workers_max5), N'n/a'),
                        N'%; queued requests ', ISNULL(@f_wg_queued, 0),
                        N', scheduler work queue ', ISNULL(@f_work_queue, 0),
                        N', avg runnable tasks per scheduler ', ISNULL(CONVERT(nvarchar(30), @f_runnable_avg), N'n/a'),
                        CASE WHEN @f_threadpool_tasks > 0 THEN CONCAT(N'; ', @f_threadpool_tasks, N' task(s) waiting for a worker (THREADPOOL)') END
                    )
                ),
                (
                    8, N'sessions', CONVERT(nvarchar(30), @f_sess_user),
                    CONCAT
                    (
                        N'user sessions; ', ISNULL(@f_sess_db, 0), N' in this database (', ISNULL(@f_sess_sleeping, 0), N' sleeping); ',
                        ISNULL(CONVERT(nvarchar(30), @f_sessions_now), N'n/a'), N'% of the session limit (', ISNULL(CONVERT(nvarchar(30), @rg_max_sessions), N'n/a'), N')'
                    )
                ),
                (
                    9, N'memory', CONVERT(nvarchar(30), @f_mem_now) + N'%',
                    CONCAT
                    (
                        N'of the memory limit in use; ', ISNULL(@f_grants_active, 0), N' active grant(s) using ', ISNULL(CONVERT(nvarchar(30), @f_granted_mb), N'0'),
                        N' MB, ', ISNULL(@f_grants_pending, 0), N' pending',
                        CASE WHEN @f_grants_pending > 0 THEN CONCAT(N' (longest wait ', CONVERT(decimal(19, 1), @f_grant_wait_ms / 1000.0), N' s)') END,
                        N'; memory health ', ISNULL(@f_mh_desc, N'n/a'),
                        CASE WHEN @f_mh_high > 0 THEN CONCAT(N' (', @f_mh_high, N' high-severity snapshot(s) in the last ', @lookback_minutes, N' min)') END
                    )
                ),
                (
                    10, N'requests', CONVERT(nvarchar(30), @f_req_active),
                    CONCAT
                    (
                        ISNULL(@f_req_running, 0), N' running, ', ISNULL(@f_req_runnable, 0), N' runnable (waiting for CPU), ', ISNULL(@f_req_suspended, 0), N' suspended; ',
                        ISNULL(@f_req_parallel, 0), N' parallel, ', ISNULL(@f_req_pageio, 0), N' reading pages from storage; ',
                        ISNULL(@f_req_long, 0), N' running >= ', @long_running_seconds, N' s',
                        CASE WHEN @f_long_desc IS NOT NULL THEN CONCAT(N'; longest ', @f_long_s, N' s: ', @f_long_desc) END
                    )
                ),
                (
                    11, N'blocking', CONVERT(nvarchar(30), @f_blocked),
                    CASE
                        WHEN @f_blocked > 0
                        THEN CONCAT
                             (
                                 N'blocked session(s); ', @f_blk_heads, N' head blocker(s), ', @f_blk_sleeping_heads, N' of them sleeping; longest wait ',
                                 CONVERT(decimal(19, 1), @f_blk_max_wait_ms / 1000.0), N' s; worst head: session ', @f_head_session, N' blocks ', @f_head_total,
                                 N', ' + @f_head_state, N', ' + @f_head_who,
                                 CASE WHEN @f_blk_cycle > 0 THEN N'; blocking cycle detected' END
                             )
                        WHEN @f_blocked = 0 THEN N'No blocking.'
                    END
                ),
                (
                    12, N'waits_now', ISNULL(@f_top_wait_now, N'none'),
                    CONCAT
                    (
                        ISNULL(@f_waits_now, N'No tasks are in a non-benign wait right now.'),
                        CASE WHEN @f_gov_now > 0 THEN CONCAT(N'; ', @f_gov_now, N' task(s) throttled by governance: ', @f_gov_now_types) END
                    )
                ),
                (
                    13, CASE WHEN @is_sampled = 1 THEN N'waits_sampled' END, ISNULL(@f_top_wait_delta, N'none'),
                    CONCAT
                    (
                        ISNULL(@f_waits_delta, N'No non-benign waits in the sample.'),
                        N'; ', ISNULL(@f_wait_total_ms, 0), N' ms waited in ', @sample_s, N' s',
                        CASE WHEN @f_wait_gov_ms > 0 THEN CONCAT(N', of which ', @f_wait_gov_ms, N' ms governance') END
                    )
                ),
                (
                    14, N'transactions', CONVERT(nvarchar(30), @f_tran_open),
                    CONCAT
                    (
                        CASE
                            WHEN @f_tran_oldest_session IS NOT NULL
                            THEN CONCAT
                                 (
                                     N'oldest that runs or holds resources: session ', @f_tran_oldest_session, N', open ', @f_tran_oldest_s, N' s, ', @f_tran_oldest_state,
                                     N', ', ISNULL(CONVERT(nvarchar(30), @f_tran_oldest_log_mb), N'0'), N' MB of log'
                                 )
                            ELSE N'no open user transaction runs or holds locks, log or row versions'
                        END,
                        CASE WHEN @f_idle_tran > 0 THEN CONCAT(N'; ', @f_idle_tran, N' session(s) idle with an open transaction (longest idle ', @f_idle_tran_max_s, N' s), ', ISNULL(@f_idle_work, 0), N' of them hold resources') END
                    )
                ),
                (
                    15, N'tempdb', CONVERT(nvarchar(30), @f_tdb_data_pct) + N'%',
                    CONCAT
                    (
                        N'data ', ISNULL(CONVERT(nvarchar(30), @f_tdb_data_used_mb), N'n/a'), N' of ', ISNULL(CONVERT(nvarchar(30), @f_tdb_data_max_mb), N'n/a'),
                        N' MB used; log ', ISNULL(CONVERT(nvarchar(30), @f_tdb_log_pct), N'n/a'), N'% used',
                        CASE WHEN @f_tdb_top_session IS NOT NULL THEN CONCAT(N'; top session ', @f_tdb_top_session, N' (', @f_tdb_top_mb, N' MB)') END
                    )
                ),
                (
                    16, N'storage',
                    CASE
                        WHEN @f_data_pct IS NOT NULL THEN CONVERT(nvarchar(30), CONVERT(decimal(9, 1), @f_data_pct)) + N'%'
                        ELSE CONVERT(nvarchar(30), CONVERT(decimal(19, 1), @f_data_used_mb / 1024.0)) + N' GB'
                    END,
                    CONCAT
                    (
                        N'used ', ISNULL(CONVERT(nvarchar(30), CONVERT(decimal(19, 1), @f_data_used_mb / 1024.0)), N'n/a'),
                        N' GB, allocated ', ISNULL(CONVERT(nvarchar(30), CONVERT(decimal(19, 1), @f_data_alloc_mb / 1024.0)), N'n/a'),
                        N' GB, max ',
                        CASE
                            WHEN @f_data_max_mb IS NOT NULL THEN CONCAT(CONVERT(decimal(19, 1), @f_data_max_mb / 1024.0), N' GB')
                            WHEN @is_hyperscale = 1 THEN N'n/a (Hyperscale grows on demand)'
                            ELSE N'n/a'
                        END
                    )
                ),
                (
                    17, N'log', CONVERT(nvarchar(30), @f_log_used_pct) + N'%',
                    CONCAT(N'of ', ISNULL(@f_log_basis, N'n/a'), N' in use; log_reuse_wait_desc ', ISNULL(@f_log_reuse_wait, N'n/a'))
                ),
                (
                    18, N'version_store', CONVERT(nvarchar(30), @f_pvs_mb) + N' MB',
                    CONCAT
                    (
                        N'ADR persistent version store; ', ISNULL(@f_pvs_aborted, 0), N' aborted transaction(s) tracked',
                        CASE
                            WHEN @f_pvs_oldest_session IS NOT NULL THEN CONCAT(N'; oldest active transaction: session ', @f_pvs_oldest_session)
                            WHEN @f_pvs_oldest_xact > 0 THEN CONCAT(N'; oldest active transaction id ', @f_pvs_oldest_xact)
                        END
                    )
                ),
                (
                    19, N'query_store', @f_qs_state,
                    CONCAT
                    (
                        ISNULL(CONVERT(nvarchar(30), @f_qs_used_mb), N'n/a'), N' of ', ISNULL(CONVERT(nvarchar(30), @f_qs_max_mb), N'n/a'),
                        N' MB (', ISNULL(CONVERT(nvarchar(30), CONVERT(decimal(9, 1), @f_qs_pct)), N'n/a'), N'%), size-based cleanup ',
                        CASE @f_qs_cleanup_auto WHEN 1 THEN N'AUTO' WHEN 0 THEN N'OFF' ELSE N'n/a' END,
                        CASE WHEN @f_qs_readonly_reason > 0 THEN CONCAT(N', readonly_reason ', @f_qs_readonly_reason) END,
                        N'; automatic tuning: ', ISNULL(@f_at_mismatch, N'actual state matches desired'),
                        CASE WHEN @f_regressions > 0 THEN CONCAT(N'; ', @f_regressions, N' plan regression(s) not yet corrected') END,
                        CASE WHEN @f_force_total > 0 THEN CONCAT(N'; ', @f_force_total, N' forced plan(s) and hint(s), ', ISNULL(@f_force_failed, 0), N' with failures') END
                    )
                ),
                (
                    20, N'deadlocks',
                    CONVERT(nvarchar(30), ISNULL(@deadlock_count, @f_deadlocks_delta)),
                    CASE
                        WHEN @deadlock_count IS NULL AND @f_deadlocks_delta IS NULL
                        THEN N'Not checked: use @section = ''deadlocks'', @effort = ''slow'' or @sample_seconds > 0.'
                        ELSE CONCAT
                             (
                                 CASE WHEN @deadlock_count IS NOT NULL THEN CONCAT(@deadlock_count, N' in the last ', @lookback_minutes, N' min (XE ring buffer)') END,
                                 CASE WHEN @deadlock_count IS NOT NULL AND @f_deadlocks_delta IS NOT NULL THEN N'; ' END,
                                 CASE WHEN @f_deadlocks_delta IS NOT NULL THEN CONCAT(@f_deadlocks_delta, N' during the ', @sample_s, N' s sample (performance counter)') END
                             )
                    END
                ),
                (
                    21, N'replicas', CONVERT(nvarchar(30), @f_replica_rows),
                    CONCAT
                    (
                        N'replica and geo-replication link row(s); ',
                        CASE WHEN @f_ha_bad > 0 THEN @f_ha_desc ELSE N'no unhealthy HA replica reported' END,
                        CASE WHEN @f_geo_lag_s IS NOT NULL THEN CONCAT(N'; geo-replication lag ', @f_geo_lag_s, N' s to ', @f_geo_partner) END
                    )
                )
            ) AS v (ord, item, value, detail)
            WHERE v.item IS NOT NULL;
        END TRY
        BEGIN CATCH
            UPDATE #emit SET error_message = LEFT(ERROR_MESSAGE(), 4000) WHERE result_key = @rk;
        END CATCH;

        UPDATE #emit SET duration_ms = DATEDIFF_BIG(MILLISECOND, @t0, SYSDATETIME()) WHERE result_key = @rk;
    END;

    /* ============================================================================================
       9000 messages: errors first, then notes, then (@debug = 1) the timing of every result
       ============================================================================================ */
    DECLARE
        @m_sections nvarchar(1000),
        @m_results int;

    SELECT
        @rk = N'messages',
        @t0 = SYSDATETIME();

    INSERT #emit (section_order, section_key, result_key, result_name, table_name, empty_message)
    VALUES (9000, N'messages', @rk, N'MESSAGES (errors, notes and timings)', N'#o_messages', N'No messages.');

    INSERT #messages (msg_type, section, message)
    SELECT
        'ERROR',
        e.section_key,
        LEFT(CONCAT(e.result_key, N': ', e.error_message), 4000)
    FROM #emit AS e
    WHERE e.error_message IS NOT NULL
    ORDER BY
        e.section_order,
        e.result_key;

    IF @debug = 1
    BEGIN
        INSERT #messages (msg_type, section, message)
        SELECT
            'DEBUG',
            e.section_key,
            LEFT(CONCAT(e.result_key, N': ', ISNULL(e.duration_ms, 0), N' ms'), 4000)
        FROM #emit AS e
        WHERE e.result_key <> N'messages'
        ORDER BY
            e.section_order,
            e.result_key;
    END;

    SELECT
        @m_sections = STRING_AGG(CONVERT(nvarchar(max), s.section_name), N', ') WITHIN GROUP (ORDER BY s.section_name)
    FROM @sections AS s;

    SELECT
        @m_results = COUNT(*)
    FROM #emit AS e;

    INSERT #messages (msg_type, section, message)
    VALUES
    (
        'INFO',
        N'runtime',
        LEFT
        (
            CONCAT
            (
                N'usp_GetDBStatus ', @version, N' collected ', @m_results, N' result(s) in ', DATEDIFF_BIG(MILLISECOND, @run_start, SYSDATETIME()),
                N' ms; effort ', @effort_l, N', sections ', @m_sections,
                CASE WHEN @is_sampled = 1 THEN CONCAT(N', sampled over ', @sample_s, N' s') ELSE N', point in time' END,
                N', top_n ', @top_n, N', lookback ', @lookback_minutes, N' min, long running >= ', @long_running_seconds, N' s',
                CASE WHEN @include_plans = 1 THEN N', plans included' END
            ),
            4000
        )
    );

    BEGIN TRY
        SELECT
            rn = ROW_NUMBER() OVER (ORDER BY CASE m.msg_type WHEN 'ERROR' THEN 1 WHEN 'INFO' THEN 2 ELSE 3 END, m.id),
            msg_type = m.msg_type,
            section = m.section,
            message = m.message
        INTO #o_messages
        FROM #messages AS m;
    END TRY
    BEGIN CATCH
        UPDATE #emit SET error_message = LEFT(ERROR_MESSAGE(), 4000) WHERE result_key = @rk;
    END CATCH;

    UPDATE #emit SET duration_ms = DATEDIFF_BIG(MILLISECOND, @t0, SYSDATETIME()) WHERE result_key = @rk;

    /* ============================================================================================
       Emit every result in section order.
         normal     one grid per result; the first column is named after the result key and holds
                    rn, and columns ending in _text are clickable XML with control characters removed
         json       one row per result: [<key>_json]
         text       one row per result at the end: section_order, section_name, section_text
         textchunks the same JSON split into 3,900-character chunks: ..., chunk_no, chunk_text
       ============================================================================================ */
    DECLARE
        @e_key nvarchar(60),
        @e_name nvarchar(300),
        @e_table nvarchar(128),
        @e_empty nvarchar(400),
        @e_error nvarchar(4000),
        @e_rows bigint,
        @e_cols_normal nvarchar(max),
        @e_cols_plain nvarchar(max),
        @e_cols_json nvarchar(max),
        @e_clean nvarchar(max),
        @e_char int,
        @e_json nvarchar(max),
        @e_max_chunks int,
        @e_cursor CURSOR;

    /* REPLACE chain for one column ({c}): NUL and control characters other than tab, LF and CR */
    SET @e_clean = N'REPLACE(CONVERT(nvarchar(max), {c}) COLLATE Latin1_General_100_BIN2, NCHAR(0), N'''')';
    SET @e_char = 1;

    WHILE @e_char <= 31
    BEGIN
        IF @e_char NOT IN (9, 10, 13)
        BEGIN
            SET @e_clean = CONCAT(N'REPLACE(', @e_clean, N', NCHAR(', @e_char, N'), N'' '')');
        END;

        SET @e_char += 1;
    END;

    SET @e_cursor = CURSOR LOCAL FAST_FORWARD FOR
        SELECT
            e.result_key,
            e.result_name,
            e.table_name,
            e.empty_message,
            e.error_message
        FROM #emit AS e
        ORDER BY
            e.section_order,
            e.result_key;

    OPEN @e_cursor;

    WHILE 1 = 1
    BEGIN
        FETCH NEXT FROM @e_cursor INTO @e_key, @e_name, @e_table, @e_empty, @e_error;

        IF @@FETCH_STATUS <> 0
            BREAK;

        SET @msg = LEFT(N'=== ' + @e_name + N' ===', 4000);
        PRINT @msg;

        SELECT
            @e_rows = NULL,
            @e_cols_normal = NULL,
            @e_cols_plain = NULL,
            @e_cols_json = NULL,
            @e_json = NULL;

        DELETE #emit_cols;

        IF  @e_error IS NULL
        AND @e_table IS NOT NULL
        AND OBJECT_ID(N'tempdb..' + @e_table) IS NOT NULL
        BEGIN
            BEGIN TRY
                SET @sql = N'SELECT @n = COUNT_BIG(*) FROM ' + @e_table + N';';
                EXEC sys.sp_executesql @sql, N'@n bigint OUTPUT', @n = @e_rows OUTPUT;
            END TRY
            BEGIN CATCH
                SET @e_error = LEFT(ERROR_MESSAGE(), 4000);
            END CATCH;

            /* tempdb.sys.columns first; dm_exec_describe_first_result_set when tempdb is not reachable */
            BEGIN TRY
                SET @sql = N'
INSERT #emit_cols (column_id, column_name, system_type_id)
SELECT
    c.column_id,
    c.name,
    c.system_type_id
FROM tempdb.sys.columns AS c
WHERE c.object_id = OBJECT_ID(N''tempdb..' + @e_table + N''');';

                EXEC sys.sp_executesql @sql;
            END TRY
            BEGIN CATCH
                DELETE #emit_cols;
            END CATCH;

            IF NOT EXISTS (SELECT 1/0 FROM #emit_cols)
            BEGIN
                BEGIN TRY
                    SET @sql = N'SELECT * FROM ' + @e_table + N';';

                    INSERT #emit_cols (column_id, column_name, system_type_id)
                    SELECT
                        d.column_ordinal,
                        d.name,
                        d.system_type_id
                    FROM sys.dm_exec_describe_first_result_set(@sql, NULL, 0) AS d
                    WHERE d.is_hidden = 0
                    AND   d.name IS NOT NULL;
                END TRY
                BEGIN CATCH
                    DELETE #emit_cols;
                END CATCH;
            END;

            IF @e_error IS NULL AND EXISTS (SELECT 1/0 FROM #emit_cols)
            BEGIN
                SELECT
                    @e_cols_normal =
                        STRING_AGG
                        (
                            CONVERT
                            (
                                nvarchar(max),
                                CASE
                                    WHEN c.column_name = N'rn'
                                    THEN QUOTENAME(@e_key) + N' = o.[rn]'
                                    WHEN c.column_name LIKE N'%[_]text'
                                    THEN QUOTENAME(c.column_name)
                                         + N' = (SELECT [processing-instruction(q)] = N''--'' + NCHAR(13) + NCHAR(10) + REPLACE('
                                         + REPLACE(@e_clean, N'{c}', N'o.' + QUOTENAME(c.column_name))
                                         + N', N''?>'', N''? >'') + NCHAR(13) + NCHAR(10) + N''--'' FOR XML PATH(N''''), TYPE)'
                                    ELSE N'o.' + QUOTENAME(c.column_name)
                                END
                            ),
                            N', '
                        ) WITHIN GROUP (ORDER BY CASE WHEN c.column_name = N'rn' THEN 0 ELSE c.column_id END)
                FROM #emit_cols AS c;

                SELECT
                    @e_cols_plain =
                        STRING_AGG
                        (
                            CONVERT
                            (
                                nvarchar(max),
                                CASE
                                    WHEN c.column_name = N'rn' THEN QUOTENAME(@e_key) + N' = o.[rn]'
                                    ELSE N'o.' + QUOTENAME(c.column_name)
                                END
                            ),
                            N', '
                        ) WITHIN GROUP (ORDER BY CASE WHEN c.column_name = N'rn' THEN 0 ELSE c.column_id END)
                FROM #emit_cols AS c;

                /* FOR JSON: xml as text, binary as 0x hex, sql_variant as text */
                SELECT
                    @e_cols_json =
                        STRING_AGG
                        (
                            CONVERT
                            (
                                nvarchar(max),
                                CASE
                                    WHEN c.system_type_id = 241 THEN N'CONVERT(nvarchar(max), o.' + QUOTENAME(c.column_name) + N') AS ' + QUOTENAME(c.column_name)
                                    WHEN c.system_type_id IN (165, 173) THEN N'CONVERT(varchar(max), o.' + QUOTENAME(c.column_name) + N', 1) AS ' + QUOTENAME(c.column_name)
                                    WHEN c.system_type_id = 98 THEN N'CONVERT(nvarchar(4000), o.' + QUOTENAME(c.column_name) + N') AS ' + QUOTENAME(c.column_name)
                                    ELSE N'o.' + QUOTENAME(c.column_name)
                                END
                            ),
                            N', '
                        ) WITHIN GROUP (ORDER BY CASE WHEN c.column_name = N'rn' THEN 0 ELSE c.column_id END)
                FROM #emit_cols AS c;
            END;

            /* Column discovery failed: show the table as it is rather than reporting no data */
            IF @e_error IS NULL AND @e_cols_normal IS NULL
            BEGIN
                SELECT
                    @e_cols_normal = N'o.*',
                    @e_cols_plain = N'o.*',
                    @e_cols_json = N'o.*';
            END;
        END;

        IF @output_l = N'normal'
        BEGIN
            IF  @e_error IS NULL
            AND @e_cols_normal IS NOT NULL
            AND (@e_rows > 0 OR (@e_rows = 0 AND @e_empty IS NULL))
            BEGIN
                SET @sql = N'SELECT ' + @e_cols_normal + N' FROM ' + @e_table + N' AS o ORDER BY o.[rn];';

                IF @debug = 1 PRINT @sql;

                BEGIN TRY
                    EXEC sys.sp_executesql @sql;
                END TRY
                BEGIN CATCH
                    /* Text that still cannot be shown as XML: fall back to plain columns */
                    SET @msg = LEFT(N'Result ' + @e_key + N' is shown without XML formatting: ' + ERROR_MESSAGE(), 4000);
                    PRINT @msg;

                    BEGIN TRY
                        SET @sql = N'SELECT ' + @e_cols_plain + N' FROM ' + @e_table + N' AS o ORDER BY o.[rn];';
                        EXEC sys.sp_executesql @sql;
                    END TRY
                    BEGIN CATCH
                        SET @msg = LEFT(N'ERROR: ' + ERROR_MESSAGE(), 4000);
                        SET @sql = N'SELECT ' + QUOTENAME(@e_key) + N' = @m;';
                        EXEC sys.sp_executesql @sql, N'@m nvarchar(4000)', @m = @msg;
                    END CATCH;
                END CATCH;
            END
            ELSE
            BEGIN
                SET @msg =
                    CASE
                        WHEN @e_error IS NOT NULL THEN LEFT(N'ERROR: ' + @e_error, 4000)
                        ELSE ISNULL(@e_empty, N'No data.')
                    END;

                SET @sql = N'SELECT ' + QUOTENAME(@e_key) + N' = @m;';
                EXEC sys.sp_executesql @sql, N'@m nvarchar(4000)', @m = @msg;
            END;
        END
        ELSE
        BEGIN
            IF @e_error IS NOT NULL
            BEGIN
                SET @e_json = (SELECT [error] = @e_error FOR JSON PATH);
            END
            ELSE IF @e_rows > 0 AND @e_cols_json IS NOT NULL
            BEGIN
                SET @sql = N'SET @j = (SELECT ' + @e_cols_json + N' FROM ' + @e_table + N' AS o ORDER BY o.[rn] FOR JSON PATH, INCLUDE_NULL_VALUES);';

                IF @debug = 1 PRINT @sql;

                BEGIN TRY
                    EXEC sys.sp_executesql @sql, N'@j nvarchar(max) OUTPUT', @j = @e_json OUTPUT;
                END TRY
                BEGIN CATCH
                    SET @msg = LEFT(ERROR_MESSAGE(), 4000);
                    SET @e_json = (SELECT [error] = @msg FOR JSON PATH);
                END CATCH;
            END;

            SET @e_json = ISNULL(@e_json, N'[]');

            IF @output_l = N'json'
            BEGIN
                SET @sql = N'SELECT ' + QUOTENAME(@e_key + N'_json') + N' = @j;';
                EXEC sys.sp_executesql @sql, N'@j nvarchar(max)', @j = @e_json;
            END
            ELSE
            BEGIN
                INSERT #textout (section_name, payload)
                VALUES (@e_name, @e_json);
            END;
        END;
    END;

    CLOSE @e_cursor;
    DEALLOCATE @e_cursor;

    PRINT '=== DIAGNOSTICS COMPLETE ===';

    IF @output_l = N'text'
    BEGIN
        SELECT
            section_order = t.id,
            section_name = t.section_name,
            section_text = t.payload
        FROM #textout AS t
        ORDER BY
            t.id;
    END;

    IF @output_l = N'textchunks'
    BEGIN
        SELECT
            @e_max_chunks = MAX(CONVERT(int, (LEN(t.payload) + 3899) / 3900))
        FROM #textout AS t;

        WITH n AS
        (
            SELECT TOP (ISNULL(@e_max_chunks, 1))
                n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL))
            FROM sys.all_objects AS a
            CROSS JOIN sys.all_objects AS b
        )
        SELECT
            section_order = t.id,
            section_name = t.section_name,
            chunk_no = n.n,
            chunk_text = SUBSTRING(t.payload, ((n.n - 1) * 3900) + 1, 3900)
        FROM #textout AS t
        JOIN n
          ON (n.n - 1) * 3900 < LEN(t.payload)
        ORDER BY
            t.id,
            n.n;
    END;
END;
GO
