-- A source dictionary too large to memoize: the memo costs eight bytes per source position against a
-- fixed byte budget, so a dictionary of tens of thousands of values is declined and the merge
-- translates it the way it always has. Merge one such part with a small one, whose dictionary the
-- memo does take, and check that the merged content is right either way.

DROP TABLE IF EXISTS t_lc_scalar_large;

CREATE TABLE t_lc_scalar_large
(
    k UInt64,
    s LowCardinality(Nullable(String)),
    total AggregateFunction(sum, UInt64)
)
ENGINE = AggregatingMergeTree
ORDER BY (k, s)
SETTINGS allow_nullable_key = 1;

SYSTEM STOP MERGES t_lc_scalar_large;

INSERT INTO t_lc_scalar_large
SELECT number, concat('v', toString(number)), initializeAggregation('sumState', toUInt64(1))
FROM numbers(40000)
SETTINGS low_cardinality_max_dictionary_size = 1000000, max_block_size = 100000, min_insert_block_size_rows = 0, min_insert_block_size_bytes = 0;

-- A second part sharing every fourth-thousandth key, so the merge interleaves the two sources rather
-- than reading one after the other. Every third of its rows is NULL, which is a group of its own.
INSERT INTO t_lc_scalar_large
SELECT number * 4000, if(number % 3 = 0, NULL, concat('v', toString(number * 4000))), initializeAggregation('sumState', toUInt64(10))
FROM numbers(10);

SELECT 'parts before', count() FROM system.parts WHERE database = currentDatabase() AND table = 't_lc_scalar_large' AND active;

SYSTEM START MERGES t_lc_scalar_large;
OPTIMIZE TABLE t_lc_scalar_large FINAL SETTINGS low_cardinality_max_dictionary_size = 1000000;

SELECT 'parts after', count() FROM system.parts WHERE database = currentDatabase() AND table = 't_lc_scalar_large' AND active;

SELECT 'rows', count(), sum(finalizeAggregation(total)), countIf(s IS NULL), countIf(finalizeAggregation(total) = 11) FROM t_lc_scalar_large;

SELECT 'overlap', k, if(s IS NULL, 'NULL', assumeNotNull(s)) AS s_repr, finalizeAggregation(total) FROM t_lc_scalar_large WHERE (k % 4000 = 0) AND (k <= 36000) ORDER BY ALL;

SELECT 'content', count(), countIf(assumeNotNull(s) = concat('v', toString(k))) FROM t_lc_scalar_large WHERE s IS NOT NULL;

DROP TABLE t_lc_scalar_large;
