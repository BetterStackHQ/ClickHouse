-- Basic behaviour of the materialized view select plan cache: the second insert
-- reuses the cached plan and produces the same result as with the cache disabled.

DROP TABLE IF EXISTS t_mvpc_src;
DROP TABLE IF EXISTS t_mvpc_dst;
DROP VIEW IF EXISTS t_mvpc_mv;

CREATE TABLE t_mvpc_src (k UInt64, s String, v Float64) ENGINE = MergeTree ORDER BY k;
CREATE TABLE t_mvpc_dst (bucket UInt64, cnt SimpleAggregateFunction(sum, UInt64), sum_v SimpleAggregateFunction(sum, Float64), top_s AggregateFunction(anyHeavy, String)) ENGINE = AggregatingMergeTree ORDER BY bucket;
CREATE MATERIALIZED VIEW t_mvpc_mv TO t_mvpc_dst AS
    SELECT k % 10 AS bucket, count() AS cnt, sum(v) AS sum_v, anyHeavyState(s) AS top_s
    FROM t_mvpc_src
    GROUP BY bucket;

SET use_mv_select_plan_cache = 1;

INSERT INTO t_mvpc_src SELECT number, toString(number % 7), number / 3 FROM numbers(1000);
INSERT INTO t_mvpc_src SELECT number, toString(number % 7), number / 3 FROM numbers(1000, 1000);

SELECT bucket, sum(cnt), round(sum(sum_v), 3) FROM t_mvpc_dst GROUP BY bucket ORDER BY bucket;

-- The same inserts without the cache must produce the identical result.
DROP TABLE t_mvpc_dst SYNC;
CREATE TABLE t_mvpc_dst (bucket UInt64, cnt SimpleAggregateFunction(sum, UInt64), sum_v SimpleAggregateFunction(sum, Float64), top_s AggregateFunction(anyHeavy, String)) ENGINE = AggregatingMergeTree ORDER BY bucket;
SET use_mv_select_plan_cache = 0;
INSERT INTO t_mvpc_src SELECT number, toString(number % 7), number / 3 FROM numbers(1000);
INSERT INTO t_mvpc_src SELECT number, toString(number % 7), number / 3 FROM numbers(1000, 1000);
SELECT bucket, sum(cnt), round(sum(sum_v), 3) FROM t_mvpc_dst GROUP BY bucket ORDER BY bucket;

-- The first cached insert misses (and captures), the second hits. The cache events
-- are attributed to the view, so they are read from `query_views_log`.
SYSTEM FLUSH LOGS query_views_log;
SELECT
    sum(ProfileEvents['MVSelectPlanCacheMisses']) AS misses,
    sum(ProfileEvents['MVSelectPlanCacheHits']) AS hits
FROM system.query_views_log
WHERE view_name = currentDatabase() || '.t_mvpc_mv';

DROP VIEW t_mvpc_mv;
DROP TABLE t_mvpc_src;
DROP TABLE t_mvpc_dst;
