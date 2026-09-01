#!/usr/bin/env bash
# Tags: no-fasttest, no-parallel-replicas
# Tag no-fasttest: requires S3
# Tag no-parallel-replicas: relies on query_log, which does not account other replicas

CUR_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../shell_config.sh
. "$CUR_DIR"/../shell_config.sh

auth="'test', 'testtest'"
# The object metadata cache outlives the query and the database, so a rerun against the same
# database must not reuse the objects, nor the query ids the events are looked up by.
run_id="${CLICKHOUSE_TEST_UNIQUE_NAME}_$$"
prefix="http://localhost:11111/test/$run_id"

# The filesystem cache would serve the bytes of a deleted object and hide every property tested
# here, so all reads below bypass it.
settings="use_object_metadata_cache = 1, enable_filesystem_cache = 0"

# An object is deleted by truncating a table over its key.
delete_object()
{
    ${CLICKHOUSE_CLIENT} -q "
        DROP TABLE IF EXISTS deleter;
        CREATE TABLE deleter (n UInt64) ENGINE = S3('$1', 'test', 'testtest', 'CSV');
        TRUNCATE TABLE deleter;
        DROP TABLE deleter;"
}

write_object()
{
    ${CLICKHOUSE_CLIENT} -q \
        "INSERT INTO FUNCTION s3('$1', $auth, 'CSV', 'n UInt64') SELECT number FROM numbers($2) SETTINGS s3_truncate_on_insert = 1"
}

# The object of a cached entry can be deleted between two reads: entries describe objects that are
# immutable, not objects that are there forever. A read that ignores non-existent files must
# therefore still ignore this one, exactly as it ignores a key that was already gone when the
# metadata was fetched, instead of failing on the reader's request for the deleted object.
ignored="$prefix/ignored.csv"
write_object "$ignored" 10
${CLICKHOUSE_CLIENT} -q "SELECT sum(n) FROM s3('$ignored', $auth, 'CSV', 'n UInt64') SETTINGS $settings"
delete_object "$ignored"

${CLICKHOUSE_CLIENT} --query_id="${run_id}_ignored" -q \
    "SELECT count(), sum(n) FROM s3('$ignored', $auth, 'CSV', 'n UInt64') SETTINGS $settings, s3_ignore_file_doesnt_exist = 1, log_queries = 1"

# The stale entry must be gone rather than merely unused, so that the key is read again - here
# after it has been written a second time, with different contents.
write_object "$ignored" 20
${CLICKHOUSE_CLIENT} -q "SELECT count(), sum(n) FROM s3('$ignored', $auth, 'CSV', 'n UInt64') SETTINGS $settings"

${CLICKHOUSE_CLIENT} -q "SYSTEM FLUSH LOGS query_log"
${CLICKHOUSE_CLIENT} -q "
    SELECT
        'ignored read dropped the entry',
        ProfileEvents['ObjectMetadataCacheInvalidations'] > 0
    FROM system.query_log
    WHERE current_database = currentDatabase() AND query_id = '${run_id}_ignored'
        AND type = 'QueryFinish' AND event_date >= yesterday()
    ORDER BY event_time_microseconds DESC LIMIT 1"

# A query that does not ignore non-existent files still fails on the deleted object, and it fails
# with a real error of the request that ran into the absence: the metadata request when the cache
# was not consulted, the read itself when a cache hit stood in for that request. Either way the
# object is reported as missing, and never as changed - which is what the read alone concludes on
# a store that answers a conditional read of a deleted object with a failed precondition.
uncached="$prefix/uncached.csv"
cached="$prefix/cached.csv"
write_object "$uncached" 10
write_object "$cached" 10
${CLICKHOUSE_CLIENT} -q "SELECT sum(n) FROM s3('$cached', $auth, 'CSV', 'n UInt64') SETTINGS $settings"
delete_object "$uncached"
delete_object "$cached"

error_of() { grep -m 1 -F 'DB::Exception'; }

uncached_error=$(${CLICKHOUSE_CLIENT} -q \
    "SELECT count(), sum(n) FROM s3('$uncached', $auth, 'CSV', 'n UInt64') SETTINGS use_object_metadata_cache = 0, enable_filesystem_cache = 0" 2>&1 | error_of)
cached_error=$(${CLICKHOUSE_CLIENT} -q \
    "SELECT count(), sum(n) FROM s3('$cached', $auth, 'CSV', 'n UInt64') SETTINGS $settings" 2>&1 | error_of)

echo "error code without the cache: $(echo "$uncached_error" | grep -o 'Code: [0-9]*' | head -n 1)"
case "$uncached_error" in
    *"Failed to get object info"*"404"*) echo "without the cache the metadata request reports the missing object: 1" ;;
    *) echo "without the cache the metadata request reports the missing object: 0 ($uncached_error)" ;;
esac
case "$cached_error" in
    *S3_OBJECT_CHANGED_DURING_READ*)
        echo "with the cache the object is reported as missing, not as changed: 0 ($cached_error)" ;;
    *"specified key does not exist"* | *"Failed to get object info"*"404"*)
        echo "with the cache the object is reported as missing, not as changed: 1" ;;
    *) echo "with the cache the object is reported as missing, not as changed: 0 ($cached_error)" ;;
esac

# A glob is listing-driven, so a deleted member is simply not listed and the read is unaffected.
write_object "$prefix/glob_1.csv" 10
write_object "$prefix/glob_2.csv" 20
${CLICKHOUSE_CLIENT} -q "SELECT count(), sum(n) FROM s3('$prefix/glob_*.csv', $auth, 'CSV', 'n UInt64') SETTINGS $settings"
delete_object "$prefix/glob_1.csv"
${CLICKHOUSE_CLIENT} -q "SELECT count(), sum(n) FROM s3('$prefix/glob_*.csv', $auth, 'CSV', 'n UInt64') SETTINGS $settings"

# There is no arm for an object deleted in the middle of reading it, where the rows already
# returned rule out both skipping the file and reporting the absence, and the read error stands.
# Reaching that state needs a read that is long enough to delete the object underneath it, which
# no amount of data makes reliable: the reader may have the whole object buffered already.
