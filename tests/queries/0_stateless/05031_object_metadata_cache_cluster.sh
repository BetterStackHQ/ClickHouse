#!/usr/bin/env bash
# Tags: no-fasttest, no-parallel-replicas
# Tag no-fasttest: requires S3
# Tag no-parallel-replicas: relies on query_log, which does not account other replicas

# `s3Cluster` splits the work without the object metadata: the initiator's iterator runs with
# `skip_object_metadata`, so the HEAD request is issued by the worker in `createReader`. That is a
# different call site from the one a plain `s3` read uses, and it must consult the cache too.

CUR_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../shell_config.sh
. "$CUR_DIR"/../shell_config.sh

auth="'test', 'testtest'"
# The cache outlives the query and the database, so a rerun must not reuse objects or query ids.
run_id="${CLICKHOUSE_TEST_UNIQUE_NAME}_$$"
object="http://localhost:11111/test/$run_id/cluster.csv"

# The cluster runs every worker in this same process, so how many of them open the object, and in
# what order, is a scheduling detail. Only assert what the cache guarantees: the first read finds
# nothing cached and fetches, the second issues no metadata request at all.
report_filled()
{
    ${CLICKHOUSE_CLIENT} -q "
        SELECT
            '$1',
            ProfileEvents['S3HeadObject'] > 0,
            ProfileEvents['ObjectMetadataCacheMisses'] > 0
        FROM system.query_log
        WHERE current_database = currentDatabase() AND query_id = '$2'
            AND type = 'QueryFinish' AND event_date >= yesterday()
        ORDER BY event_time_microseconds DESC LIMIT 1"
}

report_served()
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

${CLICKHOUSE_CLIENT} -q "INSERT INTO FUNCTION s3('$object', $auth, 'CSV', 'n UInt64') SELECT number FROM numbers(10) SETTINGS s3_truncate_on_insert = 1"

# The explicit structure keeps schema inference from reading the object before the cluster read.
${CLICKHOUSE_CLIENT} --query_id="${run_id}_cluster_1" -q \
    "SELECT sum(n) FROM s3Cluster('test_cluster_two_shards_localhost', '$object', $auth, 'CSV', 'n UInt64') SETTINGS use_object_metadata_cache = 1, log_queries = 1"
${CLICKHOUSE_CLIENT} --query_id="${run_id}_cluster_2" -q \
    "SELECT sum(n) FROM s3Cluster('test_cluster_two_shards_localhost', '$object', $auth, 'CSV', 'n UInt64') SETTINGS use_object_metadata_cache = 1, log_queries = 1"

${CLICKHOUSE_CLIENT} -q "SYSTEM FLUSH LOGS query_log"
report_filled 'cluster, first read' "${run_id}_cluster_1"
report_served 'cluster, second read' "${run_id}_cluster_2"
