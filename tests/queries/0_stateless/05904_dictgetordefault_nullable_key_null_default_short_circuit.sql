-- Tags: no-parallel-replicas
-- no-parallel-replicas: Dictionary source tables are not available on parallel-replica workers.

-- With a Nullable key the declared result type of `dictGetOrDefault` is Nullable, so a
-- lazily-evaluated default expression that genuinely evaluates to NULL on a not-found row
-- must produce a NULL result instead of throwing `CANNOT_INSERT_NULL_IN_ORDINARY_COLUMN`.
-- A plain-column default takes the eager path, where a NULL default yields the attribute
-- default instead; both behaviors are pinned here exactly as they were before the
-- regression.

SET short_circuit_function_evaluation = 'enable';

DROP TABLE IF EXISTS test_dict_nullkey_src;
DROP TABLE IF EXISTS test_dict_nullkey_input;
DROP DICTIONARY IF EXISTS test_dict_nullkey;

CREATE TABLE test_dict_nullkey_src (id UInt64, s String, sn Nullable(String), n UInt32) ENGINE = MergeTree ORDER BY id;
INSERT INTO test_dict_nullkey_src VALUES (1, 'found1', 'nfound1', 11), (2, 'found2', NULL, 22);

CREATE DICTIONARY test_dict_nullkey
(
    `id` UInt64,
    `s`  String DEFAULT '',
    `sn` Nullable(String) DEFAULT NULL,
    `n`  UInt32 DEFAULT 0
)
PRIMARY KEY id
SOURCE(CLICKHOUSE(TABLE 'test_dict_nullkey_src'))
LAYOUT(HASHED())
LIFETIME(0);

-- keys: found, not-found with non-NULL default, not-found with NULL default, NULL key
CREATE TABLE test_dict_nullkey_input (k Nullable(UInt64), d Nullable(String)) ENGINE = MergeTree ORDER BY tuple();
INSERT INTO test_dict_nullkey_input VALUES (1, 'x'), (98, 'fallback'), (99, NULL), (NULL, 'y');

-- Lazy default expression under short-circuit: NULL default on a not-found row gives NULL.
SELECT k, dictGetOrDefault('test_dict_nullkey', 's', k, concat(d, '')) FROM test_dict_nullkey_input ORDER BY k;

-- Numeric attribute with a lazy arithmetic Nullable default.
SELECT k, dictGetOrDefault('test_dict_nullkey', 'n', k, length(concat(d, ''))) FROM test_dict_nullkey_input ORDER BY k;

-- Nullable attribute: the declared type and the attribute type agree, no column lift needed.
SELECT k, dictGetOrDefault('test_dict_nullkey', 'sn', k, concat(d, '')) FROM test_dict_nullkey_input ORDER BY k;

-- The not-found + NULL-default row inside nested short-circuited conditionals
-- (the shape that triggered the regression in generated expressions).
SELECT
    k,
    if(k IS NOT NULL,
       multiIf(dictGetOrDefault('test_dict_nullkey', 's', k, concat(d, '')) = 'found1', 'one',
               dictGetOrDefault('test_dict_nullkey', 's', k, concat(d, '')) IS NULL, 'null-default',
               'other'),
       'null-key')
FROM test_dict_nullkey_input ORDER BY k;

-- Plain-column default takes the eager path: a NULL default yields the attribute default.
SELECT k, dictGetOrDefault('test_dict_nullkey', 's', k, d) FROM test_dict_nullkey_input ORDER BY k;

-- Eager evaluation of the same expression matches the plain-column behavior.
SET short_circuit_function_evaluation = 'disable';
SELECT k, dictGetOrDefault('test_dict_nullkey', 's', k, concat(d, '')) FROM test_dict_nullkey_input ORDER BY k;

DROP DICTIONARY test_dict_nullkey;
DROP TABLE test_dict_nullkey_input;
DROP TABLE test_dict_nullkey_src;
