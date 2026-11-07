-- Every JSON* family over one String column, with fuse_json_functions on and off: the results must be
-- identical, and the profile events must show that the calls were fused when the setting is on.
SET log_queries = 1;

DROP TABLE IF EXISTS json_docs;
CREATE TABLE json_docs (id UInt32, raw String) ENGINE = MergeTree ORDER BY id;

INSERT INTO json_docs VALUES
(1, '{"a": "hello", "A": "HELLO", "b": [-100, 200.0, 300], "n": 1, "f": 1.5, "t": true, "o": {"x": 1, "y": "z", "arr": [1, 2, 3]}, "big": 18446744073709551615, "neg": -9223372036854775808, "dup": 1, "dup": 2, "d": "2024-01-02 03:04:05", "d2": "1704164645", "k.e": "dot", "esc": "a\\"b\\\\c\\n"}'),
(2, '{"a": 1, "b": "str", "n": "12", "f": "x", "t": 0, "o": [], "arr": [{"x": 1}, {"x": 2}], "A": [1]}'),
(3, 'not json'),
(4, ''),
(5, '[1, 2, 3, {"a": "in array"}]'),
(6, '{"o": {"o": {"o": {"o": {"o": 1}}}}}'),
(7, '{"a": null, "n": null, "o": null, "b": null}'),
(8, '"scalar"'),
(9, '{"a": "x"}  trailing'),
(10, '{"ü": "unicode", "a": "ü", "n": 1.0, "f": 2, "t": 1, "b": [1], "o": {"y": 5, "x": "6"}}');

-- More than one block, so that the last row of a block (parsed from a copy) and the rows before it
-- (parsed in place) are both exercised.
INSERT INTO json_docs SELECT number + 100, concat('{"n": ', toString(number), ', "a": "v', toString(number % 13), '", "o": {"x": ', toString(number % 7), ', "y": "', repeat('y', number % 50), '"}, "b": [', toString(number), ']}') FROM numbers(200000);

CREATE VIEW json_wide AS SELECT
    id,
    JSONHas(raw, 'a') AS has_a,
    isValidJSON(raw) AS valid,
    JSONLength(raw) AS len,
    JSONLength(raw, 'b') AS len_b,
    JSONKey(raw, 1) AS key_1,
    JSONType(raw) AS type_root,
    JSONType(raw, 'a') AS type_a,
    JSONExtractInt(raw, 'n') AS int_n,
    JSONExtractUInt(raw, 'big') AS uint_big,
    JSONExtractInt(raw, 'neg') AS int_neg,
    JSONExtractFloat(raw, 'f') AS float_f,
    JSONExtractBool(raw, 't') AS bool_t,
    JSONExtractString(raw, 'a') AS str_a,
    JSONExtractString(raw, 'o', 'y') AS str_o_y,
    JSONExtractInt(raw, 'b', 1) AS int_b_1,
    JSONExtractInt(raw, 'b', -1) AS int_b_last,
    JSONExtractInt(raw, 'b', 4) AS int_b_4,
    JSONExtractInt(raw, 'b', 0) AS int_b_0,
    JSONExtractString(raw, 4, 'a') AS str_4_a,
    JSONExtractInt(raw, 'o', 'arr', 2) AS int_o_arr_2,
    JSONExtractInt(raw, 'o', 'o', 'o', 'o', 'o') AS int_deep,
    JSONExtractString(raw, 'k.e') AS str_dot,
    JSONExtractString(raw, 'esc') AS str_esc,
    JSONExtractString(raw, 'ü') AS str_unicode,
    JSONExtractInt(raw, 'dup') AS int_dup,
    JSONExtract(raw, 'n', 'Int64') AS ex_n_int,
    JSONExtract(raw, 'n', 'Nullable(Int64)') AS ex_n_nullable,
    JSONExtract(raw, 'n', 'String') AS ex_n_string,
    JSONExtract(raw, 'b', 'Array(Float64)') AS ex_b_array,
    JSONExtract(raw, 'o', 'Tuple(x Int32, y String)') AS ex_o_tuple,
    JSONExtract(raw, 'o', 'Map(String, String)') AS ex_o_map,
    JSONExtract(raw, 'a', 'Variant(String, Int64)') AS ex_a_variant,
    JSONExtract(raw, 'o', 'Dynamic') AS ex_o_dynamic,
    JSONExtract(raw, 'd', 'DateTime(\'UTC\')') AS ex_d_datetime,
    JSONExtract(raw, 'Tuple(a String, n Int64, o Tuple(x Int32))') AS ex_root_tuple,
    JSONExtractKeysAndValues(raw, 'o', 'String') AS kv_o,
    JSONExtractRaw(raw, 'o') AS raw_o,
    JSONExtractRaw(raw) AS raw_root,
    JSONExtractArrayRaw(raw, 'b') AS array_raw_b,
    JSONExtractKeysAndValuesRaw(raw, 'o') AS kv_raw_o,
    JSONExtractKeys(raw) AS keys_root,
    JSONExtractKeys(raw, 'o') AS keys_o,
    JSONExtractStringCaseInsensitive(raw, 'A') AS ci_str_a,
    JSONExtractString(raw, 'A') AS cs_str_A,
    JSONExtractIntCaseInsensitive(raw, 'N') AS ci_int_n,
    JSONExtractUIntCaseInsensitive(raw, 'BIG') AS ci_uint_big,
    JSONExtractFloatCaseInsensitive(raw, 'F') AS ci_float_f,
    JSONExtractBoolCaseInsensitive(raw, 'T') AS ci_bool_t,
    JSONExtractCaseInsensitive(raw, 'O', 'X', 'Int32') AS ci_ex_o_x,
    JSONExtractKeysAndValuesCaseInsensitive(raw, 'O', 'String') AS ci_kv_o,
    JSONExtractRawCaseInsensitive(raw, 'O') AS ci_raw_o,
    JSONExtractArrayRawCaseInsensitive(raw, 'B') AS ci_array_raw_b,
    JSONExtractKeysAndValuesRawCaseInsensitive(raw, 'O') AS ci_kv_raw_o,
    JSONExtractKeysCaseInsensitive(raw, 'O') AS ci_keys_o,
    JSONExtract(raw, 'o', 'Tuple(x Int32, y LowCardinality(String))') AS ex_o_tuple_lc,
    JSONExtract(raw, 'b', 'Array(LowCardinality(String))') AS ex_b_array_lc,
    JSONExtract(raw, 'o', 'Map(LowCardinality(String), String)') AS ex_o_map_lc,
    JSONExtractKeysAndValues(raw, 'o', 'LowCardinality(String)') AS kv_o_lc,
    JSONExtractInt(JSONExtractRaw(raw, 'o'), 'x') AS int_x_of_raw_o,
    JSONExtractString(JSONExtractRaw(raw, 'o'), 'y') AS str_y_of_raw_o
