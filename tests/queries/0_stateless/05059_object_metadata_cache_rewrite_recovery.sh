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

# `s3_validate_etag_on_read = 0` sends no `If-Match`, so nothing rejects the read up front and only
# the size and ETag each GET response reports can show that the object is no longer the one whose
# metadata was cached.
read_unpinned()
{
    ${CLICKHOUSE_CLIENT} --query_id="$1" -q \
        "SELECT sum(n) FROM s3('$2', $auth, 'CSV', 'n UInt64')
         SETTINGS use_object_metadata_cache = 1, s3_validate_etag_on_read = 0,
                  enable_filesystem_cache = 0, log_queries = 1"
}

write()
{
    ${CLICKHOUSE_CLIENT} -q "INSERT INTO FUNCTION s3('$1', $auth, 'CSV', 'n UInt64')
        SELECT number FROM numbers($2) SETTINGS s3_truncate_on_insert = 1"
}

recovered()
{
    ${CLICKHOUSE_CLIENT} -q "
        SELECT
            '$1',
            ProfileEvents['ObjectMetadataCacheRewriteRecovered'] > 0
        FROM system.query_log
        WHERE current_database = currentDatabase() AND query_id = '$2'
            AND type = 'QueryFinish' AND event_date >= yesterday()
        ORDER BY event_time_microseconds DESC LIMIT 1"
}

# An object rewritten SHORTER is the case that used to pass unnoticed: the reader asked for the
# byte range the cached size described, the shorter object ended before it, and an early end is
# what the end of a file looks like. The sum must be the new object's, never a part of the old one.
shrunk="$prefix/shrunk.csv"
write "$shrunk" 200
read_unpinned "${run_id}_shrunk_warm" "$shrunk"
write "$shrunk" 10
read_unpinned "${run_id}_shrunk_read" "$shrunk"
read_unpinned "${run_id}_shrunk_again" "$shrunk"

# An object rewritten longer, for which the ETag alone would have been enough.
grown="$prefix/grown.csv"
write "$grown" 10
read_unpinned "${run_id}_grown_warm" "$grown"
write "$grown" 200
read_unpinned "${run_id}_grown_read" "$grown"

# Two cases are deliberately absent, neither being deterministically constructible from a test:
# a divergence found after rows have already been emitted, and a second divergence on the re-read.
# Both need a writer landing inside a single read. The bound on the recovery is structural rather
# than timed - a re-read carries the metadata this query fetched, not the cache's, so nothing about
# it is treated as a stale entry again.

${CLICKHOUSE_CLIENT} -q "SYSTEM FLUSH LOGS query_log"
# Only the reads that met a rewritten object recover; the read after one has fresh metadata and
# behaves like any other cache hit.
recovered 'shrunk, warming read' "${run_id}_shrunk_warm"
recovered 'shrunk, read after the rewrite' "${run_id}_shrunk_read"
recovered 'shrunk, read after the recovery' "${run_id}_shrunk_again"
recovered 'grown, read after the rewrite' "${run_id}_grown_read"
