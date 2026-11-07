-- fuse_json_functions with short-circuit evaluation, lambdas and compiled expressions.
SET log_queries = 1;
SET fuse_json_functions = 1;

DROP TABLE IF EXISTS json_sc;
CREATE TABLE json_sc (id UInt32, raw String) ENGINE = MergeTree ORDER BY id;
INSERT INTO json_sc SELECT number, concat('{"a": "', if(number % 3 = 0, '', toString(number)), '", "b": "b', toString(number), '", "n": ', toString(number), ', "o": {"x": ', toString(number % 5), '}}') FROM numbers(1000);
INSERT INTO json_sc VALUES (1000, 'not json'), (1001, '{"a": "only a"}');

-- A lazily executed argument runs on a subset of the rows and is never fused; the eager calls are.
SELECT /* tag:if_enable */ sum(cityHash64(id, if(JSONHas(raw, 'a'), JSONExtractString(raw, 'a'), JSONExtractString(raw, 'b')))) FROM json_sc SETTINGS short_circuit_function_evaluation = 'enable';
SELECT /* tag:if_force_enable */ sum(cityHash64(id, if(JSONHas(raw, 'a'), JSONExtractString(raw, 'a'), JSONExtractString(raw, 'b')))) FROM json_sc SETTINGS short_circuit_function_evaluation = 'force_enable';
SELECT /* tag:if_disable */ sum(cityHash64(id, if(JSONHas(raw, 'a'), JSONExtractString(raw, 'a'), JSONExtractString(raw, 'b')))) FROM json_sc SETTINGS short_circuit_function_evaluation = 'disable';
SELECT /* tag:if_plain */ sum(cityHash64(id, if(JSONHas(raw, 'a'), JSONExtractString(raw, 'a'), JSONExtractString(raw, 'b')))) FROM json_sc SETTINGS fuse_json_functions = 0;

SELECT /* tag:and_enable */ count() FROM json_sc WHERE JSONHas(raw, 'a') AND JSONExtractInt(raw, 'n') % 2 = 0 AND JSONExtractString(raw, 'a') != '' SETTINGS short_circuit_function_evaluation = 'enable';
SELECT /* tag:and_disable */ count() FROM json_sc WHERE JSONHas(raw, 'a') AND JSONExtractInt(raw, 'n') % 2 = 0 AND JSONExtractString(raw, 'a') != '' SETTINGS short_circuit_function_evaluation = 'disable';
SELECT /* tag:and_plain */ count() FROM json_sc WHERE JSONHas(raw, 'a') AND JSONExtractInt(raw, 'n') % 2 = 0 AND JSONExtractString(raw, 'a') != '' SETTINGS fuse_json_functions = 0;

SELECT /* tag:multi_if_enable */ sum(cityHash64(id, multiIf(JSONExtractInt(raw, 'n') % 3 = 0, JSONExtractString(raw, 'a'), JSONExtractInt(raw, 'n') % 3 = 1, JSONExtractString(raw, 'b'), JSONExtractRaw(raw, 'o')))) FROM json_sc SETTINGS short_circuit_function_evaluation = 'enable';
SELECT /* tag:multi_if_plain */ sum(cityHash64(id, multiIf(JSONExtractInt(raw, 'n') % 3 = 0, JSONExtractString(raw, 'a'), JSONExtractInt(raw, 'n') % 3 = 1, JSONExtractString(raw, 'b'), JSONExtractRaw(raw, 'o')))) FROM json_sc SETTINGS fuse_json_functions = 0;

-- Two eager calls fuse next to a lazy one.
SELECT /* tag:mixed_enable */ sum(cityHash64(id, JSONExtractString(raw, 'a'), JSONExtractInt(raw, 'n'), if(JSONHas(raw, 'o'), JSONExtractInt(raw, 'o', 'x'), -1))) FROM json_sc SETTINGS short_circuit_function_evaluation = 'enable';
SELECT /* tag:mixed_plain */ sum(cityHash64(id, JSONExtractString(raw, 'a'), JSONExtractInt(raw, 'n'), if(JSONHas(raw, 'o'), JSONExtractInt(raw, 'o', 'x'), -1))) FROM json_sc SETTINGS fuse_json_functions = 0;

-- Lambda bodies are expressions of their own; the lambda argument is the shared document.
SELECT /* tag:lambda_fused */ sum(cityHash64(id, arrayMap(x -> (JSONExtractString(x, 'a'), JSONExtractInt(x, 'n')), [raw, raw2]), arrayFilter(x -> JSONHas(x, 'a') AND JSONExtractInt(x, 'n') > 0, [raw, raw2]))) FROM (SELECT id, raw, concat('{"a": "', toString(id), '", "n": ', toString(id * 2), '}') AS raw2 FROM json_sc);
SELECT /* tag:lambda_plain */ sum(cityHash64(id, arrayMap(x -> (JSONExtractString(x, 'a'), JSONExtractInt(x, 'n')), [raw, raw2]), arrayFilter(x -> JSONHas(x, 'a') AND JSONExtractInt(x, 'n') > 0, [raw, raw2]))) FROM (SELECT id, raw, concat('{"a": "', toString(id), '", "n": ', toString(id * 2), '}') AS raw2 FROM json_sc) SETTINGS fuse_json_functions = 0;

-- Compiled arithmetic over fused elements.
SELECT /* tag:jit_fused */ sum(JSONExtractInt(raw, 'n') * 2 + JSONExtractInt(raw, 'o', 'x') - JSONExtractInt(raw, 'n') % 7) FROM json_sc SETTINGS compile_expressions = 1, min_count_to_compile_expression = 0;
SELECT /* tag:jit_plain */ sum(JSONExtractInt(raw, 'n') * 2 + JSONExtractInt(raw, 'o', 'x') - JSONExtractInt(raw, 'n') % 7) FROM json_sc SETTINGS compile_expressions = 1, min_count_to_compile_expression = 0, fuse_json_functions = 0;

-- The same calls in WHERE, PREWHERE, GROUP BY and ORDER BY.
SELECT /* tag:clauses_fused */ JSONExtractInt(raw, 'o', 'x') AS x, count(), min(JSONExtractString(raw, 'b')) FROM json_sc PREWHERE JSONExtractInt(raw, 'n') % 2 = 0 WHERE JSONExtractString(raw, 'a') != '' GROUP BY x ORDER BY JSONExtractInt(raw, 'o', 'x');
SELECT /* tag:clauses_plain */ JSONExtractInt(raw, 'o', 'x') AS x, count(), min(JSONExtractString(raw, 'b')) FROM json_sc PREWHERE JSONExtractInt(raw, 'n') % 2 = 0 WHERE JSONExtractString(raw, 'a') != '' GROUP BY x ORDER BY JSONExtractInt(raw, 'o', 'x') SETTINGS fuse_json_functions = 0;

SYSTEM FLUSH LOGS query_log;
SELECT extract(query, 'tag:[a-z_]+') AS tag, ProfileEvents['JSONFunctionsFused'] AS fused
FROM system.query_log
WHERE current_database = currentDatabase() AND type = 'QueryFinish' AND query LIKE '%tag:%' AND query NOT LIKE '%system.query_log%'
ORDER BY event_time_microseconds;

DROP TABLE json_sc;
