-- Merging `quantilePrometheusHistogramArray` states across parts must give the same result as
-- aggregating the raw histograms directly, at bucket counts spanning the state's inline hash
-- table capacity and its growth boundaries. Cumulative values are small integers, so float
-- addition is exact and the comparison can demand exact equality.

DROP TABLE IF EXISTS t_hist_state_merge_05024;

CREATE TABLE t_hist_state_merge_05024
(
    k UInt32,
    nb UInt16,
    h AggregateFunction(quantilePrometheusHistogramArray, Array(Float64), Array(Float64))
)
ENGINE = AggregatingMergeTree
ORDER BY (nb, k);

SYSTEM STOP MERGES t_hist_state_merge_05024;

-- Six separate INSERTs: each statement makes at least one part of its own, which is what gives
-- the merge several states to combine. A single INSERT would produce one part and no cross-part
-- merge at all.
INSERT INTO t_hist_state_merge_05024 SELECT k, nb, initializeAggregation('quantilePrometheusHistogramArrayState', arrayConcat(arrayMap(i -> toFloat64(i + 1), range(nb - 1)), [CAST(inf AS Float64)]), arrayCumSum(arrayMap(i -> toFloat64(1 + ((i + k + 1) % 5)), range(nb)))) FROM (SELECT toUInt32(number) AS k FROM numbers(3)) AS ks CROSS JOIN (SELECT CAST(arrayJoin([3, 8, 16, 20, 40, 94]) AS UInt16) AS nb) AS nbs;
INSERT INTO t_hist_state_merge_05024 SELECT k, nb, initializeAggregation('quantilePrometheusHistogramArrayState', arrayConcat(arrayMap(i -> toFloat64(i + 1), range(nb - 1)), [CAST(inf AS Float64)]), arrayCumSum(arrayMap(i -> toFloat64(1 + ((i + k + 2) % 5)), range(nb)))) FROM (SELECT toUInt32(number) AS k FROM numbers(3)) AS ks CROSS JOIN (SELECT CAST(arrayJoin([3, 8, 16, 20, 40, 94]) AS UInt16) AS nb) AS nbs;
INSERT INTO t_hist_state_merge_05024 SELECT k, nb, initializeAggregation('quantilePrometheusHistogramArrayState', arrayConcat(arrayMap(i -> toFloat64(i + 1), range(nb - 1)), [CAST(inf AS Float64)]), arrayCumSum(arrayMap(i -> toFloat64(1 + ((i + k + 3) % 5)), range(nb)))) FROM (SELECT toUInt32(number) AS k FROM numbers(3)) AS ks CROSS JOIN (SELECT CAST(arrayJoin([3, 8, 16, 20, 40, 94]) AS UInt16) AS nb) AS nbs;
INSERT INTO t_hist_state_merge_05024 SELECT k, nb, initializeAggregation('quantilePrometheusHistogramArrayState', arrayConcat(arrayMap(i -> toFloat64(i + 1), range(nb - 1)), [CAST(inf AS Float64)]), arrayCumSum(arrayMap(i -> toFloat64(1 + ((i + k + 4) % 5)), range(nb)))) FROM (SELECT toUInt32(number) AS k FROM numbers(3)) AS ks CROSS JOIN (SELECT CAST(arrayJoin([3, 8, 16, 20, 40, 94]) AS UInt16) AS nb) AS nbs;
INSERT INTO t_hist_state_merge_05024 SELECT k, nb, initializeAggregation('quantilePrometheusHistogramArrayState', arrayConcat(arrayMap(i -> toFloat64(i + 1), range(nb - 1)), [CAST(inf AS Float64)]), arrayCumSum(arrayMap(i -> toFloat64(1 + ((i + k + 5) % 5)), range(nb)))) FROM (SELECT toUInt32(number) AS k FROM numbers(3)) AS ks CROSS JOIN (SELECT CAST(arrayJoin([3, 8, 16, 20, 40, 94]) AS UInt16) AS nb) AS nbs;
INSERT INTO t_hist_state_merge_05024 SELECT k, nb, initializeAggregation('quantilePrometheusHistogramArrayState', arrayConcat(arrayMap(i -> toFloat64(i + 1), range(nb - 1)), [CAST(inf AS Float64)]), arrayCumSum(arrayMap(i -> toFloat64(1 + ((i + k + 6) % 5)), range(nb)))) FROM (SELECT toUInt32(number) AS k FROM numbers(3)) AS ks CROSS JOIN (SELECT CAST(arrayJoin([3, 8, 16, 20, 40, 94]) AS UInt16) AS nb) AS nbs;

-- More than one part must exist for the merge to combine anything; the exact count depends on
-- randomized insert settings.
SELECT countIf(active) > 1 FROM system.parts WHERE database = currentDatabase() AND table = 't_hist_state_merge_05024';

