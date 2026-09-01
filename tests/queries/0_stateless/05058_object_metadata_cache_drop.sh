#!/usr/bin/env bash
# Tags: no-fasttest, no-parallel, no-parallel-replicas
# Tag no-fasttest: requires S3
# Tag no-parallel: the statement under test empties the cache for the whole server, and the other
# object metadata cache tests assert that their entries are still there
# Tag no-parallel-replicas: relies on query_log, which does not account other replicas

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

read_object()
{
    ${CLICKHOUSE_CLIENT} --query_id="$1" -q \
        "SELECT sum(n) FROM s3('$object', $auth, 'CSV', 'n UInt64')
         SETTINGS use_object_metadata_cache = 1, log_queries = 1" > /dev/null
}

object="$prefix/drop.csv"
${CLICKHOUSE_CLIENT} -q "INSERT INTO FUNCTION s3('$object', $auth, 'CSV', 'n UInt64') SELECT number FROM numbers(10) SETTINGS s3_truncate_on_insert = 1"

# The entry the statement has to remove, and the proof that it was there.
read_object "${run_id}_1"
read_object "${run_id}_2"

${CLICKHOUSE_CLIENT} -q "SYSTEM DROP OBJECT METADATA CACHE"

# Without the entry the read fetches the metadata again, as the very first read did.
read_object "${run_id}_3"

${CLICKHOUSE_CLIENT} -q "SYSTEM FLUSH LOGS query_log"
report 'first read' "${run_id}_1"
report 'second read' "${run_id}_2"
report 'read after the cache was dropped' "${run_id}_3"

# That the statement is a no-op on a server whose cache was never created is not assertable here:
# this server has just used the cache, and any other test may have used it before. What the
# statement does then is a null check on the cache, covered by reading the code.

# The statement is guarded by its own privilege.
user="user_05058_$CLICKHOUSE_DATABASE"
${CLICKHOUSE_CLIENT} -q "DROP USER IF EXISTS $user"
${CLICKHOUSE_CLIENT} -q "CREATE USER $user IDENTIFIED WITH no_password"

echo -n 'without the grant: '
${CLICKHOUSE_CLIENT} --user "$user" -q "SYSTEM DROP OBJECT METADATA CACHE" 2>&1 \
    | grep -oF "ACCESS_DENIED" | head -n 1

${CLICKHOUSE_CLIENT} -q "GRANT SYSTEM DROP OBJECT METADATA CACHE ON *.* TO $user"
echo -n 'with the grant: '
${CLICKHOUSE_CLIENT} --user "$user" -q "SYSTEM DROP OBJECT METADATA CACHE" && echo 'ok'

${CLICKHOUSE_CLIENT} -q "DROP USER $user"
