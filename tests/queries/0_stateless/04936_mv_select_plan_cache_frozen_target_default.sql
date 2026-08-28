-- Tags: no-parallel-replicas
-- no-parallel-replicas: dictionary source tables are not available on parallel-replica workers.

-- The conversion of a view select's output to its target structure fills in the target columns
-- the select does not supply, from their DEFAULT or MATERIALIZED expression. Building it folds a
-- call that returns a constant column, whether or not the function is deterministic, so the
-- folded value is the one the capturing insert computed. The cache stores that conversion, so
-- every later insert hitting the entry would write that same value again. Such a view must not
-- be cached.
--
-- A call that returns a full column is not folded and is executed per block by the stored actions
-- exactly as by freshly built ones, and a column the select supplies never reaches its default;
-- both keep their cached plan.

SET use_materialized_view_select_plan_cache = 1;

-- ------------------------------------------------------------------------------------------
-- Constant within one query: the value is fixed when the entry is captured.
-- ------------------------------------------------------------------------------------------

CREATE TABLE t_mvpcd_src (k UInt64, v UInt64) ENGINE = MergeTree ORDER BY k;

CREATE TABLE t_mvpcd_now (k UInt64, s UInt64, d DateTime DEFAULT now()) ENGINE = MergeTree ORDER BY k;
CREATE MATERIALIZED VIEW t_mvpcd_mv_now TO t_mvpcd_now AS
    SELECT k, sum(v) AS s FROM t_mvpcd_src GROUP BY k;

-- A MATERIALIZED column can never be supplied by a select, so it always refuses.
CREATE TABLE t_mvpcd_mat (k UInt64, s UInt64, m DateTime MATERIALIZED now()) ENGINE = MergeTree ORDER BY k;
CREATE MATERIALIZED VIEW t_mvpcd_mv_mat TO t_mvpcd_mat AS
    SELECT k, sum(v) AS s FROM t_mvpcd_src GROUP BY k;

-- The fold may sit under a deterministic call.
CREATE TABLE t_mvpcd_nested (k UInt64, s UInt64, d DateTime DEFAULT toDateTime(now(), 'UTC'))
    ENGINE = MergeTree ORDER BY k;
CREATE MATERIALIZED VIEW t_mvpcd_mv_nested TO t_mvpcd_nested AS
    SELECT k, sum(v) AS s FROM t_mvpcd_src GROUP BY k;

-- ... and next to a column the select does supply.
CREATE TABLE t_mvpcd_mixed (k UInt64, s UInt64, d DateTime DEFAULT now() + k) ENGINE = MergeTree ORDER BY k;
CREATE MATERIALIZED VIEW t_mvpcd_mv_mixed TO t_mvpcd_mixed AS
    SELECT k, sum(v) AS s FROM t_mvpcd_src GROUP BY k;

-- An ALIAS column is not in the target's sample block, but a default referencing it pulls its
-- expression into the conversion all the same.
CREATE TABLE t_mvpcd_alias (k UInt64, s UInt64, q DateTime ALIAS now(), d DateTime DEFAULT q)
    ENGINE = MergeTree ORDER BY k;
CREATE MATERIALIZED VIEW t_mvpcd_mv_alias TO t_mvpcd_alias AS
    SELECT k, sum(v) AS s FROM t_mvpcd_src GROUP BY k;

-- A second apart, so that `now()` differs per insert at its own resolution.
INSERT INTO t_mvpcd_src VALUES (1, 10);
SELECT sleep(1) FORMAT Null;
INSERT INTO t_mvpcd_src VALUES (2, 20);
SELECT sleep(1) FORMAT Null;
INSERT INTO t_mvpcd_src VALUES (3, 30);

SELECT 'now', uniqExact(d) FROM t_mvpcd_now;
SELECT 'materialized', uniqExact(m) FROM t_mvpcd_mat;
SELECT 'nested', uniqExact(d) FROM t_mvpcd_nested;
SELECT 'alias', uniqExact(d) FROM t_mvpcd_alias;
SELECT 'rows', k, s FROM t_mvpcd_now ORDER BY k;

SYSTEM FLUSH LOGS query_views_log;
SELECT
    splitByChar('.', view_name)[2] AS view,
    sum(ProfileEvents['MaterializedViewSelectPlanCacheSkippedNonDeterministic']) >= 1 AS skipped,
    sum(ProfileEvents['MaterializedViewSelectPlanCacheMisses']) AS misses,
    sum(ProfileEvents['MaterializedViewSelectPlanCacheHits']) AS hits
