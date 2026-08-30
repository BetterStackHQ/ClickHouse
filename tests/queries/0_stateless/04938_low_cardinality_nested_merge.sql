-- A row-at-a-time merge of a Map, Array, Tuple or Nested column of LowCardinality translates the
-- source dictionary through `ColumnLowCardinality::insertRangeFrom` with a range of a few elements,
-- once per output row per element column. Merge a matrix of row shapes around that path - empty and
-- long rows, repeated keys, NULLs on one side only, more parts than one merge usually has - and
-- check the merged result.

DROP TABLE IF EXISTS t_lc_nested;

CREATE TABLE t_lc_nested
(
    k UInt32,
    name LowCardinality(Nullable(String)),
    tags Map(LowCardinality(String), LowCardinality(String)),
    tags_nullable Map(LowCardinality(String), LowCardinality(Nullable(String))),
    arr Array(LowCardinality(String)),
    arr_nullable Array(LowCardinality(Nullable(String))),
    tup Tuple(LowCardinality(String), LowCardinality(String)),
    nest Nested(nk LowCardinality(String), nv LowCardinality(String)),
    total AggregateFunction(sum, UInt64)
)
ENGINE = AggregatingMergeTree
ORDER BY (name, tags, k)
SETTINGS allow_nullable_key = 1, allow_dimensions_outside_sorting_key = 1;

SYSTEM STOP MERGES t_lc_nested;

-- Map lengths cycle through 0, 1, 2, 3, 31, 32, 33 and 1000, so both sides of the short-range
-- threshold, its boundary and the empty range are all merged together. Small insert blocks make
-- more parts than a merge can hold source dictionaries for.
INSERT INTO t_lc_nested
SELECT
    number % 64 AS k,
    multiIf(number % 7 = 0, NULL, number % 3 = 0, concat('unique_', toString(number)), concat('few_', toString(number % 5))) AS name,
    mapFromArrays(
        arrayMap(i -> toLowCardinality(concat('k', toString(i))), range([0, 1, 2, 3, 31, 32, 33, 1000][1 + number % 8])),
        arrayMap(i -> toLowCardinality(concat('v', toString(cityHash64(number, i) % 37))), range([0, 1, 2, 3, 31, 32, 33, 1000][1 + number % 8]))) AS tags,
    mapFromArrays(
        arrayMap(i -> toLowCardinality(concat('k', toString(i))), range(number % 4)),
        arrayMap(i -> if(i % 2 = 0, NULL, toLowCardinality(concat('v', toString(i)))), range(number % 4))) AS tags_nullable,
    -- The same key repeated in one row: the distinct source positions are fewer than the range.
    arrayMap(i -> toLowCardinality(concat('same_', toString(number % 3))), range(number % 5)) AS arr,
    arrayMap(i -> if(i % 4 = 0, NULL, toLowCardinality(concat('a', toString(cityHash64(number, i) % 11)))), range(number % 5)) AS arr_nullable,
    (toLowCardinality(concat('t', toString(number % 6))), toLowCardinality(concat('u', toString(number % 9)))) AS tup,
    arrayMap(i -> toLowCardinality(concat('nk', toString(i))), range(number % 3)) AS `nest.nk`,
    arrayMap(i -> toLowCardinality(concat('nv', toString(cityHash64(number, i) % 5))), range(number % 3)) AS `nest.nv`,
    initializeAggregation('sumState', toUInt64(number))
FROM numbers(2048)
SETTINGS max_block_size = 64, min_insert_block_size_rows = 0, min_insert_block_size_bytes = 0;

SELECT 'parts before', count() >= 24 FROM system.parts WHERE database = currentDatabase() AND table = 't_lc_nested' AND active;

SYSTEM START MERGES t_lc_nested;
OPTIMIZE TABLE t_lc_nested FINAL;

SELECT 'parts after', count() FROM system.parts WHERE database = currentDatabase() AND table = 't_lc_nested' AND active;

SELECT 'rows', count(), sum(length(tags)), sum(length(arr)), sum(length(nest.nk)) FROM t_lc_nested;

SELECT 'distinct', uniqExact(name), uniqExact(tags), uniqExact(tags_nullable), uniqExact(arr), uniqExact(arr_nullable), uniqExact(tup), uniqExact(nest.nv) FROM t_lc_nested;

SELECT 'fold', cityHash64(groupArray(h)) FROM
(
    SELECT cityHash64(ifNull(name, '\\N'), toString(tags), toString(tags_nullable), toString(arr), toString(arr_nullable), toString(tup), toString(nest.nk), toString(nest.nv), k, finalizeAggregation(total)) AS h
    FROM t_lc_nested
    ORDER BY ifNull(name, '\\N'), toString(tags), k
)
SETTINGS max_threads = 1;

