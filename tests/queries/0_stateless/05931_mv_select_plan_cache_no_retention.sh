#!/usr/bin/env bash
# Tags: no-parallel, no-fasttest, no-asan, no-tsan, no-msan, no-ubsan
# Tag no-parallel: reads the server-wide MemoryTracking metric.
# Tag no-fasttest: pushes a ~200 MiB block.
# Sanitizer tags: the check relies on jemalloc accounting.

# A materialized view select plan cache entry must not retain anything of the insert that
# captured it. Two routes from an entry to the inserted block are covered: the plan resources
# (interpreter context, storage holders, table locks) of the capturing query, which a skeleton
# cloned with them would carry; and function objects inside the cached actions that keep the
# context they were created with (`negate`, `abs` and the other unary arithmetic functions do),
# through which the `StorageValues` standing in for the block stays reachable.

CUR_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../shell_config.sh
. "$CUR_DIR"/../shell_config.sh

ROWS=200000

$CLICKHOUSE_CLIENT -n -q "
    DROP TABLE IF EXISTS t_05931_mv_plain;
    DROP TABLE IF EXISTS t_05931_mv_context_function;
    DROP TABLE IF EXISTS t_05931_src;
    DROP TABLE IF EXISTS t_05931_dst;
    CREATE TABLE t_05931_src (k UInt64, blob String) ENGINE = MergeTree ORDER BY k;
    CREATE TABLE t_05931_dst (g UInt64, c UInt64) ENGINE = MergeTree ORDER BY g;
    CREATE MATERIALIZED VIEW t_05931_mv_plain TO t_05931_dst AS
        SELECT k % 8 AS g, count() AS c FROM t_05931_src GROUP BY g;
    CREATE MATERIALIZED VIEW t_05931_mv_context_function TO t_05931_dst AS
        SELECT toUInt64(abs(negate(toInt64(k)))) % 8 AS g, count() AS c FROM t_05931_src GROUP BY g;
"

memory_tracking() {
    sleep 1
    $CLICKHOUSE_CLIENT -q "SYSTEM JEMALLOC PURGE"
    $CLICKHOUSE_CLIENT -q "SELECT value FROM system.metrics WHERE metric = 'MemoryTracking'"
}
cache_entries() {
    $CLICKHOUSE_CLIENT -q "SELECT value FROM system.metrics WHERE metric = 'MaterializedViewSelectPlanCacheEntries'"
}

MEM_BEFORE=$(memory_tracking)
ENTRIES_BEFORE=$(cache_entries)

# One single block of ~200 MiB through both views, once per analyzer (the insert's setting chooses
# the interpreter of the view selects), with the cache on, so each view captures one entry per run.
for analyzer in 1 0; do
    $CLICKHOUSE_CLIENT -q "
        INSERT INTO t_05931_src SELECT number, repeat('x', 1024) FROM numbers($ROWS)
        SETTINGS use_materialized_view_select_plan_cache = 1, allow_experimental_analyzer = $analyzer,
                 max_insert_block_size = $ROWS, min_insert_block_size_rows = $ROWS, min_insert_block_size_bytes = 0,
                 max_threads = 1"
done

MEM_AFTER=$(memory_tracking)
ENTRIES_AFTER=$(cache_entries)

$CLICKHOUSE_CLIENT -q "SELECT count() FROM t_05931_dst"
echo "entries captured: $((ENTRIES_AFTER - ENTRIES_BEFORE))"

# Each block was ~200 MiB; a retained block would show as most of it. Allow for parts, marks and noise.
RETAINED=$(( (MEM_AFTER - MEM_BEFORE) / 1048576 ))
if [ "$RETAINED" -lt 64 ]; then
    echo "retained after capture: ok"
else
    echo "retained after capture: ${RETAINED} MiB"
fi

$CLICKHOUSE_CLIENT -n -q "
    DROP TABLE t_05931_mv_plain;
    DROP TABLE t_05931_mv_context_function;
    DROP TABLE t_05931_src;
    DROP TABLE t_05931_dst;
"
