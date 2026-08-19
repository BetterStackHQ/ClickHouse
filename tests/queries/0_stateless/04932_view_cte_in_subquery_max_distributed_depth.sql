-- Tags: shard

-- Filter-pushdown pre-analysis (`collectFiltersForAnalysis`) builds a dummy plan
-- for queries whose join tree contains a `View`. It must be planned to the same
-- processing stage as the real query: on a shard executing at `WithMergeableState`
-- a `Complete`-stage dummy plan would plan the IN-set subquery above the
-- aggregation boundary, which the real execution never plans, and the nested
-- distributed read inside it tripped the `max_distributed_depth` check during
-- planning of a plan that is discarded.

DROP TABLE IF EXISTS t_04932;
DROP VIEW IF EXISTS v_04932;

CREATE TABLE t_04932 (k String, m String, v Float64) ENGINE = MergeTree ORDER BY k;
CREATE VIEW v_04932 AS SELECT * FROM t_04932;
INSERT INTO t_04932 VALUES ('a', 'm1', 5), ('a', 'm2', 200);

SET max_distributed_depth = 1;

-- Shared CTE over a distributed read of a view, referenced again from a
-- non-GLOBAL IN subquery. Both shards read the same table, so sums double;
-- the ratio is scale-invariant.
WITH c1 AS
(
    SELECT k, m, sum(v) AS v
    FROM remote('127.0.0.{1,2}', currentDatabase(), v_04932)
    GROUP BY k, m
),
c2 AS
(
    SELECT k, sumIf(v, m = 'm1') / sumIf(v, m = 'm2') AS r
    FROM c1
    GROUP BY k
)
SELECT k, r
FROM c2
WHERE k IN (SELECT k FROM c2 GROUP BY k HAVING max(r) > 0.001)
ORDER BY k;

-- The identical query under a permissive depth cap must give the same result:
-- the depth setting must not affect results, only (real) dispatch limits.
SET max_distributed_depth = 5;

WITH c1 AS
(
    SELECT k, m, sum(v) AS v
    FROM remote('127.0.0.{1,2}', currentDatabase(), v_04932)
    GROUP BY k, m
),
c2 AS
(
    SELECT k, sumIf(v, m = 'm1') / sumIf(v, m = 'm2') AS r
    FROM c1
    GROUP BY k
)
SELECT k, r
FROM c2
WHERE k IN (SELECT k FROM c2 GROUP BY k HAVING max(r) > 0.001)
ORDER BY k;

DROP VIEW v_04932;
DROP TABLE t_04932;
