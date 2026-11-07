-- fuse_json_functions in the SELECT of a materialized view, with either analyzer stored in the view.
SET log_queries = 1;
SET fuse_json_functions = 1;

DROP TABLE IF EXISTS json_src;
DROP TABLE IF EXISTS json_target_new;
DROP TABLE IF EXISTS json_target_old;
DROP TABLE IF EXISTS json_target_plain;
DROP VIEW IF EXISTS json_mv_new;
DROP VIEW IF EXISTS json_mv_old;

CREATE TABLE json_src (id UInt32, raw String) ENGINE = MergeTree ORDER BY id;
CREATE TABLE json_target_new (id UInt32, a String, n Int64, x Int32, y String, b Array(Int64), has_a UInt8, t Tuple(x Int32, y String), raw_o String, keys Array(String), ci String, cn Int64) ENGINE = MergeTree ORDER BY id;
CREATE TABLE json_target_old AS json_target_new;
CREATE TABLE json_target_plain AS json_target_new;

CREATE MATERIALIZED VIEW json_mv_new TO json_target_new AS
SELECT id, JSONExtractString(raw, 'a') AS a, JSONExtractInt(raw, 'n') AS n, JSONExtractInt(raw, 'o', 'x') AS x, JSONExtractString(raw, 'o', 'y') AS y,
    JSONExtract(raw, 'b', 'Array(Int64)') AS b, JSONHas(raw, 'a') AS has_a, JSONExtract(raw, 'o', 'Tuple(x Int32, y String)') AS t, JSONExtractRaw(raw, 'o') AS raw_o,
    JSONExtractKeys(raw) AS keys, JSONExtractStringCaseInsensitive(raw, 'A') AS ci, JSONExtractIntCaseInsensitive(raw, 'N') AS cn
FROM json_src SETTINGS allow_experimental_analyzer = 1;

CREATE MATERIALIZED VIEW json_mv_old TO json_target_old AS
SELECT id, JSONExtractString(raw, 'a') AS a, JSONExtractInt(raw, 'n') AS n, JSONExtractInt(raw, 'o', 'x') AS x, JSONExtractString(raw, 'o', 'y') AS y,
    JSONExtract(raw, 'b', 'Array(Int64)') AS b, JSONHas(raw, 'a') AS has_a, JSONExtract(raw, 'o', 'Tuple(x Int32, y String)') AS t, JSONExtractRaw(raw, 'o') AS raw_o,
    JSONExtractKeys(raw) AS keys, JSONExtractStringCaseInsensitive(raw, 'A') AS ci, JSONExtractIntCaseInsensitive(raw, 'N') AS cn
FROM json_src SETTINGS allow_experimental_analyzer = 0;

INSERT INTO /* tag:insert_fused */ json_src SELECT number, concat('{"a": "a', toString(number % 10), '", "n": ', toString(number), ', "o": {"x": ', toString(number % 3), ', "y": "y', toString(number % 4), '"}, "b": [', toString(number), ', ', toString(number + 1), ']}') FROM numbers(10000);
-- The profile events of a `VALUES` insert are not attributed to its query log entry, so only the first insert is tagged.
INSERT INTO json_src VALUES (10000, 'not json'), (10001, '{"A": "upper", "N": 5}'), (10002, '{}');

INSERT INTO json_target_plain SELECT id, JSONExtractString(raw, 'a') AS a, JSONExtractInt(raw, 'n') AS n, JSONExtractInt(raw, 'o', 'x') AS x, JSONExtractString(raw, 'o', 'y') AS y,
    JSONExtract(raw, 'b', 'Array(Int64)') AS b, JSONHas(raw, 'a') AS has_a, JSONExtract(raw, 'o', 'Tuple(x Int32, y String)') AS t, JSONExtractRaw(raw, 'o') AS raw_o,
    JSONExtractKeys(raw) AS keys, JSONExtractStringCaseInsensitive(raw, 'A') AS ci, JSONExtractIntCaseInsensitive(raw, 'N') AS cn
FROM json_src SETTINGS fuse_json_functions = 0;

SELECT 'rows', (SELECT count() FROM json_target_new), (SELECT count() FROM json_target_old), (SELECT count() FROM json_target_plain);
SELECT 'new minus plain', count() FROM (SELECT * FROM json_target_new EXCEPT SELECT * FROM json_target_plain);
SELECT 'old minus plain', count() FROM (SELECT * FROM json_target_old EXCEPT SELECT * FROM json_target_plain);
SELECT 'plain minus new', count() FROM (SELECT * FROM json_target_plain EXCEPT SELECT * FROM json_target_new);
SELECT * FROM json_target_new WHERE id >= 9998 ORDER BY id;

SYSTEM FLUSH LOGS query_log;
SELECT extract(query, 'tag:[a-z_]+') AS tag, ProfileEvents['JSONFunctionsFused'] > 0 AS fused
FROM system.query_log
WHERE current_database = currentDatabase() AND type = 'QueryFinish' AND query LIKE '%tag:%' AND query NOT LIKE '%system.query_log%'
ORDER BY event_time_microseconds;

DROP VIEW json_mv_old;
DROP VIEW json_mv_new;
DROP TABLE json_target_plain;
DROP TABLE json_target_old;
DROP TABLE json_target_new;
DROP TABLE json_src;
