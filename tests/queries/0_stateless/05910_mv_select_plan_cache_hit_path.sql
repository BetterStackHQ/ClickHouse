-- Cache hits must keep planning correctly now that an entry no longer keeps the state of the
-- query that captured it. The analyzer branch of the capture stores the optimization settings
-- it planned with, three fields of which are per-query state: the automatic parallel replicas
-- plan builder, which closes over the capturing query and the block it was pushing, the
-- prepared sets cache, and the initial query id. None is read when a cached plan is turned into
-- a pipeline, so the entry drops all three. The retention itself is not observable from SQL;
-- what this test pins is that dropping them changes nothing -- repeated inserts through a
-- fan-out and a cascade of views keep hitting the cache and keep producing the same results, in
-- both analyzer modes.

DROP TABLE IF EXISTS t_mvpch_src;
DROP TABLE IF EXISTS t_mvpch_mid;
DROP TABLE IF EXISTS t_mvpch_dst;
DROP TABLE IF EXISTS t_mvpch_dst_plain;
DROP VIEW IF EXISTS t_mvpch_mv;
DROP VIEW IF EXISTS t_mvpch_mv_plain;
DROP VIEW IF EXISTS t_mvpch_mv_chain;

CREATE TABLE t_mvpch_src (k UInt64, v UInt64) ENGINE = MergeTree ORDER BY k;
CREATE TABLE t_mvpch_mid (bucket UInt64, s UInt64) ENGINE = MergeTree ORDER BY bucket;
CREATE TABLE t_mvpch_dst (bucket UInt64, s UInt64) ENGINE = MergeTree ORDER BY bucket;
CREATE TABLE t_mvpch_dst_plain (k UInt64, doubled UInt64) ENGINE = MergeTree ORDER BY k;

-- Two views over one source, one aggregating and one a plain projection.
CREATE MATERIALIZED VIEW t_mvpch_mv TO t_mvpch_mid AS
    SELECT k % 4 AS bucket, sum(v) AS s FROM t_mvpch_src GROUP BY bucket;
CREATE MATERIALIZED VIEW t_mvpch_mv_plain TO t_mvpch_dst_plain AS
    SELECT k, v * 2 AS doubled FROM t_mvpch_src;
-- And a view on the target of the first one, so a single insert drives a cascade.
CREATE MATERIALIZED VIEW t_mvpch_mv_chain TO t_mvpch_dst AS
    SELECT bucket, sum(s) AS s FROM t_mvpch_mid GROUP BY bucket;

SET use_materialized_view_select_plan_cache = 1;

SET allow_experimental_analyzer = 1;
INSERT INTO t_mvpch_src SELECT number, number FROM numbers(100);
INSERT INTO t_mvpch_src SELECT number, number FROM numbers(100);
INSERT INTO t_mvpch_src SELECT number, number FROM numbers(100);

SET allow_experimental_analyzer = 0;
INSERT INTO t_mvpch_src SELECT number, number FROM numbers(100);
INSERT INTO t_mvpch_src SELECT number, number FROM numbers(100);
INSERT INTO t_mvpch_src SELECT number, number FROM numbers(100);

SELECT bucket, sum(s) FROM t_mvpch_mid GROUP BY bucket ORDER BY bucket;
SELECT bucket, sum(s) FROM t_mvpch_dst GROUP BY bucket ORDER BY bucket;
SELECT count(), sum(doubled) FROM t_mvpch_dst_plain;

SYSTEM FLUSH LOGS query_views_log;
SELECT sum(ProfileEvents['MaterializedViewSelectPlanCacheHits']) >= 1 AS hits
FROM system.query_views_log
WHERE view_name = currentDatabase() || '.t_mvpch_mv';
SELECT sum(ProfileEvents['MaterializedViewSelectPlanCacheHits']) >= 1 AS hits
FROM system.query_views_log
WHERE view_name = currentDatabase() || '.t_mvpch_mv_plain';
SELECT sum(ProfileEvents['MaterializedViewSelectPlanCacheHits']) >= 1 AS hits
FROM system.query_views_log
WHERE view_name = currentDatabase() || '.t_mvpch_mv_chain';

-- The same inserts with the cache disabled must produce the identical result.
TRUNCATE TABLE t_mvpch_mid;
TRUNCATE TABLE t_mvpch_dst;
TRUNCATE TABLE t_mvpch_dst_plain;

SET use_materialized_view_select_plan_cache = 0;
SET allow_experimental_analyzer = 1;
INSERT INTO t_mvpch_src SELECT number, number FROM numbers(100);
INSERT INTO t_mvpch_src SELECT number, number FROM numbers(100);
INSERT INTO t_mvpch_src SELECT number, number FROM numbers(100);
SET allow_experimental_analyzer = 0;
INSERT INTO t_mvpch_src SELECT number, number FROM numbers(100);
INSERT INTO t_mvpch_src SELECT number, number FROM numbers(100);
INSERT INTO t_mvpch_src SELECT number, number FROM numbers(100);

SELECT bucket, sum(s) FROM t_mvpch_mid GROUP BY bucket ORDER BY bucket;
SELECT bucket, sum(s) FROM t_mvpch_dst GROUP BY bucket ORDER BY bucket;
SELECT count(), sum(doubled) FROM t_mvpch_dst_plain;

DROP VIEW t_mvpch_mv;
DROP VIEW t_mvpch_mv_plain;
DROP VIEW t_mvpch_mv_chain;
DROP TABLE t_mvpch_src;
DROP TABLE t_mvpch_mid;
DROP TABLE t_mvpch_dst;
DROP TABLE t_mvpch_dst_plain;