FROM json_docs;

CREATE TABLE json_wide_fused ENGINE = Memory AS SELECT /* tag:wide_fused */ * FROM json_wide SETTINGS fuse_json_functions = 1;
CREATE TABLE json_wide_plain ENGINE = Memory AS SELECT /* tag:wide_plain */ * FROM json_wide SETTINGS fuse_json_functions = 0;

SELECT 'rows', (SELECT count() FROM json_wide_fused), (SELECT count() FROM json_wide_plain);
SELECT 'fused minus plain', count() FROM (SELECT * FROM json_wide_fused EXCEPT SELECT * FROM json_wide_plain);
SELECT 'plain minus fused', count() FROM (SELECT * FROM json_wide_plain EXCEPT SELECT * FROM json_wide_fused);

SELECT id, has_a, valid, len, key_1, type_a, int_n, uint_big, int_neg, float_f, bool_t, str_a, str_o_y, int_b_1, int_b_last, int_b_4, str_4_a, int_deep, str_dot, str_esc, str_unicode, int_dup
FROM json_wide_fused WHERE id < 100 ORDER BY id;
SELECT id, ex_n_int, ex_n_nullable, ex_n_string, ex_b_array, ex_o_tuple, ex_o_map, ex_a_variant, ex_o_dynamic, ex_d_datetime, ex_root_tuple
FROM json_wide_fused WHERE id < 100 ORDER BY id;
SELECT id, kv_o, raw_o, raw_root, array_raw_b, kv_raw_o, keys_root, keys_o
FROM json_wide_fused WHERE id < 100 ORDER BY id;
SELECT id, ci_str_a, cs_str_A, ci_int_n, ci_uint_big, ci_float_f, ci_bool_t, ci_ex_o_x, ci_kv_o, ci_raw_o, ci_array_raw_b, ci_kv_raw_o, ci_keys_o
FROM json_wide_fused WHERE id < 100 ORDER BY id;
SELECT id, ex_o_tuple_lc, ex_b_array_lc, ex_o_map_lc, kv_o_lc, int_x_of_raw_o, str_y_of_raw_o
FROM json_wide_fused WHERE id < 100 ORDER BY id;

-- The same with the rapidjson parser, and with one row per block.
CREATE TABLE json_wide_rapid_fused ENGINE = Memory AS SELECT /* tag:rapid_fused */ * FROM json_wide SETTINGS fuse_json_functions = 1, allow_simdjson = 0;
CREATE TABLE json_wide_rapid_plain ENGINE = Memory AS SELECT /* tag:rapid_plain */ * FROM json_wide SETTINGS fuse_json_functions = 0, allow_simdjson = 0;
SELECT 'rapidjson rows', (SELECT count() FROM json_wide_rapid_fused), (SELECT count() FROM json_wide_rapid_plain);
SELECT 'rapidjson fused minus plain', count() FROM (SELECT * FROM json_wide_rapid_fused EXCEPT SELECT * FROM json_wide_rapid_plain);
SELECT 'rapidjson plain minus fused', count() FROM (SELECT * FROM json_wide_rapid_plain EXCEPT SELECT * FROM json_wide_rapid_fused);
CREATE TABLE json_wide_block1_fused ENGINE = Memory AS SELECT /* tag:block1_fused */ * FROM json_wide WHERE id < 100 SETTINGS fuse_json_functions = 1, max_block_size = 1;
SELECT 'one row per block fused minus plain', count() FROM (SELECT * FROM json_wide_block1_fused EXCEPT SELECT * FROM json_wide_plain WHERE id < 100);
SELECT 'one row per block plain minus fused', count() FROM (SELECT * FROM json_wide_plain WHERE id < 100 EXCEPT SELECT * FROM json_wide_block1_fused);

