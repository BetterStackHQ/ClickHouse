#!/usr/bin/env bash
# Tags: no-shared-merge-tree, no-object-storage
# The test edits files inside the part directory, so the part must be stored as separate files
# (min_bytes_for_full_part_storage = 0) on a local disk this process can write to.

CUR_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../shell_config.sh
. "$CUR_DIR"/../shell_config.sh

# `checkSize` answers three questions about every file listed in `checksums.txt`: is it a
# directory (a projection - skip it), does it exist at all, and is it the recorded size. This
# pins each of those outcomes to its error, so that answering all three from one lookup cannot
# quietly change what is detected.

TABLE_SETTINGS="min_rows_for_wide_part = 1, min_bytes_for_wide_part = 1,
                min_bytes_for_full_part_storage = 0, replace_long_file_name_to_hash = 0"

recreate() {
    ${CLICKHOUSE_CLIENT} --query "DROP TABLE IF EXISTS t_check_size SYNC"
    ${CLICKHOUSE_CLIENT} --query "
        CREATE TABLE t_check_size (id UInt32, s String)
        ENGINE = MergeTree ORDER BY id SETTINGS ${TABLE_SETTINGS};"
    ${CLICKHOUSE_CLIENT} --query "INSERT INTO t_check_size SELECT number, toString(number) FROM numbers(100)"
}

# `system.parts.path` ends with '<part name>/'; strip it to get the table's data directory.
part_dir() {
    ${CLICKHOUSE_CLIENT} --query "
        SELECT path FROM system.parts
        WHERE database = currentDatabase() AND table = 't_check_size' AND active"
}
detached_dir() {
    ${CLICKHOUSE_CLIENT} --query "
        SELECT substring(path, 1, length(path) - length(name) - 1) || 'detached/' || name
        FROM system.parts
        WHERE database = currentDatabase() AND table = 't_check_size' AND active"
}
part_name() {
    ${CLICKHOUSE_CLIENT} --query "
        SELECT name FROM system.parts
        WHERE database = currentDatabase() AND table = 't_check_size' AND active"
}

# Re-attaching a detached part runs the same metadata load and consistency check as startup,
# but reports the failure to the client instead of quietly detaching the part, so the exact
# error code is observable.
attach_part_error() {
    ${CLICKHOUSE_CLIENT} --query "ALTER TABLE t_check_size ATTACH PART '$1'" 2>&1 \
        | grep -o -m1 -E 'FILE_DOESNT_EXIST|BAD_SIZE_OF_FILE_IN_DATA_PART' || echo "NO ERROR"
}

echo "1. a file listed in checksums.txt is missing"
recreate
PART=$(part_name)
DETACHED=$(detached_dir)
${CLICKHOUSE_CLIENT} --query "ALTER TABLE t_check_size DETACH PARTITION tuple()"
rm -f "${DETACHED}/s.bin"
attach_part_error "$PART"

echo "2. a file listed in checksums.txt has the wrong size"
recreate
PART=$(part_name)
DETACHED=$(detached_dir)
${CLICKHOUSE_CLIENT} --query "ALTER TABLE t_check_size DETACH PARTITION tuple()"
printf 'xx' >> "${DETACHED}/s.bin"
attach_part_error "$PART"

echo "3. a projection directory listed in checksums.txt is skipped, the part still loads"
${CLICKHOUSE_CLIENT} --query "DROP TABLE IF EXISTS t_check_size SYNC"
${CLICKHOUSE_CLIENT} --query "
    CREATE TABLE t_check_size (id UInt32, s String, PROJECTION p (SELECT s, count() GROUP BY s))
    ENGINE = MergeTree ORDER BY id SETTINGS ${TABLE_SETTINGS};"
${CLICKHOUSE_CLIENT} --query "INSERT INTO t_check_size SELECT number, toString(number) FROM numbers(100)"
${CLICKHOUSE_CLIENT} --query "DETACH TABLE t_check_size SYNC"
${CLICKHOUSE_CLIENT} --query "ATTACH TABLE t_check_size"
echo -n "rows: "
${CLICKHOUSE_CLIENT} --query "SELECT count() FROM t_check_size"
echo -n "broken: "
${CLICKHOUSE_CLIENT} --query "
    SELECT count() FROM system.detached_parts
    WHERE database = currentDatabase() AND table = 't_check_size' AND startsWith(name, 'broken')"

echo "4. an optional per-part file, present and absent"
${CLICKHOUSE_CLIENT} --query "DROP TABLE IF EXISTS t_check_size SYNC"
${CLICKHOUSE_CLIENT} --query "
    CREATE TABLE t_check_size (id UInt32, d Date, s String)
    ENGINE = MergeTree ORDER BY id TTL d + INTERVAL 100 YEAR
    SETTINGS min_rows_for_wide_part = 1, min_bytes_for_wide_part = 1,
             min_bytes_for_full_part_storage = 0;"
${CLICKHOUSE_CLIENT} --query "INSERT INTO t_check_size SELECT number, today(), toString(number) FROM numbers(100)"
PATH_TTL=$(part_dir)
echo -n "ttl.txt present: "
if [ -f "${PATH_TTL}ttl.txt" ]; then echo 1; else echo 0; fi
echo -n "uuid.txt present: "
if [ -f "${PATH_TTL}uuid.txt" ]; then echo 1; else echo 0; fi
${CLICKHOUSE_CLIENT} --query "DETACH TABLE t_check_size SYNC"
${CLICKHOUSE_CLIENT} --query "ATTACH TABLE t_check_size"
echo -n "rows: "
${CLICKHOUSE_CLIENT} --query "SELECT count() FROM t_check_size"

echo "5. a torn data file detaches the part as broken on load"
recreate
PATH_TORN=$(part_dir)
${CLICKHOUSE_CLIENT} --query "DETACH TABLE t_check_size SYNC"
truncate -s 1 "${PATH_TORN}s.bin"
${CLICKHOUSE_CLIENT} --query "ATTACH TABLE t_check_size"
echo -n "active: "
${CLICKHOUSE_CLIENT} --query "
    SELECT count() FROM system.parts
    WHERE database = currentDatabase() AND table = 't_check_size' AND active"
echo -n "broken: "
${CLICKHOUSE_CLIENT} --query "
    SELECT count() FROM system.detached_parts
    WHERE database = currentDatabase() AND table = 't_check_size' AND startsWith(name, 'broken')"

${CLICKHOUSE_CLIENT} --query "DROP TABLE t_check_size SYNC"