SYSTEM START MERGES t_hist_state_merge_05024;
OPTIMIZE TABLE t_hist_state_merge_05024 FINAL;

SELECT countIf(active) FROM system.parts WHERE database = currentDatabase() AND table = 't_hist_state_merge_05024';

-- The result read back through the merged states equals the direct aggregation of the same
-- generated inputs, exactly.
WITH
    merged AS
    (
        SELECT
            nb,
            k,
            quantilesPrometheusHistogramArrayMerge(0.5, 0.9, 0.99)(h) AS q
        FROM t_hist_state_merge_05024
        GROUP BY nb, k
    ),
    direct AS
    (
        SELECT
            nb,
            k,
            quantilesPrometheusHistogramArray(0.5, 0.9, 0.99)(
                arrayConcat(arrayMap(i -> toFloat64(i + 1), range(nb - 1)), [CAST(inf AS Float64)]),
                arrayCumSum(arrayMap(i -> toFloat64(1 + ((i + k + p) % 5)), range(nb)))) AS q
        FROM (SELECT toUInt32(number) AS k FROM numbers(3)) AS ks
        CROSS JOIN (SELECT CAST(arrayJoin([3, 8, 16, 20, 40, 94]) AS UInt16) AS nb) AS nbs
        CROSS JOIN (SELECT toUInt32(arrayJoin([1, 2, 3, 4, 5, 6])) AS p) AS ps
        GROUP BY nb, k
    )
SELECT
    m.nb,
    m.k,
    m.q = d.q AS identical,
    arrayMap(x -> round(x, 6), m.q) AS quantiles
FROM merged AS m
INNER JOIN direct AS d ON m.nb = d.nb AND m.k = d.k
ORDER BY m.nb, m.k;

DROP TABLE t_hist_state_merge_05024;

-- Edge shapes: empty states (no bucket ever added), per-part DISJOINT bucket bounds (the merged
-- key set is the union, exercising growth after an undersized reserve), and the Float32 bound
-- type instantiation.
DROP TABLE IF EXISTS t_hist_edge_05024;

CREATE TABLE t_hist_edge_05024
(
    k UInt32,
    h AggregateFunction(quantilePrometheusHistogramArray, Array(Float64), Array(Float64)),
    h32 AggregateFunction(quantilePrometheusHistogramArray, Array(Float32), Array(Float32))
)
ENGINE = AggregatingMergeTree
ORDER BY k;

SYSTEM STOP MERGES t_hist_edge_05024;

-- k = 1: empty states in every part. k = 2: each part contributes ten buckets of its own
-- (part p covers bounds 10p+1 .. 10p+10), so the merged state unions 60 distinct buckets.
-- k = 3: empty and non-empty states meet in one group, in both merge directions.
INSERT INTO t_hist_edge_05024 SELECT 1, initializeAggregation('quantilePrometheusHistogramArrayState', CAST([] AS Array(Float64)), CAST([] AS Array(Float64))), initializeAggregation('quantilePrometheusHistogramArrayState', CAST([] AS Array(Float32)), CAST([] AS Array(Float32)));
INSERT INTO t_hist_edge_05024 SELECT 1, initializeAggregation('quantilePrometheusHistogramArrayState', CAST([] AS Array(Float64)), CAST([] AS Array(Float64))), initializeAggregation('quantilePrometheusHistogramArrayState', CAST([] AS Array(Float32)), CAST([] AS Array(Float32)));
INSERT INTO t_hist_edge_05024 SELECT 1, initializeAggregation('quantilePrometheusHistogramArrayState', CAST([] AS Array(Float64)), CAST([] AS Array(Float64))), initializeAggregation('quantilePrometheusHistogramArrayState', CAST([] AS Array(Float32)), CAST([] AS Array(Float32)));
INSERT INTO t_hist_edge_05024 SELECT 2, initializeAggregation('quantilePrometheusHistogramArrayState', arrayMap(i -> toFloat64(10 + i + 1), range(10)), arrayCumSum(arrayMap(i -> toFloat64(1 + i % 3), range(10)))), initializeAggregation('quantilePrometheusHistogramArrayState', arrayMap(i -> toFloat32(10 + i + 1), range(10)), CAST(arrayCumSum(arrayMap(i -> toFloat32(1 + i % 3), range(10))) AS Array(Float32)));
INSERT INTO t_hist_edge_05024 SELECT 2, initializeAggregation('quantilePrometheusHistogramArrayState', arrayMap(i -> toFloat64(20 + i + 1), range(10)), arrayCumSum(arrayMap(i -> toFloat64(1 + i % 3), range(10)))), initializeAggregation('quantilePrometheusHistogramArrayState', arrayMap(i -> toFloat32(20 + i + 1), range(10)), CAST(arrayCumSum(arrayMap(i -> toFloat32(1 + i % 3), range(10))) AS Array(Float32)));
INSERT INTO t_hist_edge_05024 SELECT 2, initializeAggregation('quantilePrometheusHistogramArrayState', arrayMap(i -> toFloat64(30 + i + 1), range(10)), arrayCumSum(arrayMap(i -> toFloat64(1 + i % 3), range(10)))), initializeAggregation('quantilePrometheusHistogramArrayState', arrayMap(i -> toFloat32(30 + i + 1), range(10)), CAST(arrayCumSum(arrayMap(i -> toFloat32(1 + i % 3), range(10))) AS Array(Float32)));
INSERT INTO t_hist_edge_05024 SELECT 2, initializeAggregation('quantilePrometheusHistogramArrayState', arrayMap(i -> toFloat64(40 + i + 1), range(10)), arrayCumSum(arrayMap(i -> toFloat64(1 + i % 3), range(10)))), initializeAggregation('quantilePrometheusHistogramArrayState', arrayMap(i -> toFloat32(40 + i + 1), range(10)), CAST(arrayCumSum(arrayMap(i -> toFloat32(1 + i % 3), range(10))) AS Array(Float32)));
INSERT INTO t_hist_edge_05024 SELECT 2, initializeAggregation('quantilePrometheusHistogramArrayState', arrayMap(i -> toFloat64(50 + i + 1), range(10)), arrayCumSum(arrayMap(i -> toFloat64(1 + i % 3), range(10)))), initializeAggregation('quantilePrometheusHistogramArrayState', arrayMap(i -> toFloat32(50 + i + 1), range(10)), CAST(arrayCumSum(arrayMap(i -> toFloat32(1 + i % 3), range(10))) AS Array(Float32)));
INSERT INTO t_hist_edge_05024 SELECT 2, initializeAggregation('quantilePrometheusHistogramArrayState', arrayMap(i -> toFloat64(60 + i + 1), range(10)), arrayCumSum(arrayMap(i -> toFloat64(1 + i % 3), range(10)))), initializeAggregation('quantilePrometheusHistogramArrayState', arrayMap(i -> toFloat32(60 + i + 1), range(10)), CAST(arrayCumSum(arrayMap(i -> toFloat32(1 + i % 3), range(10))) AS Array(Float32)));

