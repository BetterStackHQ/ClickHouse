#!/usr/bin/env bash
# Tags: no-fasttest, no-parallel, no-parallel-replicas
# Tag no-fasttest: requires S3 and Parquet
# Tag no-parallel: relies on an entry in the instance-wide query condition cache surviving from
# one query to the next; a parallel test dropping a path-keyed MergeTree table clears that cache
# Tag no-parallel-replicas: relies on query_log, which does not account other replicas

# The read that meets the overwrite is logged at warning level. The client mirrors server log
# messages to its stderr, where the test runner takes any output for a failure, so the messages
# are not asked for in the first place.
CLICKHOUSE_CLIENT_SERVER_LOGS_LEVEL=none

CUR_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../shell_config.sh
. "$CUR_DIR"/../shell_config.sh

auth="'test', 'testtest'"
# The object metadata cache outlives the query and the database, so a rerun against the same
# database must not reuse the object, nor the query ids the events are looked up by.
run_id="${CLICKHOUSE_TEST_UNIQUE_NAME}_$$"
url="http://localhost:11111/test/$run_id/row_groups.parquet"

# The query condition cache keys its entries by table UUID and ignores tables without one, which
# includes every table function; the reads go through a table so that they have it.
${CLICKHOUSE_CLIENT} -q "DROP TABLE IF EXISTS t_row_groups"
${CLICKHOUSE_CLIENT} -q "CREATE TABLE t_row_groups (n UInt64) ENGINE = S3('$url', $auth, 'Parquet')"

# Row groups of 100000 rows. The predicate matches nothing in the first, which the first read
# records in the query condition cache under the object's metadata; a later read under the same
# metadata takes the remaining row groups alone.
write()
{
    ${CLICKHOUSE_CLIENT} -q "INSERT INTO FUNCTION s3('$url', $auth, 'Parquet', 'n UInt64')
        SELECT number FROM numbers($1)
        SETTINGS s3_truncate_on_insert = 1, output_format_parquet_row_group_size = 100000"
}

# `s3_validate_etag_on_read = 0` sends no `If-Match`, so only the size each GET response reports can
# show that the object is no longer the one whose metadata was cached.
read_filtered()
{
    ${CLICKHOUSE_CLIENT} --query_id="$1" -q \
        "SELECT count() FROM t_row_groups WHERE n >= 150000
         SETTINGS use_object_metadata_cache = 1, s3_validate_etag_on_read = 0, use_query_condition_cache = 1,
                  enable_filesystem_cache = 0, log_queries = 1" 2>&1 | grep -oE '^[0-9]+$|S3_OBJECT_CHANGED_DURING_READ' | head -1
}

write 200000
echo "warm read: $(read_filtered "${run_id}_warm")"

# Rewritten longer. The row groups the read was going to take were chosen for the object as it
# was; taken from the object as it is now, they would count 50000 again - a wrong answer that looks
# exactly like the old right one. So the read is not repeated under the current metadata the way a
# read without such a selection is: it reports the overwrite. The read after it starts from the
# refreshed metadata, makes no selection for the old object, and counts the whole new one.
write 400000
echo "read after the rewrite: $(read_filtered "${run_id}_after_rewrite")"
echo "read after the refresh: $(read_filtered "${run_id}_after_refresh")"

${CLICKHOUSE_CLIENT} -q "SYSTEM FLUSH LOGS query_log"
# Neither read recovered: the first refused to, the second had nothing to recover from.
${CLICKHOUSE_CLIENT} -q "
    SELECT
        replaceOne(query_id, '${run_id}_', 'recovered: '),
        ProfileEvents['ObjectMetadataCacheRewriteRecovered']
    FROM system.query_log
    WHERE current_database = currentDatabase()
        AND query_id IN ('${run_id}_after_rewrite', '${run_id}_after_refresh')
        AND type IN ('QueryFinish', 'ExceptionWhileProcessing') AND event_date >= yesterday()
    ORDER BY query_id"

${CLICKHOUSE_CLIENT} -q "DROP TABLE t_row_groups"
