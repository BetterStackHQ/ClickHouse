-- The short cross-dictionary range insert that a merge of a nested LowCardinality column performs
-- is reachable outside merges too: copying between tables, joining, grouping and `arrayJoin` all
-- insert an `Array`, `Map` or `Tuple` of LowCardinality one row at a time.

DROP TABLE IF EXISTS t_lc_src;
DROP TABLE IF EXISTS t_lc_dst;

CREATE TABLE t_lc_src
(
    k UInt32,
    name LowCardinality(Nullable(String)),
    tags Map(LowCardinality(String), LowCardinality(String)),
    arr Array(LowCardinality(String))
)
ENGINE = MergeTree ORDER BY k;

CREATE TABLE t_lc_dst AS t_lc_src;

INSERT INTO t_lc_src
SELECT
    number AS k,
    if(number % 11 = 0, NULL, concat('name_', toString(number % 7))) AS name,
    mapFromArrays(
        arrayMap(i -> toLowCardinality(concat('k', toString(i))), range(number % 5)),
        arrayMap(i -> toLowCardinality(concat('v', toString(cityHash64(number, i) % 13))), range(number % 5))) AS tags,
    arrayMap(i -> toLowCardinality(concat('a', toString(cityHash64(number, i) % 9))), range(number % 4)) AS arr
FROM numbers(1000)
SETTINGS max_block_size = 128, min_insert_block_size_rows = 0, min_insert_block_size_bytes = 0;

-- Every source block carries its own dictionary, so the copy translates across dictionaries.
INSERT INTO t_lc_dst SELECT * FROM t_lc_src SETTINGS max_block_size = 100;

SELECT 'copy', count(), sum(length(tags)), sum(length(arr)), uniqExact(tags), uniqExact(arr), uniqExact(name) FROM t_lc_dst;

SELECT 'copy identical', count() FROM
(
    SELECT k, name, tags, arr FROM t_lc_src
    EXCEPT
    SELECT k, name, tags, arr FROM t_lc_dst
);

SELECT 'array join', count(), uniqExact(a) FROM (SELECT arrayJoin(arr) AS a FROM t_lc_src);

-- Grouping by the nested columns themselves, so the result is not order-dependent.
SELECT 'group by', count(), uniqExact(tags), uniqExact(arr), sum(c) FROM
(
    SELECT tags, arr, count() AS c FROM t_lc_src GROUP BY tags, arr
);

SELECT 'join', count(), sum(length(tags)), uniqExact(arr) FROM
(
    SELECT l.k AS k, r.tags AS tags, r.arr AS arr
    FROM t_lc_src AS l INNER JOIN t_lc_src AS r ON l.k = r.k
    SETTINGS max_block_size = 100
);

SELECT 'limit by', count(), uniqExact(tags) FROM (SELECT name, tags FROM t_lc_src ORDER BY name, toString(tags) LIMIT 3 BY name);

DROP TABLE t_lc_src;
DROP TABLE t_lc_dst;