INSERT INTO t_hist_edge_05024 SELECT 3, initializeAggregation('quantilePrometheusHistogramArrayState', CAST([] AS Array(Float64)), CAST([] AS Array(Float64))), initializeAggregation('quantilePrometheusHistogramArrayState', CAST([] AS Array(Float32)), CAST([] AS Array(Float32)));
INSERT INTO t_hist_edge_05024 SELECT 3, initializeAggregation('quantilePrometheusHistogramArrayState', arrayConcat(arrayMap(i -> toFloat64(i + 1), range(11)), [CAST(inf AS Float64)]), arrayCumSum(arrayMap(i -> toFloat64(1 + i % 4), range(12)))), initializeAggregation('quantilePrometheusHistogramArrayState', arrayConcat(arrayMap(i -> toFloat32(i + 1), range(11)), [CAST(inf AS Float32)]), CAST(arrayCumSum(arrayMap(i -> toFloat32(1 + i % 4), range(12))) AS Array(Float32)));
INSERT INTO t_hist_edge_05024 SELECT 3, initializeAggregation('quantilePrometheusHistogramArrayState', CAST([] AS Array(Float64)), CAST([] AS Array(Float64))), initializeAggregation('quantilePrometheusHistogramArrayState', CAST([] AS Array(Float32)), CAST([] AS Array(Float32)));
INSERT INTO t_hist_edge_05024 SELECT 3, initializeAggregation('quantilePrometheusHistogramArrayState', arrayConcat(arrayMap(i -> toFloat64(i + 1), range(11)), [CAST(inf AS Float64)]), arrayCumSum(arrayMap(i -> toFloat64(2 + i % 3), range(12)))), initializeAggregation('quantilePrometheusHistogramArrayState', arrayConcat(arrayMap(i -> toFloat32(i + 1), range(11)), [CAST(inf AS Float32)]), CAST(arrayCumSum(arrayMap(i -> toFloat32(2 + i % 3), range(12))) AS Array(Float32)));

SYSTEM START MERGES t_hist_edge_05024;
OPTIMIZE TABLE t_hist_edge_05024 FINAL;

SELECT countIf(active) FROM system.parts WHERE database = currentDatabase() AND table = 't_hist_edge_05024';

SELECT
    k,
    round(quantilePrometheusHistogramArrayMerge(0.5)(h), 6) AS q50,
    round(quantilePrometheusHistogramArrayMerge(0.5)(h32), 6) AS q50_f32,
    length(CAST(finalizeAggregation(anyLast(h)) AS String)) > 0 AS has_state
FROM t_hist_edge_05024
GROUP BY k
ORDER BY k;

DROP TABLE t_hist_edge_05024;
