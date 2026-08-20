-- accurateCastOrDefault and the to*OrDefault functions inside a cached materialized view select plan:
-- the plan (and its prepared functions) outlives the query context of the insert that captured it.

DROP TABLE IF EXISTS t_mvpc_cod_src;
DROP TABLE IF EXISTS t_mvpc_cod_dst;
DROP TABLE IF EXISTS t_mvpc_cod_dst2;
DROP VIEW IF EXISTS t_mvpc_cod_mv;
DROP VIEW IF EXISTS t_mvpc_cod_mv2;

CREATE TABLE t_mvpc_cod_src (k UInt64, raw String, s String, ds String, ns Nullable(String), lc LowCardinality(String), dt DateTime('Europe/Moscow'), def UInt32) ENGINE = MergeTree ORDER BY k;
CREATE TABLE t_mvpc_cod_dst
(
    k UInt64,
    region Nullable(String),
    n UInt32,
    n_def UInt32,
    n_col UInt32,
    n_keep Nullable(UInt32),
    lc_n UInt32,
    dt_cast DateTime('Europe/Moscow'),
    j_type String,
    t32 UInt32,
    t32_def UInt32,
    t64 DateTime64(3, 'UTC'),
    tdec Decimal(9, 2),
    c UInt32
)
ENGINE = MergeTree ORDER BY k;
CREATE TABLE t_mvpc_cod_dst2 (k UInt64, n UInt32) ENGINE = MergeTree ORDER BY k;

CREATE MATERIALIZED VIEW t_mvpc_cod_mv TO t_mvpc_cod_dst AS
    SELECT
        k,
        accurateCastOrDefault(JSONExtract(raw, 'context', 'region', 'Nullable(String)'), 'Nullable(String)') AS region,
        accurateCastOrDefault(s, 'UInt32') AS n,
        accurateCastOrDefault(s, 'UInt32', 99::UInt32) AS n_def,
        accurateCastOrDefault(s, 'UInt32', def) AS n_col,
        accurateCastOrDefault(ns, 'UInt32') AS n_keep,
        accurateCastOrDefault(lc, 'UInt32') AS lc_n,
        accurateCastOrDefault(dt, 'DateTime') AS dt_cast,
        dynamicType(accurateCastOrDefault(raw, 'JSON').d) AS j_type,
        toUInt32OrDefault(s) AS t32,
        toUInt32OrDefault(s, 42::UInt32) AS t32_def,
        toDateTime64OrDefault(ds, 3, 'UTC') AS t64,
        toDecimal32OrDefault(s, 2) AS tdec,
        accurateCastOrDefault('x', 'UInt32') AS c
    FROM t_mvpc_cod_src
    SETTINGS cast_keep_nullable = 1, input_format_try_infer_dates = 1, enable_analyzer = 1;

CREATE MATERIALIZED VIEW t_mvpc_cod_mv2 TO t_mvpc_cod_dst2 AS
    SELECT k, accurateCastOrDefault(s, 'UInt32') AS n FROM t_mvpc_cod_src;

SET use_materialized_view_select_plan_cache = 1;

INSERT INTO t_mvpc_cod_src VALUES (1, '{"context":{"region":"eu"},"d":"2020-01-01"}', '12', '2024-01-02 03:04:05.678', '7', '5', toDateTime('2020-01-01 00:00:00', 'Europe/Moscow'), 1);
INSERT INTO t_mvpc_cod_src VALUES (2, '{"context":{}}', 'abc', 'not a date', NULL, 'x', toDateTime('2021-01-01 00:00:00', 'Europe/Moscow'), 2);
INSERT INTO t_mvpc_cod_src VALUES (3, '{"context":{"region":"us"},"d":"not a date"}', '3.5', '', 'q', '9', toDateTime('2022-01-01 00:00:00', 'Europe/Moscow'), 3);
INSERT INTO t_mvpc_cod_src VALUES (4, '{}', 'x', '25 Jul 2024 10:00:00', '25 Jul 2024 10:00:00', '25 Jul 2024 10:00:00', toDateTime('2023-01-01 00:00:00', 'Europe/Moscow'), 4);

SELECT * FROM t_mvpc_cod_dst ORDER BY k;
SELECT * FROM t_mvpc_cod_dst2 ORDER BY k;
SELECT toTypeName(accurateCastOrDefault(dt, 'DateTime')) FROM t_mvpc_cod_src LIMIT 1;

-- The same inserts with the cache disabled produce the identical rows.
TRUNCATE TABLE t_mvpc_cod_dst;
TRUNCATE TABLE t_mvpc_cod_dst2;
SET use_materialized_view_select_plan_cache = 0;
INSERT INTO t_mvpc_cod_src VALUES (1, '{"context":{"region":"eu"},"d":"2020-01-01"}', '12', '2024-01-02 03:04:05.678', '7', '5', toDateTime('2020-01-01 00:00:00', 'Europe/Moscow'), 1);
INSERT INTO t_mvpc_cod_src VALUES (2, '{"context":{}}', 'abc', 'not a date', NULL, 'x', toDateTime('2021-01-01 00:00:00', 'Europe/Moscow'), 2);
INSERT INTO t_mvpc_cod_src VALUES (3, '{"context":{"region":"us"},"d":"not a date"}', '3.5', '', 'q', '9', toDateTime('2022-01-01 00:00:00', 'Europe/Moscow'), 3);
INSERT INTO t_mvpc_cod_src VALUES (4, '{}', 'x', '25 Jul 2024 10:00:00', '25 Jul 2024 10:00:00', '25 Jul 2024 10:00:00', toDateTime('2023-01-01 00:00:00', 'Europe/Moscow'), 4);
SELECT * FROM t_mvpc_cod_dst ORDER BY k;
SELECT * FROM t_mvpc_cod_dst2 ORDER BY k;

-- The cached plan was actually reused. The cache events are attributed to the view,
-- so they are read from `query_views_log`.
SYSTEM FLUSH LOGS query_views_log;
SELECT
    view_name,
    sum(ProfileEvents['MaterializedViewSelectPlanCacheMisses']) >= 1 AS has_misses,
    sum(ProfileEvents['MaterializedViewSelectPlanCacheHits']) >= 1 AS has_hits
FROM system.query_views_log
WHERE view_name IN (currentDatabase() || '.t_mvpc_cod_mv', currentDatabase() || '.t_mvpc_cod_mv2')
GROUP BY view_name
ORDER BY view_name;

DROP VIEW t_mvpc_cod_mv;
DROP VIEW t_mvpc_cod_mv2;
DROP TABLE t_mvpc_cod_src;
DROP TABLE t_mvpc_cod_dst;
DROP TABLE t_mvpc_cod_dst2;