FROM system.query_views_log
WHERE view_name IN (
    currentDatabase() || '.t_mvpcd_mv_now', currentDatabase() || '.t_mvpcd_mv_mat',
    currentDatabase() || '.t_mvpcd_mv_nested', currentDatabase() || '.t_mvpcd_mv_mixed',
    currentDatabase() || '.t_mvpcd_mv_alias')
GROUP BY view ORDER BY view;

-- ------------------------------------------------------------------------------------------
-- Volatile per call: folded only when the call returns a constant column, which for these
-- functions means when every argument is a constant.
-- ------------------------------------------------------------------------------------------

CREATE TABLE t_mvpcd_src_vol (k UInt64, v UInt64) ENGINE = MergeTree ORDER BY k;

-- `generateULID` uses the constant-argument implementation, so given an argument it returns a
-- constant column and the call is folded, although it is volatile per call.
CREATE TABLE t_mvpcd_ulid_arg (k UInt64, s UInt64, u String DEFAULT generateULID(1))
    ENGINE = MergeTree ORDER BY k;
CREATE MATERIALIZED VIEW t_mvpcd_mv_ulid_arg TO t_mvpcd_ulid_arg AS
    SELECT k, sum(v) AS s FROM t_mvpcd_src_vol GROUP BY k;

-- The argument need not be written as a literal: the default of another column the select omits
-- is inlined first, and the call becomes foldable through it.
CREATE TABLE t_mvpcd_ulid_ident (k UInt64, s UInt64, n UInt8 DEFAULT 1, u String DEFAULT generateULID(n))
    ENGINE = MergeTree ORDER BY k;
CREATE MATERIALIZED VIEW t_mvpcd_mv_ulid_ident TO t_mvpcd_ulid_ident AS
    SELECT k, sum(v) AS s FROM t_mvpcd_src_vol GROUP BY k;

-- Without arguments the same function returns a full column, is not folded, and stays cacheable.
CREATE TABLE t_mvpcd_ulid (k UInt64, s UInt64, u String DEFAULT generateULID())
    ENGINE = MergeTree ORDER BY k;
CREATE MATERIALIZED VIEW t_mvpcd_mv_ulid TO t_mvpcd_ulid AS
    SELECT k, sum(v) AS s FROM t_mvpcd_src_vol GROUP BY k;

-- So does a random function over a constant length, which does not use that implementation.
CREATE TABLE t_mvpcd_ascii (k UInt64, s UInt64, t String DEFAULT randomPrintableASCII(16))
    ENGINE = MergeTree ORDER BY k;
CREATE MATERIALIZED VIEW t_mvpcd_mv_ascii TO t_mvpcd_ascii AS
    SELECT k, sum(v) AS s FROM t_mvpcd_src_vol GROUP BY k;

CREATE TABLE t_mvpcd_rand (k UInt64, s UInt64, r UInt64 DEFAULT rand64()) ENGINE = MergeTree ORDER BY k;
CREATE MATERIALIZED VIEW t_mvpcd_mv_rand TO t_mvpcd_rand AS
    SELECT k, sum(v) AS s FROM t_mvpcd_src_vol GROUP BY k;

INSERT INTO t_mvpcd_src_vol VALUES (1, 10);
INSERT INTO t_mvpcd_src_vol VALUES (2, 20);
INSERT INTO t_mvpcd_src_vol VALUES (3, 30);

-- Every one of these must write three distinct values: the refused ones because they are not
-- cached, the cacheable ones because their stored actions still evaluate the call per block.
SELECT 'ulid_arg', uniqExact(u) FROM t_mvpcd_ulid_arg;
SELECT 'ulid_ident', uniqExact(u) FROM t_mvpcd_ulid_ident;
SELECT 'ulid', uniqExact(u) FROM t_mvpcd_ulid;
SELECT 'ascii', uniqExact(t) FROM t_mvpcd_ascii;
SELECT 'rand', uniqExact(r) FROM t_mvpcd_rand;

SYSTEM FLUSH LOGS query_views_log;
SELECT
    splitByChar('.', view_name)[2] AS view,
    sum(ProfileEvents['MaterializedViewSelectPlanCacheSkippedNonDeterministic']) >= 1 AS skipped,
    sum(ProfileEvents['MaterializedViewSelectPlanCacheMisses']) AS misses,
    sum(ProfileEvents['MaterializedViewSelectPlanCacheHits']) >= 1 AS hits
