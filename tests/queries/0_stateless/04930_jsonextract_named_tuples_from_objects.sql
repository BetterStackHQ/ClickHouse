-- `JSONExtract` fills named tuples from JSON objects only (see the
-- `json_extract_named_tuples_as_objects` setting); unnamed tuples keep the
-- historical positional fill from arrays.

-- Named tuple from an array: defaults with the setting on (never an error),
-- historical positional fill with it off.
SET json_extract_named_tuples_as_objects = 1;
SELECT JSONExtract('{"t":["a","b"]}', 't', 'Tuple(x String, y String)');
SET json_extract_named_tuples_as_objects = 0;
SELECT JSONExtract('{"t":["a","b"]}', 't', 'Tuple(x String, y String)');
SET json_extract_named_tuples_as_objects = 1;

-- Objects fill named tuples by key under both values, order-independent.
SELECT JSONExtract('{"t":{"y":"b","x":"a"}}', 't', 'Tuple(x String, y String)');

-- Unnamed tuples: positional from arrays, unchanged by the setting.
SELECT JSONExtract('[3,5,7]', 'Tuple(Int64, Int64, Int64)');
SET json_extract_named_tuples_as_objects = 0;
SELECT JSONExtract('[3,5,7]', 'Tuple(Int64, Int64, Int64)');
SET json_extract_named_tuples_as_objects = 1;

-- Nested: outer object fill works, inner named tuple meeting an array yields
-- defaults inside a complex value (no error).
SELECT JSONExtract('{"o":{"inner":["a","b"],"k":7}}', 'o', 'Tuple(inner Tuple(p String, q String), k Int64)');

-- Named and unnamed side by side on the same array value.
SELECT JSONExtract('{"v":[1,2]}', 'v', 'Tuple(a Int64, b Int64)'), JSONExtract('{"v":[1,2]}', 'v', 'Tuple(Int64, Int64)');

-- Array of named tuples from array-of-arrays: each element defaults (setting
-- on), positional (off).
SELECT JSONExtract('{"l":[["a","b"],["c","d"]]}', 'l', 'Array(Tuple(x String, y String))');
SET json_extract_named_tuples_as_objects = 0;
SELECT JSONExtract('{"l":[["a","b"],["c","d"]]}', 'l', 'Array(Tuple(x String, y String))');
SET json_extract_named_tuples_as_objects = 1;

-- Scalar/tuple equivalence: the tuple element equals the scalar extraction for
-- object, array, and absent shapes.
SELECT
    tupleElement(JSONExtract(j, 'k', 'Tuple(a String)'), 'a') = JSONExtract(j, 'k', 'a', 'String')
FROM (SELECT arrayJoin(['{"k":{"a":"v"}}', '{"k":["v"]}', '{"k":7}', '{}']) AS j);

-- Duplicate keys (documented divergence, pinned): named tuple keeps the first
-- valid occurrence; the scalar path keeps the first occurrence.
SELECT JSONExtract('{"t":{"x":1,"x":2}}', 't', 'Tuple(x Int64)'), JSONExtract('{"t":{"x":1,"x":2}}', 't', 'x', 'Int64');
