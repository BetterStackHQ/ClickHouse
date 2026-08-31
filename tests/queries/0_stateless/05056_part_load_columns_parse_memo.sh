#!/usr/bin/env bash
# Tags: no-shared-merge-tree

CUR_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../shell_config.sh
. "$CUR_DIR"/../shell_config.sh

# Parts of one table are loaded through a memo that parses each distinct `columns.txt` once and
# finishes the list it returns - aggregate function versions, quantized serializations - before
# sharing it. Three things have to hold. The memo is keyed on the contents of the file, so a part
# written before a schema change must not pick up the entry that belongs to parts written after
# it. The finished list must carry the same types and serializations a part would have built for
# itself. And the sharing must be safe: the parts of a table load concurrently, so this test is
# also the one to run under a thread sanitizer build to certify the memo.
#
# Every table below keeps its parts separate with `max_bytes_to_merge_at_max_space_in_pool = 1`
# rather than `SYSTEM STOP MERGES`, because that lock is keyed on the live table and is released
# when the re-attached table starts up, which would merge the parts away before they are counted.

${CLICKHOUSE_CLIENT} --query "DROP TABLE IF EXISTS t_memo_uniform SYNC"
${CLICKHOUSE_CLIENT} --query "DROP TABLE IF EXISTS t_memo_evolved SYNC"
${CLICKHOUSE_CLIENT} --query "DROP TABLE IF EXISTS t_memo_quantized SYNC"

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

# A `Quantized(...)` codec is the case that forces the memo to finish the list itself: the
# serialization that writes the `<column>.quantized` companion stream is not in `columns.txt`, it
# is attached from the table's metadata afterwards, and it is attached to the type instance the
# memo shares between the parts. Every part must come back with it.
echo "-- a column whose serialization comes from the table's metadata"
${CLICKHOUSE_CLIENT} --allow_experimental_codecs 1 --query "
    CREATE TABLE t_memo_quantized (id UInt32, vec Array(Float32) CODEC(Quantized('rabitq', 64)), s String)
    ENGINE = MergeTree ORDER BY id
    SETTINGS min_bytes_for_wide_part = 0, min_rows_for_wide_part = 0,
             max_bytes_to_merge_at_max_space_in_pool = 1;"
for i in 1 2 3; do
    ${CLICKHOUSE_CLIENT} --query "
        INSERT INTO t_memo_quantized
        SELECT number + ${i} * 100, arrayMap(x -> toFloat32(x + number), range(64)), toString(number)
        FROM numbers(10)"
done
${CLICKHOUSE_CLIENT} --query "DETACH TABLE t_memo_quantized SYNC"
${CLICKHOUSE_CLIENT} --allow_experimental_codecs 1 --query "ATTACH TABLE t_memo_quantized"

echo -n "parts: "
${CLICKHOUSE_CLIENT} --query "
    SELECT count() FROM system.parts
    WHERE database = currentDatabase() AND table = 't_memo_quantized' AND active"
echo -n "rows: "
${CLICKHOUSE_CLIENT} --query "SELECT count() FROM t_memo_quantized"
echo "types resolved per part:"
${CLICKHOUSE_CLIENT} --query "
    SELECT column, type, count() AS parts
    FROM system.parts_columns
    WHERE database = currentDatabase() AND table = 't_memo_quantized' AND active
    GROUP BY column, type ORDER BY column, type"
echo -n "parts whose vec carries the quantized stream: "
${CLICKHOUSE_CLIENT} --query "
    SELECT countIf(arrayExists(s -> s LIKE '%quantized%', substreams))
    FROM system.parts_columns
    WHERE database = currentDatabase() AND table = 't_memo_quantized' AND active AND column = 'vec'"
echo -n "rows whose quantized subcolumn reads back: "
${CLICKHOUSE_CLIENT} --query "SELECT countIf(length(hex(vec.quantized)) > 0) FROM t_memo_quantized"

${CLICKHOUSE_CLIENT} --query "DROP TABLE t_memo_uniform SYNC"
${CLICKHOUSE_CLIENT} --query "DROP TABLE t_memo_evolved SYNC"
${CLICKHOUSE_CLIENT} --query "DROP TABLE t_memo_quantized SYNC"
