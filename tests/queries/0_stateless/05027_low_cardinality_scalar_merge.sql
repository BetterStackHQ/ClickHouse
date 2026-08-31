-- A merge assembles its output one row at a time, so every non-aggregate column is copied through
-- `ColumnLowCardinality::insertFrom`, once per output row, translating the source part's dictionary
-- into the merged one. Merge parts whose dictionaries hold overlapping values in different orders,
-- so that a source position and its translation differ, and check the merged content exactly.

DROP TABLE IF EXISTS t_lc_scalar;

CREATE TABLE t_lc_scalar
(
    k UInt32,
    name LowCardinality(Nullable(String)),
    other LowCardinality(String),
    total AggregateFunction(sum, UInt64)
)
ENGINE = AggregatingMergeTree
ORDER BY (name, other, k)
SETTINGS allow_nullable_key = 1;

SYSTEM STOP MERGES t_lc_scalar;

-- Three parts over overlapping value sets. Each part fills its own dictionary in its own order, and
-- none of those orders is the one the merged dictionary fills in, so every translation is a
-- permutation rather than the identity. NULL and the empty string are both present and adjacent in
-- the key: the dictionary's default position holds the empty string, so a translation that confuses
-- the two shows up here.
INSERT INTO t_lc_scalar VALUES (1, 'a', 'x', initializeAggregation('sumState', toUInt64(1))), (2, 'c', 'z', initializeAggregation('sumState', toUInt64(2))), (3, 'e', 'y', initializeAggregation('sumState', toUInt64(4))), (1, 'a', 'x', initializeAggregation('sumState', toUInt64(8)));
INSERT INTO t_lc_scalar VALUES (1, NULL, 'z', initializeAggregation('sumState', toUInt64(16))), (2, '', 'y', initializeAggregation('sumState', toUInt64(32))), (1, 'a', 'x', initializeAggregation('sumState', toUInt64(64))), (2, 'b', 'w', initializeAggregation('sumState', toUInt64(128)));
INSERT INTO t_lc_scalar VALUES (3, 'e', 'y', initializeAggregation('sumState', toUInt64(256))), (2, 'c', 'z', initializeAggregation('sumState', toUInt64(512))), (4, '', 'y', initializeAggregation('sumState', toUInt64(1024))), (5, 'd', 'x', initializeAggregation('sumState', toUInt64(2048)));

SELECT 'parts before', count() FROM system.parts WHERE database = currentDatabase() AND table = 't_lc_scalar' AND active;

SYSTEM START MERGES t_lc_scalar;
OPTIMIZE TABLE t_lc_scalar FINAL;

SELECT 'parts after', count() FROM system.parts WHERE database = currentDatabase() AND table = 't_lc_scalar' AND active;

-- `[]` is the empty string, `NULL` is the absent value.
SELECT 'merged', k, if(name IS NULL, 'NULL', concat('[', assumeNotNull(name), ']')) AS name_repr, other, finalizeAggregation(total) FROM t_lc_scalar ORDER BY ALL;

SELECT 'null vs empty', count(), countIf(name IS NULL), countIf((name IS NOT NULL) AND (assumeNotNull(name) = '')), countIf((name IS NOT NULL) AND (assumeNotNull(name) != '')) FROM t_lc_scalar;

DROP TABLE t_lc_scalar;

-- More source parts than the memo holds entries for. Past its bound the memo stops installing
-- entries, so the same merge translates some sources through it and the rest without it.
-- This is the >16-entries latch case, and the only coverage of it: keep the part count above the
-- memo's entry bound if this section is ever rewritten.
DROP TABLE IF EXISTS t_lc_scalar_many;

CREATE TABLE t_lc_scalar_many
(
    k UInt32,
    name LowCardinality(Nullable(String)),
    total AggregateFunction(sum, UInt64)
)
ENGINE = AggregatingMergeTree
ORDER BY (name, k)
SETTINGS allow_nullable_key = 1;

SYSTEM STOP MERGES t_lc_scalar_many;

-- Small insert blocks make one part each, and the value cycles are coprime with the block size, so
-- consecutive parts see the same values in different orders.
INSERT INTO t_lc_scalar_many
SELECT
    number % 32 AS k,
    multiIf(number % 11 = 0, NULL, number % 7 = 0, '', concat('n', toString(number % 13))) AS name,
    initializeAggregation('sumState', toUInt64(1))
FROM numbers(640)
SETTINGS max_block_size = 32, min_insert_block_size_rows = 0, min_insert_block_size_bytes = 0;

SELECT 'many parts before', count() >= 20 FROM system.parts WHERE database = currentDatabase() AND table = 't_lc_scalar_many' AND active;

SYSTEM START MERGES t_lc_scalar_many;
OPTIMIZE TABLE t_lc_scalar_many FINAL;

SELECT 'many parts after', count() FROM system.parts WHERE database = currentDatabase() AND table = 't_lc_scalar_many' AND active;

-- The merged content against the same grouping computed without a merge, both ways round.
SELECT 'many diff',
(
    SELECT count() FROM
    (
        SELECT toUInt32(k) AS k, CAST(ifNull(name, '\\N'), 'String') AS name, toUInt64(finalizeAggregation(total)) AS total FROM t_lc_scalar_many
        EXCEPT
        SELECT toUInt32(number % 32) AS k, CAST(ifNull(multiIf(number % 11 = 0, NULL, number % 7 = 0, '', concat('n', toString(number % 13))), '\\N'), 'String') AS name, toUInt64(count()) AS total FROM numbers(640) GROUP BY k, name
    )
),
(
    SELECT count() FROM
    (
        SELECT toUInt32(number % 32) AS k, CAST(ifNull(multiIf(number % 11 = 0, NULL, number % 7 = 0, '', concat('n', toString(number % 13))), '\\N'), 'String') AS name, toUInt64(count()) AS total FROM numbers(640) GROUP BY k, name
        EXCEPT
        SELECT toUInt32(k) AS k, CAST(ifNull(name, '\\N'), 'String') AS name, toUInt64(finalizeAggregation(total)) AS total FROM t_lc_scalar_many
    )
);

DROP TABLE t_lc_scalar_many;

-- A plain MergeTree merge reaches the same per-row copy through a different algorithm. The parts
-- interleave, so the whole-chunk bypass in `MergingSortedAlgorithm` cannot fire and every row is
-- copied one at a time.
DROP TABLE IF EXISTS t_lc_scalar_plain;

CREATE TABLE t_lc_scalar_plain (name LowCardinality(Nullable(String)), k UInt32)
ENGINE = MergeTree
ORDER BY (name, k)
SETTINGS allow_nullable_key = 1;

SYSTEM STOP MERGES t_lc_scalar_plain;
INSERT INTO t_lc_scalar_plain VALUES ('b', 1), ('a', 3), (NULL, 5), ('', 7);
INSERT INTO t_lc_scalar_plain VALUES ('a', 2), ('', 4), ('b', 6), (NULL, 8);
INSERT INTO t_lc_scalar_plain VALUES ('', 9), (NULL, 10), ('c', 11), ('a', 12);
SYSTEM START MERGES t_lc_scalar_plain;
OPTIMIZE TABLE t_lc_scalar_plain FINAL;

SELECT 'plain', if(name IS NULL, 'NULL', concat('[', assumeNotNull(name), ']')) AS name_repr, k FROM t_lc_scalar_plain ORDER BY ALL;

DROP TABLE t_lc_scalar_plain;