FROM system.query_views_log
WHERE view_name IN (
    currentDatabase() || '.t_mvpcd_mv_ulid_arg', currentDatabase() || '.t_mvpcd_mv_ulid_ident',
    currentDatabase() || '.t_mvpcd_mv_ulid', currentDatabase() || '.t_mvpcd_mv_ascii',
    currentDatabase() || '.t_mvpcd_mv_rand')
GROUP BY view ORDER BY view;

-- ------------------------------------------------------------------------------------------
-- A dictionary lookup over an inlined key: the value follows the dictionary, not the insert.
-- ------------------------------------------------------------------------------------------

CREATE TABLE t_mvpcd_dict_src (id UInt64, name String) ENGINE = MergeTree ORDER BY id;
INSERT INTO t_mvpcd_dict_src VALUES (1, 'one');

CREATE DICTIONARY t_mvpcd_dict (id UInt64, name String DEFAULT '?')
PRIMARY KEY id
SOURCE(CLICKHOUSE(TABLE 't_mvpcd_dict_src'))
LAYOUT(FLAT())
LIFETIME(0);

CREATE TABLE t_mvpcd_src_dict (k UInt64, v UInt64) ENGINE = MergeTree ORDER BY k;
CREATE TABLE t_mvpcd_labelled (k UInt64, s UInt64, id UInt64 DEFAULT 1,
                               label String DEFAULT dictGet('t_mvpcd_dict', 'name', id))
    ENGINE = MergeTree ORDER BY k;
CREATE MATERIALIZED VIEW t_mvpcd_mv_labelled TO t_mvpcd_labelled AS
    SELECT k, sum(v) AS s FROM t_mvpcd_src_dict GROUP BY k;

INSERT INTO t_mvpcd_src_dict VALUES (1, 10);

TRUNCATE TABLE t_mvpcd_dict_src;
INSERT INTO t_mvpcd_dict_src VALUES (1, 'two');
SYSTEM RELOAD DICTIONARY t_mvpcd_dict;
INSERT INTO t_mvpcd_src_dict VALUES (2, 20);

TRUNCATE TABLE t_mvpcd_dict_src;
INSERT INTO t_mvpcd_dict_src VALUES (1, 'three');
SYSTEM RELOAD DICTIONARY t_mvpcd_dict;
INSERT INTO t_mvpcd_src_dict VALUES (3, 30);

SELECT 'labelled', k, label FROM t_mvpcd_labelled ORDER BY k;

SYSTEM FLUSH LOGS query_views_log;
SELECT
    splitByChar('.', view_name)[2] AS view,
    sum(ProfileEvents['MaterializedViewSelectPlanCacheSkippedNonDeterministic']) >= 1 AS skipped,
    sum(ProfileEvents['MaterializedViewSelectPlanCacheMisses']) AS misses,
    sum(ProfileEvents['MaterializedViewSelectPlanCacheHits']) AS hits
FROM system.query_views_log
WHERE view_name = currentDatabase() || '.t_mvpcd_mv_labelled'
GROUP BY view;

-- ------------------------------------------------------------------------------------------
-- Supplied by the select: the column is taken from the block and its default is never evaluated,
-- so a target column that would fold on its own does not cost the view its plan.
-- ------------------------------------------------------------------------------------------

CREATE TABLE t_mvpcd_src_supplied (k UInt64, v UInt64, dt DateTime64(6, 'UTC')) ENGINE = MergeTree ORDER BY k;
CREATE TABLE t_mvpcd_supplied (k UInt64, s UInt64, dt DateTime64(6, 'UTC') DEFAULT now64(6))
    ENGINE = MergeTree ORDER BY (dt, k);
CREATE MATERIALIZED VIEW t_mvpcd_mv_supplied TO t_mvpcd_supplied AS
    SELECT k, sum(v) AS s, max(dt) AS dt FROM t_mvpcd_src_supplied GROUP BY k;

INSERT INTO t_mvpcd_src_supplied VALUES (1, 10, '2020-01-01 00:00:01.000000');
INSERT INTO t_mvpcd_src_supplied VALUES (2, 20, '2020-01-01 00:00:02.000000');
INSERT INTO t_mvpcd_src_supplied VALUES (3, 30, '2020-01-01 00:00:03.000000');

SELECT 'supplied', k, s, dt FROM t_mvpcd_supplied ORDER BY k;

