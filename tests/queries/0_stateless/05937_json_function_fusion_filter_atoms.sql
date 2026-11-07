-- fuse_json_functions across the atoms of a WHERE / PREWHERE conjunction and lazily executed arguments.
SET log_queries = 1;
SET fuse_json_functions = 1;

DROP TABLE IF EXISTS json_atoms;
DROP TABLE IF EXISTS json_atoms_memory;
CREATE TABLE json_atoms (id UInt32, raw String, other String) ENGINE = MergeTree ORDER BY id;
INSERT INTO json_atoms SELECT number, concat('{"event": "', ['email.failed', 'store.redis_warm', 'other'][number % 3 + 1], '", "level": "', ['warn', 'info'][number % 2 + 1], '", "message": {"reason": "r', toString(number % 10), '", "operationId": "op', toString(number), '"}, "n": ', toString(number), '}'), concat('{"env": "', ['production', 'staging'][number % 2 + 1], '"}') FROM numbers(10000);
INSERT INTO json_atoms VALUES (10000, 'not json', '{}'), (10001, '{"event": "email.failed"}', '{"env": "production"}');
CREATE TABLE json_atoms_memory ENGINE = Memory AS SELECT * FROM json_atoms;

-- Two atoms on one document: in one filter and parsed once, unless short-circuit evaluation is off.
SELECT /* tag:where_two_atoms */ count() FROM json_atoms_memory WHERE JSONExtractString(raw, 'event') = 'email.failed' AND JSONExtractString(raw, 'level') = 'warn';
SELECT /* tag:where_two_atoms_disable */ count() FROM json_atoms_memory WHERE JSONExtractString(raw, 'event') = 'email.failed' AND JSONExtractString(raw, 'level') = 'warn' SETTINGS short_circuit_function_evaluation = 'disable';
SELECT /* tag:where_two_atoms_plain */ count() FROM json_atoms_memory WHERE JSONExtractString(raw, 'event') = 'email.failed' AND JSONExtractString(raw, 'level') = 'warn' SETTINGS fuse_json_functions = 0;

-- A cheap atom in front and an atom on another document behind are split as before; the run on `raw` stays together.
SELECT /* tag:where_run */ count() FROM json_atoms_memory WHERE id % 2 = 0 AND JSONExtractString(raw, 'event') = 'email.failed' AND JSONExtractString(raw, 'message', 'reason') = 'r1' AND JSONExtractString(raw, 'level') = 'warn' AND JSONExtractString(other, 'env') = 'production';
SELECT /* tag:where_run_plain */ count() FROM json_atoms_memory WHERE id % 2 = 0 AND JSONExtractString(raw, 'event') = 'email.failed' AND JSONExtractString(raw, 'message', 'reason') = 'r1' AND JSONExtractString(raw, 'level') = 'warn' AND JSONExtractString(other, 'env') = 'production' SETTINGS fuse_json_functions = 0;

-- An atom on another document between two atoms on `raw` ends the run: the atoms keep their order.
SELECT /* tag:where_interleaved */ count() FROM json_atoms_memory WHERE JSONExtractString(raw, 'event') = 'email.failed' AND JSONExtractString(other, 'env') = 'production' AND JSONExtractString(raw, 'level') = 'warn';

-- The same calls in the select list and the filter.
SELECT /* tag:where_and_select */ sum(cityHash64(JSONExtractString(raw, 'message', 'operationId'), JSONExtractInt(raw, 'n'))) FROM json_atoms_memory WHERE JSONExtractString(raw, 'event') = 'email.failed' AND JSONExtractString(raw, 'level') = 'warn';

-- Guarded atoms: the calls run only on the rows their guards pass, with or without fusion.
SELECT /* tag:where_guarded */ count() FROM json_atoms_memory WHERE if(raw LIKE '%email.failed%', JSONExtractString(raw, 'event') = 'email.failed', 0) AND if(raw LIKE '%warn%', JSONExtractString(raw, 'level') = 'warn', 0);
SELECT /* tag:where_guarded_plain */ count() FROM json_atoms_memory WHERE if(raw LIKE '%email.failed%', JSONExtractString(raw, 'event') = 'email.failed', 0) AND if(raw LIKE '%warn%', JSONExtractString(raw, 'level') = 'warn', 0) SETTINGS fuse_json_functions = 0;

-- An OR of predicates on one extracted value next to an atom on the same document.
SELECT /* tag:where_or */ count() FROM json_atoms_memory WHERE JSONExtractString(raw, 'level') = 'warn' AND (JSONExtractString(raw, 'event') LIKE 'email%' OR JSONExtractString(raw, 'event') LIKE 'store%');