-- A document column stored with sparse serialization.
CREATE TABLE json_sparse (id UInt32, raw String) ENGINE = MergeTree ORDER BY id SETTINGS ratio_of_defaults_for_sparse_serialization = 0.5, compute_exact_num_defaults_for_sparse_columns = 1;
INSERT INTO json_sparse SELECT number, if(number % 20 = 0, concat('{"a": "s', toString(number), '", "n": ', toString(number), '}'), '') FROM numbers(2000);
SELECT DISTINCT serialization_kind FROM system.parts_columns WHERE database = currentDatabase() AND table = 'json_sparse' AND column = 'raw' AND active;
CREATE TABLE json_sparse_fused ENGINE = Memory AS SELECT /* tag:sparse_fused */ id, JSONExtractString(raw, 'a') AS a, JSONExtractInt(raw, 'n') AS n, isValidJSON(raw) AS valid FROM json_sparse SETTINGS fuse_json_functions = 1;
CREATE TABLE json_sparse_plain ENGINE = Memory AS SELECT /* tag:sparse_plain */ id, JSONExtractString(raw, 'a') AS a, JSONExtractInt(raw, 'n') AS n, isValidJSON(raw) AS valid FROM json_sparse SETTINGS fuse_json_functions = 0;
SELECT 'sparse rows', (SELECT count() FROM json_sparse_fused), (SELECT count() FROM json_sparse_plain), (SELECT countIf(valid) FROM json_sparse_fused);
SELECT 'sparse fused minus plain', count() FROM (SELECT * FROM json_sparse_fused EXCEPT SELECT * FROM json_sparse_plain);
SELECT 'sparse plain minus fused', count() FROM (SELECT * FROM json_sparse_plain EXCEPT SELECT * FROM json_sparse_fused);

-- The settings a call captured when it was built decide what its member of the group extracts.
CREATE TABLE json_settings_fused ENGINE = Memory AS SELECT /* tag:settings_fused */ id, JSONExtract(raw, 'd2', 'DateTime(\'UTC\')') AS d2, JSONExtract(raw, 'o', 'Tuple(y String, x Int32)') AS o FROM json_docs WHERE id < 100
    SETTINGS fuse_json_functions = 1, cast_string_to_date_time_mode = 'best_effort', json_extract_named_tuples_as_objects = 1;
CREATE TABLE json_settings_plain ENGINE = Memory AS SELECT /* tag:settings_plain */ id, JSONExtract(raw, 'd2', 'DateTime(\'UTC\')') AS d2, JSONExtract(raw, 'o', 'Tuple(y String, x Int32)') AS o FROM json_docs WHERE id < 100
    SETTINGS fuse_json_functions = 0, cast_string_to_date_time_mode = 'best_effort', json_extract_named_tuples_as_objects = 1;
CREATE TABLE json_settings_default ENGINE = Memory AS SELECT /* tag:settings_default */ id, JSONExtract(raw, 'd2', 'DateTime(\'UTC\')') AS d2, JSONExtract(raw, 'o', 'Tuple(y String, x Int32)') AS o FROM json_docs WHERE id < 100
    SETTINGS fuse_json_functions = 1;

SELECT 'settings fused minus plain', count() FROM (SELECT * FROM json_settings_fused EXCEPT SELECT * FROM json_settings_plain);
SELECT 'settings plain minus fused', count() FROM (SELECT * FROM json_settings_plain EXCEPT SELECT * FROM json_settings_fused);
SELECT id, d2, o FROM json_settings_fused ORDER BY id;
SELECT id, d2, o FROM json_settings_default ORDER BY id;

SYSTEM FLUSH LOGS query_log;
SELECT extract(query, 'tag:[a-z_]+') AS tag, ProfileEvents['JSONFunctionsFused'] AS fused, ProfileEvents['JSONFusedDocumentsParsed'] > 0 AS parsed
FROM system.query_log
WHERE current_database = currentDatabase() AND type = 'QueryFinish' AND query LIKE '%tag:%' AND query NOT LIKE '%system.query_log%'
ORDER BY event_time_microseconds;

DROP TABLE json_sparse_plain;
DROP TABLE json_sparse_fused;
DROP TABLE json_sparse;
DROP TABLE json_wide_block1_fused;
DROP TABLE json_wide_rapid_plain;
DROP TABLE json_wide_rapid_fused;
DROP TABLE json_settings_default;
DROP TABLE json_settings_plain;
DROP TABLE json_settings_fused;
DROP TABLE json_wide_plain;
DROP TABLE json_wide_fused;
DROP VIEW json_wide;
DROP TABLE json_docs;
