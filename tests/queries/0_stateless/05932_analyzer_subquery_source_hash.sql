-- Tags: no-parallel-replicas
-- GROUP BY keys read from subquery sources: the analyzer passes that key hash-keyed
-- containers by query-tree nodes must behave the same whatever the hash of a column's
-- source. Covers function-of-key and aggregate-of-key elimination, grouping sets,
-- equal projections of different subqueries, a self-joined CTE, UNION sources,
-- Tuple-typed projections and nested subquery stacks.
SET enable_analyzer = 1;
-- The EXPLAIN outputs below assume the GROUP BY passes run; pin them against settings randomisation.
SET optimize_group_by_function_keys = 1, optimize_aggregators_of_group_by_keys = 1, optimize_injective_functions_in_group_by = 1, optimize_arithmetic_operations_in_aggregate_functions = 1;

SELECT '-- function of a subquery key is dropped from GROUP BY';
SELECT a, a + 1, count() FROM (SELECT number % 3 AS a FROM numbers(30)) GROUP BY a, a + 1 ORDER BY a;
EXPLAIN QUERY TREE dump_tree = 0, dump_ast = 1, run_passes = 1
SELECT a, a + 1, count() FROM (SELECT number % 3 AS a FROM numbers(30)) GROUP BY a, a + 1;

SELECT '-- aggregate of a subquery key is replaced by the key';
SELECT a, max(a), min(a + 1), count() FROM (SELECT number % 4 AS a FROM numbers(20)) GROUP BY a ORDER BY a;
EXPLAIN QUERY TREE dump_tree = 0, dump_ast = 1, run_passes = 1
SELECT a, max(a), min(a + 1), count() FROM (SELECT number % 4 AS a FROM numbers(20)) GROUP BY a;

SELECT '-- grouping sets, cube, rollup over subquery keys';
SELECT a, b, grouping(a), grouping(b), count() FROM (SELECT number % 2 AS a, number % 3 AS b FROM numbers(12)) GROUP BY GROUPING SETS ((a), (b), (a, b)) ORDER BY ALL;
SELECT a, b, grouping(a, b), count() FROM (SELECT number % 2 AS a, number % 2 AS b FROM numbers(8)) GROUP BY a, b WITH CUBE ORDER BY ALL;
SELECT a, b, count() FROM (SELECT number % 2 AS a, number % 3 AS b FROM numbers(6)) GROUP BY a, b WITH ROLLUP ORDER BY ALL;

SELECT '-- two different subqueries with the same projection, keys from both';
SELECT t1.a, t2.a, count() FROM (SELECT number % 2 AS a FROM numbers(10)) t1 JOIN (SELECT number % 3 AS a FROM numbers(10)) t2 ON t1.a = t2.a GROUP BY t1.a, t2.a ORDER BY ALL;
SELECT x.a, y.a, x.a + y.a FROM (SELECT 1 AS a) x, (SELECT 2 AS a) y GROUP BY x.a, y.a, x.a + y.a ORDER BY ALL;
EXPLAIN QUERY TREE dump_tree = 0, dump_ast = 1, run_passes = 1
SELECT x.a, y.a FROM (SELECT 1 AS a) x, (SELECT 2 AS a) y GROUP BY x.a, y.a;

SELECT '-- the same CTE joined to itself, keys from both sides';
WITH c AS (SELECT number % 2 AS k, number AS v FROM numbers(6)) SELECT l.k, r.k, count() FROM c l JOIN c r ON l.v = r.v GROUP BY l.k, r.k ORDER BY ALL;

SELECT '-- JOIN USING and ARRAY JOIN sources';
SELECT k, k + 1, count() FROM (SELECT number % 2 AS k, number AS v FROM numbers(6)) s1 JOIN (SELECT number % 2 AS k, number AS w FROM numbers(6)) s2 USING (k) GROUP BY k, k + 1 ORDER BY k;
SELECT x, x * 2, count() FROM (SELECT [number % 2, number % 3] AS arr FROM numbers(6)) ARRAY JOIN arr AS x GROUP BY x, x * 2 ORDER BY x;
EXPLAIN QUERY TREE dump_tree = 0, dump_ast = 1, run_passes = 1
SELECT x, x * 2, count() FROM (SELECT [number % 2, number % 3] AS arr FROM numbers(6)) ARRAY JOIN arr AS x GROUP BY x, x * 2;

SELECT '-- union sources';
SELECT a, count() FROM (SELECT number AS a FROM numbers(3) UNION ALL SELECT number + 1 AS a FROM numbers(3)) GROUP BY a ORDER BY a;
SELECT a, a * 2, count() FROM (SELECT number % 2 AS a FROM numbers(4) UNION DISTINCT SELECT number % 3 AS a FROM numbers(6)) GROUP BY a, a * 2 ORDER BY a;

SELECT '-- EXCEPT and INTERSECT sources';
SELECT a, count() FROM (SELECT number AS a FROM numbers(5) EXCEPT SELECT number AS a FROM numbers(2)) GROUP BY a ORDER BY a;
SELECT a, a + 1, count() FROM (SELECT number AS a FROM numbers(5) INTERSECT SELECT number AS a FROM numbers(2, 5)) GROUP BY a, a + 1 ORDER BY a;

SELECT '-- window function over subquery keys';
SELECT a, count() OVER (PARTITION BY a), count() FROM (SELECT number % 2 AS a FROM numbers(4)) GROUP BY a ORDER BY a;

SELECT '-- tuple-typed projection, keys are tuple elements';
SELECT k1, k2, k1 || k2, count() FROM (SELECT tupleElement(t, 'x') AS k1, tupleElement(t, 'y') AS k2, t FROM (SELECT CAST((toString(number % 2), toString(number % 3)), 'Tuple(x String, y String)') AS t FROM numbers(12))) GROUP BY k1, k2, k1 || k2 ORDER BY ALL;

SELECT '-- group_by_use_nulls with subquery keys';
SELECT a, b, count() FROM (SELECT number % 2 AS a, number % 3 AS b FROM numbers(6)) GROUP BY GROUPING SETS ((a), (b)) ORDER BY ALL SETTINGS group_by_use_nulls = 1;

SELECT '-- HAVING with a subquery over a subquery key';
SELECT k, count() FROM (SELECT number % 3 AS k FROM numbers(9)) GROUP BY k HAVING k IN (SELECT number % 2 AS k FROM numbers(2)) ORDER BY k;

SELECT '-- keys from a three-level subquery stack';
SELECT a, b, a + b, count() FROM (SELECT a, b FROM (SELECT a, number % 2 AS b FROM (SELECT number % 3 AS a, number FROM numbers(12)))) GROUP BY a, b, a + b ORDER BY ALL;
EXPLAIN QUERY TREE dump_tree = 0, dump_ast = 1, run_passes = 1
SELECT a, b, a + b, count() FROM (SELECT a, b FROM (SELECT a, number % 2 AS b FROM (SELECT number % 3 AS a, number FROM numbers(12)))) GROUP BY a, b, a + b;
