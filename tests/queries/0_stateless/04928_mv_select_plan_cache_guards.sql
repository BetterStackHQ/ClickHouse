-- Guards of the materialized view select plan cache: view selects with
-- analysis-time volatile constants are never cached, and both analyzer modes
-- produce correct results with the cache enabled.

DROP TABLE IF EXISTS t_mvpcg_src;
DROP TABLE IF EXISTS t_mvpcg_dst;
DROP TABLE IF EXISTS t_mvpcg_dst2;
DROP VIEW IF EXISTS t_mvpcg_mv;
DROP VIEW IF EXISTS t_mvpcg_mv2;

CREATE TABLE t_mvpcg_src (k UInt64) ENGINE = MergeTree ORDER BY k;
CREATE TABLE t_mvpcg_dst (k UInt64, u String) ENGINE = MergeTree ORDER BY k;
CREATE MATERIALIZED VIEW t_mvpcg_mv TO t_mvpcg_dst AS
    SELECT k, currentUser() AS u FROM t_mvpcg_src;

SET use_materialized_view_select_plan_cache = 1;

INSERT INTO t_mvpcg_src VALUES (1);
INSERT INTO t_mvpcg_src VALUES (2);
SELECT count() FROM t_mvpcg_dst;

SYSTEM FLUSH LOGS query_views_log;
SELECT
    sum(ProfileEvents['MaterializedViewSelectPlanCacheSkippedNonDeterministic']) AS skipped,
    sum(ProfileEvents['MaterializedViewSelectPlanCacheHits']) AS hits
FROM system.query_views_log
WHERE view_name = currentDatabase() || '.t_mvpcg_mv';

-- Both analyzer modes work with the cache and agree on results.
CREATE TABLE t_mvpcg_dst2 (bucket UInt64, s UInt64) ENGINE = SummingMergeTree ORDER BY bucket;
CREATE MATERIALIZED VIEW t_mvpcg_mv2 TO t_mvpcg_dst2 AS
    SELECT k % 3 AS bucket, sum(k) AS s FROM t_mvpcg_src GROUP BY bucket;

SET allow_experimental_analyzer = 1;
INSERT INTO t_mvpcg_src SELECT number FROM numbers(100);
INSERT INTO t_mvpcg_src SELECT number FROM numbers(100);
SET allow_experimental_analyzer = 0;
INSERT INTO t_mvpcg_src SELECT number FROM numbers(100);
INSERT INTO t_mvpcg_src SELECT number FROM numbers(100);

SELECT bucket, sum(s) FROM t_mvpcg_dst2 GROUP BY bucket ORDER BY bucket;

-- SQL user defined functions are inlined during analysis and must not block
-- caching (their bodies are scanned by the volatility guard instead).
CREATE FUNCTION IF NOT EXISTS 04928_udf_double AS x -> x * 2;
CREATE TABLE t_mvpcg_dst3 (k UInt64, d UInt64) ENGINE = MergeTree ORDER BY k;
CREATE MATERIALIZED VIEW t_mvpcg_mv3 TO t_mvpcg_dst3 AS
    SELECT k, 04928_udf_double(k) AS d FROM t_mvpcg_src;
INSERT INTO t_mvpcg_src VALUES (1000);
INSERT INTO t_mvpcg_src VALUES (2000);
SELECT k, d FROM t_mvpcg_dst3 ORDER BY k;
SYSTEM FLUSH LOGS query_views_log;
SELECT sum(ProfileEvents['MaterializedViewSelectPlanCacheHits']) >= 1 AS udf_view_cached
FROM system.query_views_log
WHERE view_name = currentDatabase() || '.t_mvpcg_mv3';

-- SQL UDF bodies are inlined into the stored view query at CREATE, so a
-- redefinition does not affect existing views; the cache preserves exactly that.
CREATE OR REPLACE FUNCTION 04928_udf_double AS x -> x * 3;
INSERT INTO t_mvpcg_src VALUES (3000);
SELECT k, d FROM t_mvpcg_dst3 WHERE k = 3000;

DROP VIEW t_mvpcg_mv3;
DROP TABLE t_mvpcg_dst3;
DROP FUNCTION IF EXISTS 04928_udf_double;

-- Reads besides the view source (here a join) are never cached, and results
-- stay live: rows added to the joined table are visible to later inserts.
CREATE TABLE t_mvpcg_dim (k UInt64, name String) ENGINE = MergeTree ORDER BY k;
INSERT INTO t_mvpcg_dim VALUES (1, 'one'), (2, 'two');
CREATE TABLE t_mvpcg_dst4 (k UInt64, name String) ENGINE = MergeTree ORDER BY k;
CREATE MATERIALIZED VIEW t_mvpcg_mv4 TO t_mvpcg_dst4 AS
    SELECT s.k AS k, d.name AS name FROM t_mvpcg_src AS s INNER JOIN t_mvpcg_dim AS d ON s.k % 3 = d.k;
INSERT INTO t_mvpcg_src VALUES (3001);
INSERT INTO t_mvpcg_dim VALUES (0, 'zero');
INSERT INTO t_mvpcg_src VALUES (3002);
INSERT INTO t_mvpcg_src VALUES (3003);
SELECT k, name FROM t_mvpcg_dst4 ORDER BY k;

-- Scalar subqueries are folded per block, so such selects are never cached and
-- later inserts observe new data.
CREATE TABLE t_mvpcg_dst5 (k UInt64, m UInt64) ENGINE = MergeTree ORDER BY k;
CREATE MATERIALIZED VIEW t_mvpcg_mv5 TO t_mvpcg_dst5 AS
    SELECT k, (SELECT max(k) FROM t_mvpcg_dim) AS m FROM t_mvpcg_src;
INSERT INTO t_mvpcg_src VALUES (4001);
INSERT INTO t_mvpcg_dim VALUES (10, 'ten');
INSERT INTO t_mvpcg_src VALUES (4002);
SELECT k, m FROM t_mvpcg_dst5 ORDER BY k;

SYSTEM FLUSH LOGS query_views_log;
SELECT sum(ProfileEvents['MaterializedViewSelectPlanCacheHits']) = 0 AS join_view_never_cached
FROM system.query_views_log
WHERE view_name = currentDatabase() || '.t_mvpcg_mv4';
SELECT sum(ProfileEvents['MaterializedViewSelectPlanCacheSkippedNonDeterministic']) >= 1 AS subquery_view_skipped
FROM system.query_views_log
WHERE view_name = currentDatabase() || '.t_mvpcg_mv5';

DROP VIEW t_mvpcg_mv4;
DROP VIEW t_mvpcg_mv5;
DROP TABLE t_mvpcg_dim;
DROP TABLE t_mvpcg_dst4;
DROP TABLE t_mvpcg_dst5;

DROP VIEW t_mvpcg_mv;
DROP VIEW t_mvpcg_mv2;
DROP TABLE t_mvpcg_src;
DROP TABLE t_mvpcg_dst;
DROP TABLE t_mvpcg_dst2;
