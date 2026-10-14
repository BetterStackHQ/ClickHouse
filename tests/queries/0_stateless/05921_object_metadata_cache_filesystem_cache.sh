#!/usr/bin/env bash
# Tags: no-fasttest, no-random-settings, no-parallel-replicas
# Tag no-fasttest: requires S3
# Tag no-random-settings: deterministic filesystem cache behaviour
# Tag no-parallel-replicas: relies on query_log, which does not account other replicas

# The filesystem cache is keyed by the object path and its ETag. Metadata taken from the object
# metadata cache must reproduce exactly the key a fresh HEAD request produces, otherwise enabling
# the metadata cache would silently orphan the cached data and re-download every object.

CUR_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../shell_config.sh
. "$CUR_DIR"/../shell_config.sh

auth="'test', 'testtest'"
object="http://localhost:11111/test/${CLICKHOUSE_TEST_UNIQUE_NAME}_$$/cached.csv"
# The cache named here is defined in the stateless test server config.
cache_settings="filesystem_cache_name = 'cache_for_readbigat', enable_filesystem_cache = 1"

# Report whether the read was served by the filesystem cache rather than re-downloaded, and
# whether it needed a HEAD request of its own.
report()
{
    ${CLICKHOUSE_CLIENT} -q "
        SELECT
            '$1',
            ProfileEvents['CachedReadBufferReadFromCacheBytes'] > 0,
            ProfileEvents['CachedReadBufferReadFromSourceBytes'] > 0,
            ProfileEvents['S3HeadObject'] > 0
        FROM system.query_log
        WHERE current_database = currentDatabase() AND query_id = '$2'
            AND type = 'QueryFinish' AND event_date >= yesterday()
        ORDER BY event_time_microseconds DESC LIMIT 1"
}

${CLICKHOUSE_CLIENT} -q "INSERT INTO FUNCTION s3('$object', $auth, 'CSV', 'n UInt64') SELECT number FROM numbers(100000) SETTINGS s3_truncate_on_insert = 1"

# Cold read with the metadata cache off: the data is downloaded and the filesystem cache filled.
${CLICKHOUSE_CLIENT} --query_id="${CLICKHOUSE_TEST_UNIQUE_NAME}_cold" -q \
    "SELECT sum(n) FROM s3('$object', $auth, 'CSV', 'n UInt64') FORMAT Null SETTINGS $cache_settings, log_queries = 1"

# Warm read, still with the metadata cache off: the baseline that the data is cached at all.
${CLICKHOUSE_CLIENT} --query_id="${CLICKHOUSE_TEST_UNIQUE_NAME}_warm_off" -q \
    "SELECT sum(n) FROM s3('$object', $auth, 'CSV', 'n UInt64') FORMAT Null SETTINGS $cache_settings, log_queries = 1"

# First read with the metadata cache on: still a HEAD request (nothing cached yet), and the
# filesystem cache entries written by the reads above must still be found.
${CLICKHOUSE_CLIENT} --query_id="${CLICKHOUSE_TEST_UNIQUE_NAME}_warm_miss" -q \
    "SELECT sum(n) FROM s3('$object', $auth, 'CSV', 'n UInt64') FORMAT Null SETTINGS $cache_settings, use_object_metadata_cache = 1, log_queries = 1"

# The decisive one: metadata comes from the cache, so no HEAD request is issued, and the
# filesystem cache must still serve the same entries rather than download the object again.
${CLICKHOUSE_CLIENT} --query_id="${CLICKHOUSE_TEST_UNIQUE_NAME}_warm_hit" -q \
    "SELECT sum(n) FROM s3('$object', $auth, 'CSV', 'n UInt64') FORMAT Null SETTINGS $cache_settings, use_object_metadata_cache = 1, log_queries = 1"

${CLICKHOUSE_CLIENT} -q "SYSTEM FLUSH LOGS query_log"
report 'cold read, metadata cache off' "${CLICKHOUSE_TEST_UNIQUE_NAME}_cold"
report 'warm read, metadata cache off' "${CLICKHOUSE_TEST_UNIQUE_NAME}_warm_off"
report 'warm read, metadata cache miss' "${CLICKHOUSE_TEST_UNIQUE_NAME}_warm_miss"
report 'warm read, metadata cache hit' "${CLICKHOUSE_TEST_UNIQUE_NAME}_warm_hit"
