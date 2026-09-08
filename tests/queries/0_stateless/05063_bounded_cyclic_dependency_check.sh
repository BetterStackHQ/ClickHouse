#!/usr/bin/env bash
# Tags: atomic-database

CURDIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../shell_config.sh
. "$CURDIR"/../shell_config.sh

# A cycle is described by listing its tables in an unspecified order and with their UUIDs, so only the error code and
# the stable part of the message are printed. The name of the temporary table a REPLACE goes through is random too,
# and the name of the test database is not fixed either.
function run_and_report_cycle()
{
    $CLICKHOUSE_CLIENT --query "$1" 2>&1 \
        | sed -n -E 's/^Code: ([0-9]+)\..*(Cannot .* because it will lead to cyclic dependencies):.*/Code: \1. \2/p' \
        | sed -E "s/_tmp_replace_[0-9a-z_]+/_tmp_replace/g; s/${CLICKHOUSE_DATABASE}\./default./g" \
        | head -n 1
}

$CLICKHOUSE_CLIENT --query "
DROP DICTIONARY IF EXISTS altered_dict;
DROP DICTIONARY IF EXISTS dict_over_absent;
DROP DICTIONARY IF EXISTS dict_over_view;
DROP DICTIONARY IF EXISTS self_dict;
DROP DICTIONARY IF EXISTS dict;
DROP VIEW IF EXISTS dict_view;
DROP TABLE IF EXISTS mv;
DROP VIEW IF EXISTS replaced;
DROP VIEW IF EXISTS v_reader;
DROP VIEW IF EXISTS v;
DROP VIEW IF EXISTS renamed_reader;
DROP VIEW IF EXISTS renamed_to;
DROP VIEW IF EXISTS renamed;
DROP VIEW IF EXISTS exchanged_1_renamed;
DROP VIEW IF EXISTS exchanged_2;
DROP VIEW IF EXISTS exchanged_1;
DROP TABLE IF EXISTS altered;
DROP TABLE IF EXISTS other_source;
DROP TABLE IF EXISTS source;
"

$CLICKHOUSE_CLIENT --query "
CREATE TABLE source (id UInt64, value String) ENGINE = MergeTree ORDER BY id;
INSERT INTO source VALUES (1, 'from source');
CREATE TABLE other_source (id UInt64, value String) ENGINE = MergeTree ORDER BY id;
INSERT INTO other_source VALUES (2, 'from other source');
"

# A view cannot read from itself directly: `CREATE VIEW v AS SELECT * FROM v` is rejected while its SELECT is
# analysed, before the cyclic dependency check runs, so that shape is covered by the unit tests instead.
echo '-- a view reading from its own dependent'
$CLICKHOUSE_CLIENT --query "
CREATE VIEW v AS SELECT * FROM source;
CREATE VIEW v_reader AS SELECT * FROM v;
"
run_and_report_cycle "CREATE OR REPLACE VIEW v AS SELECT * FROM v_reader"
echo '-- and the replaced view still reads its original source'
$CLICKHOUSE_CLIENT --query "SELECT * FROM v ORDER BY id"

$CLICKHOUSE_CLIENT --query "
CREATE DICTIONARY dict (id UInt64, value String)
PRIMARY KEY id SOURCE(CLICKHOUSE(TABLE source)) LAYOUT(FLAT()) LIFETIME(MIN 0 MAX 1000);
CREATE VIEW dict_view AS SELECT id, dictGet('dict', 'value', id) AS value FROM source;
"

echo '-- a dictionary replaced with one reading a view over it'
run_and_report_cycle "CREATE OR REPLACE DICTIONARY dict (id UInt64, value String)
PRIMARY KEY id SOURCE(CLICKHOUSE(TABLE dict_view)) LAYOUT(FLAT()) LIFETIME(MIN 0 MAX 1000)"
run_and_report_cycle "REPLACE DICTIONARY dict (id UInt64, value String)
PRIMARY KEY id SOURCE(CLICKHOUSE(TABLE dict_view)) LAYOUT(FLAT()) LIFETIME(MIN 0 MAX 1000)"

