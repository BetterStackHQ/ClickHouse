-- The `JSONExtract*CaseInsensitive` family matches named tuple element names
-- against JSON object keys ASCII-case-insensitively, with the first
-- case-insensitive match in document order winning (like the scalar path's
-- key lookup). The case-sensitive family is unchanged.

-- Basic element-name matching, both parsers.
SELECT JSONExtractCaseInsensitive('{"Name":"x","AGE":3}', 'Tuple(name String, age Int64)');
SELECT JSONExtractCaseInsensitive('{"Name":"x","AGE":3}', 'Tuple(name String, age Int64)') SETTINGS allow_simdjson = 0;

-- First case-insensitive match in document order wins when it is type-valid.
SELECT JSONExtractCaseInsensitive('{"K":"first","k":"second"}', 'Tuple(k String)');
SELECT JSONExtractCaseInsensitive('{"K":"first","k":"second"}', 'Tuple(k String)') SETTINGS allow_simdjson = 0;
SELECT JSONExtractStringCaseInsensitive('{"K":"first","k":"second"}', 'k');

-- When the first match is invalid for the type, the tuple keeps the first VALID
-- match (like the case-sensitive family with exact duplicates), while the scalar
-- function takes the first occurrence strictly.
SELECT JSONExtractCaseInsensitive('{"K":"notanumber","k":5}', 'Tuple(k Int64)');
SELECT JSONExtractIntCaseInsensitive('{"K":"notanumber","k":5}', 'k');

-- Matching is ASCII-only: keys differing in non-ASCII letter case do not match.
SELECT JSONExtractCaseInsensitive('{"Ключ":1}', 'Tuple(`ключ` Int64)');

-- Path segments and tuple element names are both case-insensitive.
SELECT JSONExtractCaseInsensitive('{"DATA":{"NaMe":"y"}}', 'data', 'Tuple(name String)');

-- Nested types: Array(Tuple), Map values, KeysAndValues.
SELECT JSONExtractCaseInsensitive('{"Rows":[{"ID":1},{"id":2}]}', 'rows', 'Array(Tuple(id Int64))');
SELECT JSONExtractCaseInsensitive('{"m":{"k1":{"Val":7}}}', 'm', 'Map(String, Tuple(val Int64))');
SELECT JSONExtractKeysAndValuesCaseInsensitive('{"k1":{"Val":7},"k2":{"VAL":8}}', 'Tuple(val Int64)');

-- The case-sensitive family is unaffected: mismatched case defaults, exact case works.
SELECT JSONExtract('{"Name":"x"}', 'Tuple(name String)');
SELECT JSONExtract('{"name":"x"}', 'Tuple(name String)');

-- Interaction with `json_extract_named_tuples_as_objects`: an array is refused
-- for a named tuple in the case-insensitive family too...
SELECT JSONExtractCaseInsensitive('{"T":[1,2]}', 't', 'Tuple(a Int64, b Int64)');
-- ...unless the setting is disabled, which restores positional fill.
SELECT JSONExtractCaseInsensitive('{"T":[1,2]}', 't', 'Tuple(a Int64, b Int64)') SETTINGS json_extract_named_tuples_as_objects = 0;

-- Unnamed tuples fill positionally regardless of the function family.
SELECT JSONExtractCaseInsensitive('{"t":[1,2]}', 't', 'Tuple(Int64, Int64)');

-- Element names that differ only by character case are ambiguous under
-- case-insensitive matching and are rejected when the extraction tree is built.
SELECT JSONExtractCaseInsensitive('{"a":1}', 'Tuple(Name Int64, name Int64)'); -- { serverError BAD_ARGUMENTS }
SELECT JSONExtractCaseInsensitive('{"a":1}', 'Tuple(Name Int64, name Int64)') SETTINGS allow_simdjson = 0; -- { serverError BAD_ARGUMENTS }

-- The same tuple type stays valid for the case-sensitive family.
SELECT JSONExtract('{"Name":1,"name":2}', 'Tuple(Name Int64, name Int64)');