-- Row shapes that must survive a merge unchanged, listed explicitly.
SELECT 'map lengths', arraySort(groupUniqArray(length(tags))) FROM t_lc_nested;
SELECT 'empty maps', countIf(length(tags) = 0), countIf(length(arr) = 0), countIf(name IS NULL) FROM t_lc_nested;
SELECT 'boundary', length(tags), count(), uniqExact(tags) FROM t_lc_nested WHERE length(tags) IN (31, 32, 33) GROUP BY length(tags) ORDER BY length(tags);

-- Merging the merged result again must be a no-op.
OPTIMIZE TABLE t_lc_nested FINAL;
SELECT 'idempotent', count(), cityHash64(groupArray(h)) FROM
(
    SELECT cityHash64(ifNull(name, '\\N'), toString(tags), toString(arr), k) AS h
    FROM t_lc_nested
    ORDER BY ifNull(name, '\\N'), toString(tags), k
)
SETTINGS max_threads = 1;

DROP TABLE t_lc_nested;

-- The same path with a dictionary that overflows during the merge.
DROP TABLE IF EXISTS t_lc_nested_overflow;

CREATE TABLE t_lc_nested_overflow
(
    k UInt32,
    tags Map(LowCardinality(String), LowCardinality(String))
)
ENGINE = AggregatingMergeTree ORDER BY (tags, k);

SYSTEM STOP MERGES t_lc_nested_overflow;

INSERT INTO t_lc_nested_overflow
SELECT
    number AS k,
    mapFromArrays(
        arrayMap(i -> toLowCardinality(concat('k', toString(i))), range(3)),
        arrayMap(i -> toLowCardinality(concat('v', toString(cityHash64(number, i)))), range(3))) AS tags
FROM numbers(1024)
SETTINGS max_block_size = 32, min_insert_block_size_rows = 0, min_insert_block_size_bytes = 0, low_cardinality_max_dictionary_size = 16;

SYSTEM START MERGES t_lc_nested_overflow;
OPTIMIZE TABLE t_lc_nested_overflow FINAL SETTINGS low_cardinality_max_dictionary_size = 16;

SELECT 'overflow', count(), uniqExact(tags), sum(length(tags)) FROM t_lc_nested_overflow;

DROP TABLE t_lc_nested_overflow;

-- A float dictionary maps a value that compares equal to the default onto the default position, so
-- negative zero does not survive a merge. Pin that, because the two insert paths disagree about it.
DROP TABLE IF EXISTS t_lc_nested_float;

SET allow_suspicious_low_cardinality_types = 1;
CREATE TABLE t_lc_nested_float (k UInt32, arr Array(LowCardinality(Float64))) ENGINE = MergeTree ORDER BY k;

SYSTEM STOP MERGES t_lc_nested_float;
INSERT INTO t_lc_nested_float VALUES (1, [-0., 0., 1.5]), (2, [-0., -1.5]);
INSERT INTO t_lc_nested_float VALUES (3, [-0., 2.5]), (4, [0., -0.]);
SYSTEM START MERGES t_lc_nested_float;
OPTIMIZE TABLE t_lc_nested_float FINAL;

SELECT 'float', k, arr, arrayMap(x -> toString(1 / x), arr) FROM t_lc_nested_float ORDER BY k;

DROP TABLE t_lc_nested_float;

-- The same, with a nullable float dictionary: the type test unwraps the Nullable before looking at
-- the value type, so this half of it needs pinning too. NULLs are interleaved with the zeros so
-- that the null placeholder position takes part in the merge.
DROP TABLE IF EXISTS t_lc_nested_float_nullable;

CREATE TABLE t_lc_nested_float_nullable (k UInt32, arr Array(LowCardinality(Nullable(Float64)))) ENGINE = MergeTree ORDER BY k;

SYSTEM STOP MERGES t_lc_nested_float_nullable;
INSERT INTO t_lc_nested_float_nullable VALUES (1, [-0., 0., NULL, 1.5]), (2, [NULL, -0., -1.5]);
INSERT INTO t_lc_nested_float_nullable VALUES (3, [-0., NULL, 2.5]), (4, [0., -0., NULL]);
SYSTEM START MERGES t_lc_nested_float_nullable;
OPTIMIZE TABLE t_lc_nested_float_nullable FINAL;

SELECT 'float nullable', k, arr, arrayMap(x -> toString(1 / x), arr) FROM t_lc_nested_float_nullable ORDER BY k;

DROP TABLE t_lc_nested_float_nullable;
