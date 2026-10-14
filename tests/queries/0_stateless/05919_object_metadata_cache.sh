#!/usr/bin/env bash
# Tags: no-fasttest, no-parallel-replicas
# Tag no-fasttest: requires S3
# Tag no-parallel-replicas: relies on query_log, which does not account other replicas

# Reading an object that was overwritten in place is what this test does, and the read that meets
# the overwrite is logged at error level even where it goes on to recover. The client mirrors
# server log messages to its stderr, where the test runner takes any output for a failure, so the
# messages are not asked for in the first place.
CLICKHOUSE_CLIENT_SERVER_LOGS_LEVEL=none

CUR_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../shell_config.sh
. "$CUR_DIR"/../shell_config.sh

auth="'test', 'testtest'"
# The object metadata cache outlives the query and the database, so a rerun against the same
# database must not reuse the objects, nor the query ids the events are looked up by.
run_id="${CLICKHOUSE_TEST_UNIQUE_NAME}_$$"
prefix="http://localhost:11111/test/$run_id"

# Report how the query with the given id obtained the object metadata: whether it issued a HEAD
# request, and whether it hit or missed the object metadata cache.
report()
{
    ${CLICKHOUSE_CLIENT} -q "
        SELECT
            '$1',
            ProfileEvents['S3HeadObject'] > 0,
            ProfileEvents['ObjectMetadataCacheHits'] > 0,
            ProfileEvents['ObjectMetadataCacheMisses'] > 0
        FROM system.query_log
        WHERE current_database = currentDatabase() AND query_id = '$2'
            AND type = 'QueryFinish' AND event_date >= yesterday()
        ORDER BY event_time_microseconds DESC LIMIT 1"
}

# The second read of the same object must be served from the cache, without a HEAD request.
hit="$prefix/hit.csv"
${CLICKHOUSE_CLIENT} -q "INSERT INTO FUNCTION s3('$hit', $auth, 'CSV', 'n UInt64') SELECT number FROM numbers(10) SETTINGS s3_truncate_on_insert = 1"

${CLICKHOUSE_CLIENT} --query_id="${run_id}_hit_1" -q \
    "SELECT sum(n) FROM s3('$hit', $auth, 'CSV', 'n UInt64') SETTINGS use_object_metadata_cache = 1, log_queries = 1"
${CLICKHOUSE_CLIENT} --query_id="${run_id}_hit_2" -q \
    "SELECT sum(n) FROM s3('$hit', $auth, 'CSV', 'n UInt64') SETTINGS use_object_metadata_cache = 1, log_queries = 1"

# With the setting at its default the cache is neither consulted nor filled, and both reads HEAD.
off="$prefix/off.csv"
${CLICKHOUSE_CLIENT} -q "INSERT INTO FUNCTION s3('$off', $auth, 'CSV', 'n UInt64') SELECT number FROM numbers(10) SETTINGS s3_truncate_on_insert = 1"

${CLICKHOUSE_CLIENT} --query_id="${run_id}_off_1" -q \
    "SELECT sum(n) FROM s3('$off', $auth, 'CSV', 'n UInt64') SETTINGS log_queries = 1"
${CLICKHOUSE_CLIENT} --query_id="${run_id}_off_2" -q \
    "SELECT sum(n) FROM s3('$off', $auth, 'CSV', 'n UInt64') SETTINGS log_queries = 1"

${CLICKHOUSE_CLIENT} -q "SYSTEM FLUSH LOGS query_log"
report 'cache on, first read' "${run_id}_hit_1"
report 'cache on, second read' "${run_id}_hit_2"
report 'cache off, first read' "${run_id}_off_1"
report 'cache off, second read' "${run_id}_off_2"

# An object overwritten in place breaks the immutability contract of the setting. The read must
# never return data stitched together from two generations: having emitted nothing yet, it drops
# the stale entry and reads the object again under its current metadata.
overwritten="$prefix/overwritten.csv"
${CLICKHOUSE_CLIENT} -q "INSERT INTO FUNCTION s3('$overwritten', $auth, 'CSV', 'n UInt64') SELECT number FROM numbers(10) SETTINGS s3_truncate_on_insert = 1"
${CLICKHOUSE_CLIENT} -q "SELECT sum(n) FROM s3('$overwritten', $auth, 'CSV', 'n UInt64') SETTINGS use_object_metadata_cache = 1"

${CLICKHOUSE_CLIENT} -q "INSERT INTO FUNCTION s3('$overwritten', $auth, 'CSV', 'n UInt64') SELECT number FROM numbers(200) SETTINGS s3_truncate_on_insert = 1"
${CLICKHOUSE_CLIENT} --query_id="${run_id}_recovered" -q \
    "SELECT sum(n) FROM s3('$overwritten', $auth, 'CSV', 'n UInt64') SETTINGS use_object_metadata_cache = 1, s3_validate_etag_on_read = 1, log_queries = 1"

${CLICKHOUSE_CLIENT} --query_id="${run_id}_overwritten" -q \
    "SELECT sum(n) FROM s3('$overwritten', $auth, 'CSV', 'n UInt64') SETTINGS use_object_metadata_cache = 1, log_queries = 1"

# The absence of an object is never cached: a key that appears after a failed read is readable.
appearing="$prefix/appearing.csv"
${CLICKHOUSE_CLIENT} -q "SELECT sum(n) FROM s3('$appearing', $auth, 'CSV', 'n UInt64') SETTINGS use_object_metadata_cache = 1" 2>&1 \
    | grep -oF "S3_ERROR" | head -n 1

${CLICKHOUSE_CLIENT} -q "INSERT INTO FUNCTION s3('$appearing', $auth, 'CSV', 'n UInt64') SELECT number FROM numbers(10) SETTINGS s3_truncate_on_insert = 1"
${CLICKHOUSE_CLIENT} -q "SELECT sum(n) FROM s3('$appearing', $auth, 'CSV', 'n UInt64') SETTINGS use_object_metadata_cache = 1"

${CLICKHOUSE_CLIENT} -q "SYSTEM FLUSH LOGS query_log"
# The recovering read drops the stale entry and remembers what it found instead, so it is counted
# as a recovery - the violation stays visible - and the read after it needs no request of its own.
${CLICKHOUSE_CLIENT} -q "
    SELECT
        'overwrite recovered',
        ProfileEvents['ObjectMetadataCacheInvalidations'] > 0,
        ProfileEvents['ObjectMetadataCacheRewriteRecovered'] > 0
    FROM system.query_log
    WHERE current_database = currentDatabase() AND query_id = '${run_id}_recovered'
        AND type = 'QueryFinish' AND event_date >= yesterday()
    ORDER BY event_time_microseconds DESC LIMIT 1"
report 'read after overwrite' "${run_id}_overwritten"
