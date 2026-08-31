-- A hash join copies each matched right-hand row into its output one row at a time, through
-- `ColumnLowCardinality::insertFrom`. The build side keeps the blocks it was fed, each with its own
-- dictionary, so the output column translates from as many source dictionaries as there are blocks -
-- here more than the translation memo holds entries for, and interleaved, so consecutive rows ask
-- for different entries.

DROP TABLE IF EXISTS t_lc_join_left;
DROP TABLE IF EXISTS t_lc_join_right;

CREATE TABLE t_lc_join_left (k UInt32) ENGINE = MergeTree ORDER BY k;

CREATE TABLE t_lc_join_right
(
    k UInt32,
    name LowCardinality(Nullable(String)),
    tag LowCardinality(String)
)
ENGINE = MergeTree
ORDER BY k;

INSERT INTO t_lc_join_left SELECT number FROM numbers(240);

SYSTEM STOP MERGES t_lc_join_right;

-- Small insert blocks make one part each, and 37 is coprime with 240, so a part holds keys scattered
-- over the whole range rather than a contiguous run of them: the left side probes k in order and
-- walks the parts, and their dictionaries, in a different order on every row. NULL and the empty
-- string are both present, so a translation that confuses the two shows up here.
INSERT INTO t_lc_join_right
SELECT
    (number * 37) % 240 AS k,
    multiIf(number % 11 = 0, NULL, number % 7 = 0, '', concat('n', toString(number % 13))) AS name,
    concat('t', toString(number % 5)) AS tag
FROM numbers(240)
SETTINGS max_block_size = 10, min_insert_block_size_rows = 0, min_insert_block_size_bytes = 0;

SELECT 'right parts', count() >= 20 FROM system.parts WHERE database = currentDatabase() AND table = 't_lc_join_right' AND active;

-- Every key matches exactly once, so the join reproduces the right-hand side in full.
SELECT 'joined rows', count() FROM t_lc_join_left AS l INNER JOIN t_lc_join_right AS r ON l.k = r.k
SETTINGS join_algorithm = 'hash';

-- The joined content against the same rows computed without a join, both ways round.
SELECT 'join diff',
(
    SELECT count() FROM
    (
        SELECT toUInt32(l.k) AS k, CAST(ifNull(r.name, '\\N'), 'String') AS name, CAST(r.tag, 'String') AS tag
        FROM t_lc_join_left AS l INNER JOIN t_lc_join_right AS r ON l.k = r.k
        EXCEPT
        SELECT toUInt32((number * 37) % 240) AS k, CAST(ifNull(multiIf(number % 11 = 0, NULL, number % 7 = 0, '', concat('n', toString(number % 13))), '\\N'), 'String') AS name, CAST(concat('t', toString(number % 5)), 'String') AS tag
        FROM numbers(240)
    )
),
(
    SELECT count() FROM
    (
        SELECT toUInt32((number * 37) % 240) AS k, CAST(ifNull(multiIf(number % 11 = 0, NULL, number % 7 = 0, '', concat('n', toString(number % 13))), '\\N'), 'String') AS name, CAST(concat('t', toString(number % 5)), 'String') AS tag
        FROM numbers(240)
        EXCEPT
        SELECT toUInt32(l.k) AS k, CAST(ifNull(r.name, '\\N'), 'String') AS name, CAST(r.tag, 'String') AS tag
        FROM t_lc_join_left AS l INNER JOIN t_lc_join_right AS r ON l.k = r.k
    )
)
SETTINGS join_algorithm = 'hash';

SELECT 'null vs empty', count(), countIf(r.name IS NULL), countIf((r.name IS NOT NULL) AND (assumeNotNull(r.name) = '')), countIf((r.name IS NOT NULL) AND (assumeNotNull(r.name) != ''))
FROM t_lc_join_left AS l INNER JOIN t_lc_join_right AS r ON l.k = r.k
SETTINGS join_algorithm = 'hash';

-- `[]` is the empty string, `NULL` is the absent value.
SELECT 'head', l.k AS k, if(r.name IS NULL, 'NULL', concat('[', assumeNotNull(r.name), ']')) AS name_repr, r.tag AS tag
FROM t_lc_join_left AS l INNER JOIN t_lc_join_right AS r ON l.k = r.k
ORDER BY k
LIMIT 4
SETTINGS join_algorithm = 'hash';

DROP TABLE t_lc_join_left;
DROP TABLE t_lc_join_right;