SYSTEM FLUSH LOGS query_views_log;
SELECT
    splitByChar('.', view_name)[2] AS view,
    sum(ProfileEvents['MaterializedViewSelectPlanCacheSkippedNonDeterministic']) AS skipped,
    sum(ProfileEvents['MaterializedViewSelectPlanCacheHits']) >= 1 AS hits
FROM system.query_views_log
WHERE view_name = currentDatabase() || '.t_mvpcd_mv_supplied'
GROUP BY view;

-- ------------------------------------------------------------------------------------------
-- The same holds without the analyzer, which builds the default expressions differently.
-- ------------------------------------------------------------------------------------------

SET allow_experimental_analyzer = 0;

CREATE TABLE t_mvpcd_src_old (k UInt64, v UInt64) ENGINE = MergeTree ORDER BY k;
CREATE TABLE t_mvpcd_ulid_old (k UInt64, s UInt64, u String DEFAULT generateULID(1))
    ENGINE = MergeTree ORDER BY k;
CREATE MATERIALIZED VIEW t_mvpcd_mv_ulid_old TO t_mvpcd_ulid_old AS
    SELECT k, sum(v) AS s FROM t_mvpcd_src_old GROUP BY k;
CREATE TABLE t_mvpcd_ascii_old (k UInt64, s UInt64, t String DEFAULT randomPrintableASCII(16))
    ENGINE = MergeTree ORDER BY k;
CREATE MATERIALIZED VIEW t_mvpcd_mv_ascii_old TO t_mvpcd_ascii_old AS
    SELECT k, sum(v) AS s FROM t_mvpcd_src_old GROUP BY k;

INSERT INTO t_mvpcd_src_old VALUES (1, 10);
INSERT INTO t_mvpcd_src_old VALUES (2, 20);
INSERT INTO t_mvpcd_src_old VALUES (3, 30);

SELECT 'ulid_arg_old', uniqExact(u) FROM t_mvpcd_ulid_old;
SELECT 'ascii_old', uniqExact(t) FROM t_mvpcd_ascii_old;

SYSTEM FLUSH LOGS query_views_log;
SELECT
    splitByChar('.', view_name)[2] AS view,
    sum(ProfileEvents['MaterializedViewSelectPlanCacheSkippedNonDeterministic']) >= 1 AS skipped,
    sum(ProfileEvents['MaterializedViewSelectPlanCacheHits']) >= 1 AS hits
FROM system.query_views_log
WHERE view_name IN (currentDatabase() || '.t_mvpcd_mv_ulid_old', currentDatabase() || '.t_mvpcd_mv_ascii_old')
GROUP BY view ORDER BY view;

SET allow_experimental_analyzer = DEFAULT;

DROP VIEW t_mvpcd_mv_now;
DROP VIEW t_mvpcd_mv_mat;
DROP VIEW t_mvpcd_mv_nested;
DROP VIEW t_mvpcd_mv_mixed;
DROP VIEW t_mvpcd_mv_alias;
DROP VIEW t_mvpcd_mv_ulid_arg;
DROP VIEW t_mvpcd_mv_ulid_ident;
DROP VIEW t_mvpcd_mv_ulid;
DROP VIEW t_mvpcd_mv_ascii;
DROP VIEW t_mvpcd_mv_rand;
DROP VIEW t_mvpcd_mv_labelled;
DROP VIEW t_mvpcd_mv_supplied;
DROP VIEW t_mvpcd_mv_ulid_old;
DROP VIEW t_mvpcd_mv_ascii_old;
DROP TABLE t_mvpcd_src;
DROP TABLE t_mvpcd_src_vol;
DROP TABLE t_mvpcd_src_dict;
DROP TABLE t_mvpcd_src_supplied;
DROP TABLE t_mvpcd_src_old;
DROP TABLE t_mvpcd_now;
DROP TABLE t_mvpcd_mat;
DROP TABLE t_mvpcd_nested;
DROP TABLE t_mvpcd_mixed;
DROP TABLE t_mvpcd_alias;
DROP TABLE t_mvpcd_ulid_arg;
DROP TABLE t_mvpcd_ulid_ident;
DROP TABLE t_mvpcd_ulid;
DROP TABLE t_mvpcd_ascii;
DROP TABLE t_mvpcd_rand;
DROP TABLE t_mvpcd_labelled;
DROP TABLE t_mvpcd_supplied;
DROP TABLE t_mvpcd_ulid_old;
DROP TABLE t_mvpcd_ascii_old;
DROP DICTIONARY t_mvpcd_dict;
DROP TABLE t_mvpcd_dict_src;