echo '-- a dictionary reading itself'
run_and_report_cycle "CREATE OR REPLACE DICTIONARY self_dict (id UInt64, value String)
PRIMARY KEY id SOURCE(CLICKHOUSE(TABLE self_dict)) LAYOUT(FLAT()) LIFETIME(MIN 0 MAX 1000)"

echo '-- exchanging it with such a dictionary'
$CLICKHOUSE_CLIENT --query "
CREATE DICTIONARY dict_over_view (id UInt64, value String)
PRIMARY KEY id SOURCE(CLICKHOUSE(TABLE dict_view)) LAYOUT(FLAT()) LIFETIME(MIN 0 MAX 1000);
"
run_and_report_cycle "EXCHANGE DICTIONARIES dict AND dict_over_view"

echo '-- and renaming such a dictionary onto its name'
$CLICKHOUSE_CLIENT --query "DROP DICTIONARY dict"
run_and_report_cycle "RENAME DICTIONARY dict_over_view TO dict"

echo '-- an ALTER adding a default which reads a dictionary reading the altered table'
$CLICKHOUSE_CLIENT --query "
CREATE TABLE altered (key Int32, value Int32) ENGINE = MergeTree PRIMARY KEY key;
CREATE DICTIONARY altered_dict (key Int32, value Int32)
PRIMARY KEY key SOURCE(CLICKHOUSE(TABLE altered)) LAYOUT(HASHED()) LIFETIME(MIN 0 MAX 0);
"
run_and_report_cycle "ALTER TABLE altered ADD COLUMN key2 Int32 DEFAULT dictGetOrDefault('altered_dict', 'value', 0, 1)"

echo '-- replacing a view which a materialized view reads, with the same and with a different source'
$CLICKHOUSE_CLIENT --query "
CREATE VIEW replaced AS SELECT * FROM source;
CREATE MATERIALIZED VIEW mv (id UInt64, value String) ENGINE = MergeTree ORDER BY id AS SELECT * FROM replaced;
CREATE OR REPLACE VIEW replaced AS SELECT * FROM source;
CREATE OR REPLACE VIEW replaced AS SELECT * FROM other_source;
SELECT * FROM replaced ORDER BY id;
"

echo '-- exchanging two views with disjoint sources'
$CLICKHOUSE_CLIENT --query "
CREATE VIEW exchanged_1 AS SELECT * FROM source;
CREATE VIEW exchanged_2 AS SELECT * FROM other_source;
EXCHANGE TABLES exchanged_1 AND exchanged_2;
SELECT * FROM exchanged_1 ORDER BY id;
SELECT * FROM exchanged_2 ORDER BY id;
"

echo '-- renaming a view'
$CLICKHOUSE_CLIENT --query "
RENAME TABLE exchanged_1 TO exchanged_1_renamed;
SELECT * FROM exchanged_1_renamed ORDER BY id;
"

echo '-- renaming a view which another view reads'
$CLICKHOUSE_CLIENT --query "
CREATE VIEW renamed AS SELECT * FROM source;
CREATE VIEW renamed_reader AS SELECT * FROM renamed;
RENAME TABLE renamed TO renamed_to;
SELECT * FROM renamed_to ORDER BY id;
"
echo '-- the reader refers to the old name, so creating a view with that name again makes it readable'
$CLICKHOUSE_CLIENT --query "
CREATE VIEW renamed AS SELECT * FROM other_source;
SELECT * FROM renamed_reader ORDER BY id;
"

echo '-- a dictionary reading a table which does not exist yet'
$CLICKHOUSE_CLIENT --query "
CREATE DICTIONARY dict_over_absent (id UInt64, value String)
PRIMARY KEY id SOURCE(CLICKHOUSE(TABLE not_created_yet)) LAYOUT(FLAT()) LIFETIME(MIN 0 MAX 1000);
SELECT count() FROM system.tables WHERE database = currentDatabase() AND name = 'dict_over_absent';
"
