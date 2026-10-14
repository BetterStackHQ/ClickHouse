#!/usr/bin/env bash
# Tags: no-shared-merge-tree

CUR_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../shell_config.sh
. "$CUR_DIR"/../shell_config.sh

# Parts of one table are loaded through a memo that parses each distinct `columns.txt` once and
# finishes the list it returns - the aggregate function versions - before sharing it. Three things
# have to hold. The memo is keyed on the contents of the file, so a part written before a schema
# change must not pick up the entry that belongs to parts written after it. The finished list must
# carry the same types a part would have built for itself. And the sharing must be safe: the parts
# of a table load concurrently, so this test is also the one to run under a thread sanitizer build
# to certify the memo.
#
# Every table below keeps its parts separate with `max_bytes_to_merge_at_max_space_in_pool = 1`
# rather than `SYSTEM STOP MERGES`, because that lock is keyed on the live table and is released
# when the re-attached table starts up, which would merge the parts away before they are counted.

${CLICKHOUSE_CLIENT} --query "DROP TABLE IF EXISTS t_memo_uniform SYNC"
${CLICKHOUSE_CLIENT} --query "DROP TABLE IF EXISTS t_memo_evolved SYNC"

echo "-- every part shares one schema"
${CLICKHOUSE_CLIENT} --query "
    CREATE TABLE t_memo_uniform (id UInt32, s String, a Array(Nullable(UInt64)), d Decimal(18, 4))
    ENGINE = MergeTree ORDER BY id
    SETTINGS min_bytes_for_wide_part = 1, max_bytes_to_merge_at_max_space_in_pool = 1;"
for i in 1 2 3 4 5; do
    ${CLICKHOUSE_CLIENT} --query "
        INSERT INTO t_memo_uniform
        SELECT number + ${i} * 100, toString(number), [number, NULL], number / 3 FROM numbers(10)"
done
${CLICKHOUSE_CLIENT} --query "DETACH TABLE t_memo_uniform SYNC"
${CLICKHOUSE_CLIENT} --query "ATTACH TABLE t_memo_uniform"
echo -n "parts: "
${CLICKHOUSE_CLIENT} --query "
    SELECT count() FROM system.parts
    WHERE database = currentDatabase() AND table = 't_memo_uniform' AND active"
echo -n "rows: "
${CLICKHOUSE_CLIENT} --query "SELECT count() FROM t_memo_uniform"
echo "types resolved per part:"
${CLICKHOUSE_CLIENT} --query "
    SELECT column, type, count() AS parts
    FROM system.parts_columns
    WHERE database = currentDatabase() AND table = 't_memo_uniform' AND active
    GROUP BY column, type ORDER BY column, type"

echo "-- a part written before a schema change"
${CLICKHOUSE_CLIENT} --query "
    CREATE TABLE t_memo_evolved (id UInt32, s String)
    ENGINE = MergeTree ORDER BY id
    SETTINGS min_bytes_for_wide_part = 1, max_bytes_to_merge_at_max_space_in_pool = 1;"
${CLICKHOUSE_CLIENT} --query "INSERT INTO t_memo_evolved SELECT number, toString(number) FROM numbers(10)"

# ADD COLUMN changes the table's metadata without rewriting existing parts, so the first part
# keeps its own two-column `columns.txt` while the next one gets a three-column list.
${CLICKHOUSE_CLIENT} --query "ALTER TABLE t_memo_evolved ADD COLUMN n Nullable(Int64)"
${CLICKHOUSE_CLIENT} --query "
    INSERT INTO t_memo_evolved SELECT number + 100, toString(number), number FROM numbers(10)"

${CLICKHOUSE_CLIENT} --query "DETACH TABLE t_memo_evolved SYNC"
${CLICKHOUSE_CLIENT} --query "ATTACH TABLE t_memo_evolved"

echo -n "parts: "
${CLICKHOUSE_CLIENT} --query "
    SELECT count() FROM system.parts
    WHERE database = currentDatabase() AND table = 't_memo_evolved' AND active"
echo -n "rows: "
${CLICKHOUSE_CLIENT} --query "SELECT count() FROM t_memo_evolved"
echo "types resolved per part:"
${CLICKHOUSE_CLIENT} --query "
    SELECT column, type, count() AS parts
    FROM system.parts_columns
    WHERE database = currentDatabase() AND table = 't_memo_evolved' AND active
    GROUP BY column, type ORDER BY column, type"
echo -n "sum of the new column: "
${CLICKHOUSE_CLIENT} --query "SELECT sum(ifNull(n, 0)) FROM t_memo_evolved"

${CLICKHOUSE_CLIENT} --query "DROP TABLE t_memo_uniform SYNC"
${CLICKHOUSE_CLIENT} --query "DROP TABLE t_memo_evolved SYNC"
