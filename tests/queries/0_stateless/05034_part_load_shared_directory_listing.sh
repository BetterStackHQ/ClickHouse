#!/usr/bin/env bash
# Tags: no-shared-merge-tree, no-object-storage
# The test creates files and directories inside the table's data directory, so it needs a local
# disk this process can write to, and the non-replicated engine whose mutations live on disk.

CUR_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# The test leaves a stale temporary part directory behind on purpose, and removing one is logged
# at warning level, which the client would otherwise print to stderr and fail the test with.
CLICKHOUSE_CLIENT_SERVER_LOGS_LEVEL=error
# shellcheck source=../shell_config.sh
. "$CUR_DIR"/../shell_config.sh

# Loading a table lists its data directory for parts and then, separately, for mutation entries.
# The two consumers now share one listing, so this pins what each of them must still see: a
# pending mutation is loaded, a leftover `tmp_mutation_` entry is removed, and stale temporary
# part directories are still cleaned up by the scan that runs after the load.

${CLICKHOUSE_CLIENT} --query "DROP TABLE IF EXISTS t_listing SYNC"

${CLICKHOUSE_CLIENT} --query "
    CREATE TABLE t_listing (id UInt32, v UInt32)
    ENGINE = MergeTree ORDER BY id
    SETTINGS min_bytes_for_full_part_storage = 0, temporary_directories_lifetime = 0;"

${CLICKHOUSE_CLIENT} --query "INSERT INTO t_listing SELECT number, 0 FROM numbers(100)"

TABLE_PATH=$(${CLICKHOUSE_CLIENT} --query "
    SELECT substring(path, 1, length(path) - length(name) - 1) FROM system.parts
    WHERE database = currentDatabase() AND table = 't_listing' AND active")

# Keep the mutation pending on disk so that loading it back is observable.
${CLICKHOUSE_CLIENT} --query "SYSTEM STOP MERGES t_listing"
${CLICKHOUSE_CLIENT} --query "ALTER TABLE t_listing UPDATE v = 1 WHERE 1" --mutations_sync 0

# A leftover from an interrupted mutation, and a stale temporary part directory. Both are named
# so that the parts scan skips them and the other two consumers must find them.
touch "${TABLE_PATH}tmp_mutation_9999999999.txt"
mkdir -p "${TABLE_PATH}tmp_insert_all_9999999999_9999999999_0"
touch -d '2020-01-01 00:00:00' "${TABLE_PATH}tmp_insert_all_9999999999_9999999999_0"

echo -n "mutation entry on disk before reload: "
ls "${TABLE_PATH}" | grep -c '^mutation_'

${CLICKHOUSE_CLIENT} --query "DETACH TABLE t_listing SYNC"
${CLICKHOUSE_CLIENT} --query "ATTACH TABLE t_listing"

echo -n "mutations loaded: "
${CLICKHOUSE_CLIENT} --query "
    SELECT count() FROM system.mutations
    WHERE database = currentDatabase() AND table = 't_listing'"

echo -n "mutation command loaded: "
${CLICKHOUSE_CLIENT} --query "
    SELECT count() FROM system.mutations
    WHERE database = currentDatabase() AND table = 't_listing' AND command LIKE '%v = 1%'"

# `loadMutations` is the only writer of this line, so it says that the entries came out of the
# shared listing and reached it, rather than the mutation appearing in `system.mutations` by some
# other route.
${CLICKHOUSE_CLIENT} --query "SYSTEM FLUSH LOGS text_log"
echo -n "mutation entry read by the mutation loader: "
${CLICKHOUSE_CLIENT} --query "
    SELECT count() > 0 FROM system.text_log
    WHERE event_date >= yesterday() AND event_time >= now() - 600
      AND logger_name LIKE '${CLICKHOUSE_DATABASE}.t_listing%'
      AND message LIKE 'Loading mutation: mutation%'
    SETTINGS max_rows_to_read = 0"

# Only `loadMutations` can account for this one: the entry is a regular file, and the temporary
# directory cleanup that also matches the `tmp_` prefix removes directories only - `isOldPartDirectory`
# answers `false` for anything that is not one.
echo -n "tmp_mutation_ entry removed: "
if [ -e "${TABLE_PATH}tmp_mutation_9999999999.txt" ]; then echo 0; else echo 1; fi

echo -n "stale tmp part directory removed: "
if [ -e "${TABLE_PATH}tmp_insert_all_9999999999_9999999999_0" ]; then echo 0; else echo 1; fi

# The mutation must still be applicable after being loaded back from disk.
${CLICKHOUSE_CLIENT} --query "SYSTEM START MERGES t_listing"
${CLICKHOUSE_CLIENT} --query "ALTER TABLE t_listing UPDATE v = v WHERE 1" --mutations_sync 2
echo -n "rows updated by the reloaded mutation: "
${CLICKHOUSE_CLIENT} --query "SELECT count() FROM t_listing WHERE v = 1"

${CLICKHOUSE_CLIENT} --query "DROP TABLE t_listing SYNC"
