-- Shapes that fuse_json_functions leaves alone: the results are those of the standalone calls, and the
-- profile events show that no call was fused.
SET log_queries = 1;
SET fuse_json_functions = 1;

DROP TABLE IF EXISTS json_shapes;
CREATE TABLE json_shapes (id UInt32, raw String, raw2 String, n_raw Nullable(String), lc_raw LowCardinality(String), j JSON, key String) ENGINE = MergeTree ORDER BY id;
INSERT INTO json_shapes VALUES
(1, '{"a": "x", "n": 1}', '{"a": "y", "n": 2}', '{"a": "nx", "n": 3}', '{"a": "lcx", "n": 4}', '{"a": "jx", "n": 5}', 'a'),
(2, '{"a": "p", "n": 10}', '{"a": "q", "n": 20}', NULL, '{"a": "lcp", "n": 40}', '{"a": "jp", "n": 50}', 'n'),
(3, 'not json', '', NULL, '', '{}', 'a');

SELECT /* tag:nullable_input */ id, JSONExtractString(n_raw, 'a'), JSONExtractInt(n_raw, 'n') FROM json_shapes ORDER BY id;
SELECT /* tag:low_cardinality_input */ id, JSONExtractString(lc_raw, 'a'), JSONExtractInt(lc_raw, 'n') FROM json_shapes ORDER BY id;
SELECT /* tag:json_type_input */ id, JSONExtractString(j, 'a'), JSONExtractInt(j, 'n') FROM json_shapes ORDER BY id;
SELECT /* tag:constant_document */ id, JSONExtractString('{"a": "c", "n": 7}', 'a'), JSONExtractInt('{"a": "c", "n": 7}', 'n') FROM json_shapes ORDER BY id;
SELECT /* tag:non_constant_key */ id, JSONExtractString(raw, key), JSONExtractInt(raw, key) FROM json_shapes ORDER BY id;
SELECT /* tag:nullable_key */ id, JSONExtractString(raw, toNullable('a')), JSONExtractInt(raw, toNullable('n')) FROM json_shapes ORDER BY id;
SELECT /* tag:low_cardinality_result */ id, JSONExtract(raw, 'a', 'LowCardinality(String)'), JSONExtract(raw, 'n', 'LowCardinality(Int64)') FROM json_shapes ORDER BY id;
SELECT /* tag:single_call */ id, JSONExtractString(raw, 'a') FROM json_shapes ORDER BY id;
SELECT /* tag:two_columns */ id, JSONExtractString(raw, 'a'), JSONExtractString(raw2, 'a') FROM json_shapes ORDER BY id;
SELECT /* tag:simple_json */ id, simpleJSONExtractString(raw, 'a'), simpleJSONExtractInt(raw, 'n') FROM json_shapes ORDER BY id;
SELECT /* tag:sql_json_path */ id, JSON_VALUE(raw, '$.a'), JSON_VALUE(raw, '$.n') FROM json_shapes ORDER BY id;

-- The fusable calls of a group are fused around the ones that are not.
SELECT /* tag:mixed */ id, JSONExtractString(raw, 'a'), JSONExtractString(raw, key), JSONExtractInt(raw, 'n'), JSONExtractString(raw2, 'a') FROM json_shapes ORDER BY id;

SYSTEM FLUSH LOGS query_log;
SELECT extract(query, 'tag:[a-z_]+') AS tag, ProfileEvents['JSONFunctionsFused'] AS fused
FROM system.query_log
WHERE current_database = currentDatabase() AND type = 'QueryFinish' AND query LIKE '%tag:%' AND query NOT LIKE '%system.query_log%'
ORDER BY event_time_microseconds;

DROP TABLE json_shapes;