-- The same conjunctions on MergeTree, where the conditions move to PREWHERE and are read in steps.
SELECT /* tag:prewhere_two_atoms */ count() FROM json_atoms WHERE JSONExtractString(raw, 'event') = 'email.failed' AND JSONExtractString(raw, 'level') = 'warn';
SELECT /* tag:prewhere_two_atoms_plain */ count() FROM json_atoms WHERE JSONExtractString(raw, 'event') = 'email.failed' AND JSONExtractString(raw, 'level') = 'warn' SETTINGS fuse_json_functions = 0;
SELECT /* tag:prewhere_run */ count() FROM json_atoms WHERE id % 2 = 0 AND JSONExtractString(raw, 'event') = 'email.failed' AND JSONExtractString(raw, 'message', 'reason') = 'r1' AND JSONExtractString(raw, 'level') = 'warn' AND JSONExtractString(other, 'env') = 'production';
SELECT /* tag:prewhere_guarded */ count() FROM json_atoms WHERE if(raw LIKE '%email.failed%', JSONExtractString(raw, 'event') = 'email.failed', 0) AND if(raw LIKE '%warn%', JSONExtractString(raw, 'level') = 'warn', 0);
SELECT /* tag:prewhere_explicit */ count() FROM json_atoms PREWHERE JSONExtractString(raw, 'event') = 'email.failed' AND JSONExtractString(raw, 'level') = 'warn' WHERE JSONExtractInt(raw, 'n') % 2 = 0;

-- A lazily executed call joins the group of a call that runs on every row, and only then.
SELECT /* tag:lazy_with_eager */ sum(cityHash64(JSONExtractString(raw, 'event'), if(JSONHas(raw, 'n'), JSONExtractInt(raw, 'n'), -1))) FROM json_atoms_memory;
SELECT /* tag:lazy_with_eager_plain */ sum(cityHash64(JSONExtractString(raw, 'event'), if(JSONHas(raw, 'n'), JSONExtractInt(raw, 'n'), -1))) FROM json_atoms_memory SETTINGS fuse_json_functions = 0;
SELECT /* tag:lazy_alone */ sum(cityHash64(id, if(id % 2 = 0, JSONExtractInt(raw, 'n'), 0), if(id % 3 = 0, JSONExtractString(raw, 'event'), ''))) FROM json_atoms_memory;
SELECT /* tag:lazy_alone_plain */ sum(cityHash64(id, if(id % 2 = 0, JSONExtractInt(raw, 'n'), 0), if(id % 3 = 0, JSONExtractString(raw, 'event'), ''))) FROM json_atoms_memory SETTINGS fuse_json_functions = 0;
SELECT /* tag:lazy_force_enable */ sum(cityHash64(JSONExtractString(raw, 'event'), if(JSONHas(raw, 'n'), JSONExtractInt(raw, 'n'), -1))) FROM json_atoms_memory SETTINGS short_circuit_function_evaluation = 'force_enable';

-- The split as the pipeline builds it.
SELECT replaceRegexpAll(explain, '^ *', '') FROM (EXPLAIN actions = 1 SELECT count() FROM json_atoms_memory WHERE id % 2 = 0 AND JSONExtractString(raw, 'event') = 'email.failed' AND JSONExtractString(raw, 'level') = 'warn' AND JSONExtractString(other, 'env') = 'production') WHERE explain LIKE '%AND column%' OR explain LIKE '%Filter column%';
SELECT replaceRegexpAll(explain, '^ *', '') FROM (EXPLAIN actions = 1 SELECT count() FROM json_atoms_memory WHERE id % 2 = 0 AND JSONExtractString(raw, 'event') = 'email.failed' AND JSONExtractString(raw, 'level') = 'warn' AND JSONExtractString(other, 'env') = 'production' SETTINGS fuse_json_functions = 0) WHERE explain LIKE '%AND column%' OR explain LIKE '%Filter column%';

SYSTEM FLUSH LOGS query_log;
SELECT extract(query, 'tag:[a-z_]+') AS tag, ProfileEvents['JSONFunctionsFused'] AS fused, ProfileEvents['JSONDocumentsParsed'] AS parsed, ProfileEvents['JSONFusedDocumentsParsed'] AS fused_parsed
FROM system.query_log
WHERE current_database = currentDatabase() AND type = 'QueryFinish' AND query LIKE '%tag:%' AND query NOT LIKE '%system.query_log%'
ORDER BY event_time_microseconds;

DROP TABLE json_atoms_memory;
DROP TABLE json_atoms;
