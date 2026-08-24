-- Merging `quantileTDigest` states across parts, covering both single-centroid states (the
-- per-row `initializeAggregation` shape) and multi-centroid states. The digest is approximate
-- and its compression depends on how the states were grouped along the way, so the checks are
-- range predicates on the quantiles rather than exact values.

DROP TABLE IF EXISTS t_tdigest_state_merge_05025;

CREATE TABLE t_tdigest_state_merge_05025
(
    k UInt32,
    d AggregateFunction(quantileTDigest, Float32)
)
ENGINE = AggregatingMergeTree
ORDER BY k;

SYSTEM STOP MERGES t_tdigest_state_merge_05025;

-- Six parts of single-centroid states per key (keys 0..2).
INSERT INTO t_tdigest_state_merge_05025 SELECT toUInt32(number) AS k, initializeAggregation('quantileTDigestState', toFloat32(10 * number + 1)) FROM numbers(3);
INSERT INTO t_tdigest_state_merge_05025 SELECT toUInt32(number) AS k, initializeAggregation('quantileTDigestState', toFloat32(10 * number + 2)) FROM numbers(3);
INSERT INTO t_tdigest_state_merge_05025 SELECT toUInt32(number) AS k, initializeAggregation('quantileTDigestState', toFloat32(10 * number + 3)) FROM numbers(3);
INSERT INTO t_tdigest_state_merge_05025 SELECT toUInt32(number) AS k, initializeAggregation('quantileTDigestState', toFloat32(10 * number + 4)) FROM numbers(3);
INSERT INTO t_tdigest_state_merge_05025 SELECT toUInt32(number) AS k, initializeAggregation('quantileTDigestState', toFloat32(10 * number + 5)) FROM numbers(3);
INSERT INTO t_tdigest_state_merge_05025 SELECT toUInt32(number) AS k, initializeAggregation('quantileTDigestState', toFloat32(10 * number + 6)) FROM numbers(3);

-- Two parts of multi-centroid states per key (keys 100..101).
INSERT INTO t_tdigest_state_merge_05025 SELECT toUInt32(100 + number % 2) AS k, quantileTDigestState(toFloat32(number)) FROM numbers(200) GROUP BY k;
INSERT INTO t_tdigest_state_merge_05025 SELECT toUInt32(100 + number % 2) AS k, quantileTDigestState(toFloat32(1000 + number)) FROM numbers(200) GROUP BY k;

-- More than one part must exist for the merge to combine anything; the exact count depends on
-- randomized insert settings.
SELECT countIf(active) > 1 FROM system.parts WHERE database = currentDatabase() AND table = 't_tdigest_state_merge_05025';

SYSTEM START MERGES t_tdigest_state_merge_05025;
OPTIMIZE TABLE t_tdigest_state_merge_05025 FINAL;

SELECT countIf(active) FROM system.parts WHERE database = currentDatabase() AND table = 't_tdigest_state_merge_05025';

-- Keys 0..2 hold the values {10k+1 .. 10k+6}; keys 100..101 hold 0..199 and 1000..1199
-- interleaved by parity.
SELECT
    k,
    quantileTDigestMerge(0.5)(d) BETWEEN 10 * k + 3 AND 10 * k + 4 AS q50_in_range,
    quantileTDigestMerge(0.9)(d) BETWEEN 10 * k + 5 AND 10 * k + 6 AS q90_in_range
FROM t_tdigest_state_merge_05025
WHERE k < 100
GROUP BY k
ORDER BY k;

SELECT
    k,
    quantileTDigestMerge(0.5)(d) BETWEEN 150 AND 1050 AS q50_in_range,
    quantileTDigestMerge(0.9)(d) BETWEEN 1100 AND 1200 AS q90_in_range
FROM t_tdigest_state_merge_05025
WHERE k >= 100
GROUP BY k
ORDER BY k;

DROP TABLE t_tdigest_state_merge_05025;
