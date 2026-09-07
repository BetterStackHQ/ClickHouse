#!/usr/bin/env bash
# Tags: no-parallel, no-fasttest
# Tag no-parallel: asserts on wall-clock durations of flushes and of the waiting client queries.
# Tag no-fasttest: timing-based, several seconds per scenario.

# The flush of an asynchronous insert must honour the timeouts of the queries waiting for it,
# counted from when each was queued (`async_insert_flush_timeout_from_queries`), and the client
# query waiting for the flush must be interruptible by KILL QUERY and its own `max_execution_time`.

CUR_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../shell_config.sh
. "$CUR_DIR"/../shell_config.sh

set -e

Q="05136_${CLICKHOUSE_DATABASE}"
TMP_OUT="${CLICKHOUSE_TMP}/05136_$$"

function cleanup()
{
    wait 2>/dev/null ||:
    rm -f "${TMP_OUT}".*
}
trap cleanup EXIT

# A three-deep chain whose last view sleeps 1 s per row: with 6 rows a flush that runs to
# completion takes ~6 s, and `sleepEachRow` re-checks the query's time limit every second, so a
# killed flush stops within ~1 s of its deadline. Every deadline below is at least 3x shorter
# than the sleep, and every "fast" bound leaves at least 1 s of margin over the expected duration
# while staying below the duration of the behaviour it rules out.
$CLICKHOUSE_CLIENT -q "
    DROP TABLE IF EXISTS mv3_deadline;
    DROP TABLE IF EXISTS mv2_deadline;
    DROP TABLE IF EXISTS mv1_deadline;
    DROP TABLE IF EXISTS t3_deadline;
    DROP TABLE IF EXISTS t2_deadline;
    DROP TABLE IF EXISTS t1_deadline;
    DROP TABLE IF EXISTS src_deadline;
    DROP TABLE IF EXISTS plain_deadline;
    CREATE TABLE src_deadline (id UInt64, n UInt8) ENGINE = MergeTree ORDER BY id;
    CREATE TABLE t1_deadline (id UInt64, n UInt8) ENGINE = MergeTree ORDER BY id;
    CREATE TABLE t2_deadline (id UInt64, n UInt8) ENGINE = MergeTree ORDER BY id;
    CREATE TABLE t3_deadline (id UInt64, n UInt8, s UInt8) ENGINE = MergeTree ORDER BY id;
    CREATE TABLE plain_deadline (id UInt64, n UInt8) ENGINE = MergeTree ORDER BY id;
    CREATE MATERIALIZED VIEW mv1_deadline TO t1_deadline AS SELECT id, n FROM src_deadline;
    CREATE MATERIALIZED VIEW mv2_deadline TO t2_deadline AS SELECT id, n FROM t1_deadline;
    CREATE MATERIALIZED VIEW mv3_deadline TO t3_deadline AS SELECT id, n, sleepEachRow(1) AS s FROM t2_deadline;
"

COMMON="async_insert=1, async_insert_use_adaptive_busy_timeout=0, function_sleep_max_microseconds_per_block=60000000"

# One insert of six rows tagged with id=$1 into table $2, under the extra settings $3, as query
# id $4. Prints the error class the client saw, or `none`.
function run_insert()
{
    local id=$1 table=$2 settings=$3 qid=$4 err
    err=$($CLICKHOUSE_CLIENT --query_id="$qid" -q "INSERT INTO $table SETTINGS $COMMON, $settings VALUES ($id,1),($id,2),($id,3),($id,4),($id,5),($id,6)" 2>&1 \
        | grep -oE 'TIMEOUT_EXCEEDED|QUERY_WAS_CANCELLED' | head -1) || true
    echo "${err:-none}"
}

# The same over the native protocol with the data outside the query text, so that the queue
# receives preprocessed blocks instead of text to parse.
function run_insert_blocks()
{
    local id=$1 table=$2 settings=$3 qid=$4 err
    err=$(printf '%s\t1\n%s\t2\n%s\t3\n%s\t4\n%s\t5\n%s\t6\n' "$id" "$id" "$id" "$id" "$id" "$id" \
        | $CLICKHOUSE_CLIENT --query_id="$qid" -q "INSERT INTO $table SETTINGS $COMMON, $settings FORMAT TSV" 2>&1 \
        | grep -oE 'TIMEOUT_EXCEEDED|QUERY_WAS_CANCELLED' | head -1) || true
    echo "${err:-none}"
}

# Wait until query_log has the final row of query $1 (its flush ends before the row is written,
# and the logs are flushed on demand). Prints nothing; the callers read the row afterwards.
function wait_query_log()
{
    local qid=$1
    for _ in $(seq 1 600); do
        $CLICKHOUSE_CLIENT -q "SYSTEM FLUSH LOGS"
        if [ "$($CLICKHOUSE_CLIENT -q "SELECT count() FROM system.query_log WHERE query_id = '$qid' AND type != 'QueryStart' AND event_date >= yesterday()")" != "0" ]; then
            return
        fi
        sleep 0.1
    done
    echo "no final query_log row for $qid" >&2
}

# The flush's query id for a client query, from asynchronous_insert_log (written when the flush
# ends, successfully or not; waits for it and then for the flush's own query_log row).
function flush_id_of()
{
    local qid=$1 fid
    for _ in $(seq 1 600); do
        $CLICKHOUSE_CLIENT -q "SYSTEM FLUSH LOGS"
        fid=$($CLICKHOUSE_CLIENT -q "SELECT flush_query_id FROM system.asynchronous_insert_log WHERE query_id = '$qid' AND event_date >= yesterday() ORDER BY event_time_microseconds DESC LIMIT 1")
        if [ -n "$fid" ]; then
            wait_query_log "$fid"
            echo "$fid"
            return
        fi
        sleep 0.1
    done
    echo "no asynchronous_insert_log row for $qid" >&2
}

# type, exception code and whether the query ran for less than $2 ms.
function outcome()
{
    local qid=$1 fast_below_ms=$2
    wait_query_log "$qid"
    $CLICKHOUSE_CLIENT -q "
        SELECT type, exception_code, if(query_duration_ms < $fast_below_ms, 'fast', 'slow')
        FROM system.query_log
        WHERE query_id = '$qid' AND type != 'QueryStart' AND event_date >= yesterday()
        ORDER BY event_time_microseconds DESC LIMIT 1 FORMAT TSV"
}

function flush_rows()
{
    wait_query_log "$1"
    $CLICKHOUSE_CLIENT -q "SELECT type, written_rows FROM system.query_log WHERE query_id = '$1' AND type != 'QueryStart' AND event_date >= yesterday() ORDER BY event_time_microseconds DESC LIMIT 1 FORMAT TSV"
}

function async_log_status()
{
    $CLICKHOUSE_CLIENT -q "SELECT status, exception LIKE '%TIMEOUT_EXCEEDED%' FROM system.asynchronous_insert_log WHERE query_id = '$1' AND event_date >= yesterday() ORDER BY event_time_microseconds DESC LIMIT 1 FORMAT TSV"
}

function rows_with_id()
{
    $CLICKHOUSE_CLIENT -q "SELECT count() FROM $1 WHERE id = $2"
}

function expired_counter()
{
    $CLICKHOUSE_CLIENT -q "SELECT max(value) FROM (SELECT value FROM system.events WHERE event = 'AsyncInsertEntriesExpiredBeforeFlush' UNION ALL SELECT 0)"
}

echo "-- 1. only wait_for_async_insert_timeout=2: the flush inherits it and is killed at ~2 s"
echo "client error: $(run_insert 1 src_deadline "wait_for_async_insert=1, wait_for_async_insert_timeout=2, async_insert_busy_timeout_min_ms=100, async_insert_busy_timeout_max_ms=100" "${Q}_1")"
echo "client: $(outcome "${Q}_1" 4000)"
F1=$(flush_id_of "${Q}_1")
echo "flush: $(outcome "$F1" 4000)"
echo "async_insert_log: $(async_log_status "${Q}_1")"
echo "rows at the end of the chain: $(rows_with_id t3_deadline 1)"

echo "-- 2. max_execution_time=5 queued for 4 s: the flush gets the remaining ~1 s, not 5 s"
echo "client error: $(run_insert 2 src_deadline "wait_for_async_insert=1, max_execution_time=5, async_insert_busy_timeout_min_ms=4000, async_insert_busy_timeout_max_ms=4000" "${Q}_2")"
echo "client: $(outcome "${Q}_2" 6500)"
F2=$(flush_id_of "${Q}_2")
echo "flush: $(outcome "$F2" 3500)"

echo "-- 3a. max_execution_time=1 queued for 3 s: expired before the flush; the waiting client is released at 1 s"
BEFORE=$(expired_counter)
echo "client error: $(run_insert 3 src_deadline "wait_for_async_insert=1, max_execution_time=1, async_insert_busy_timeout_min_ms=3000, async_insert_busy_timeout_max_ms=3000" "${Q}_3a")"
echo "client: $(outcome "${Q}_3a" 2500)"
F3A=$(flush_id_of "${Q}_3a")
echo "async_insert_log: $(async_log_status "${Q}_3a")"
echo "flush: $(flush_rows "$F3A")"

echo "-- 3b. the same without waiting for the result: acknowledged data is not expired; the flush keeps max_execution_time from its own start"
echo "client error: $(run_insert 3 src_deadline "wait_for_async_insert=0, max_execution_time=1, async_insert_busy_timeout_min_ms=3000, async_insert_busy_timeout_max_ms=3000" "${Q}_3b")"
echo "client: $(outcome "${Q}_3b" 2500)"
F3B=$(flush_id_of "${Q}_3b")
echo "async_insert_log: $(async_log_status "${Q}_3b")"
echo "flush: $(outcome "$F3B" 2500)"
AFTER=$(expired_counter)
echo "expired counter grew by: $(( AFTER - BEFORE ))"
echo "rows at the end of the chain: $(rows_with_id t3_deadline 3)"

echo "-- 3c. a batch mixing an expired insert and a live one (preprocessed blocks): only the expired one is dropped"
BEFORE=$(expired_counter)
run_insert_blocks 31 plain_deadline "wait_for_async_insert=1, max_execution_time=3, async_insert_busy_timeout_min_ms=5000, async_insert_busy_timeout_max_ms=5000" "${Q}_3c1" > "${TMP_OUT}.3c1" &
# The second insert joins the same batch after the first one's deadline (3 s) but before the
# flush (5 s); if it arrives late it merely forms its own batch and the assertions still hold.
sleep 3.5
echo "second client error: $(run_insert_blocks 32 plain_deadline "wait_for_async_insert=1, max_execution_time=3, async_insert_busy_timeout_min_ms=5000, async_insert_busy_timeout_max_ms=5000" "${Q}_3c2")"
wait
echo "first client error: $(cat "${TMP_OUT}.3c1")"
echo "first client: $(outcome "${Q}_3c1" 5000)"
echo "first async_insert_log: $(async_log_status "${Q}_3c1")"
echo "second async_insert_log: $(async_log_status "${Q}_3c2")"
AFTER=$(expired_counter)
echo "expired counter grew by: $(( AFTER - BEFORE ))"
echo "rows of the expired insert: $(rows_with_id plain_deadline 31)"
echo "rows of the live insert: $(rows_with_id plain_deadline 32)"

echo "-- 4. no timeouts; KILL QUERY on the waiting client releases it while the flush completes"
run_insert 4 src_deadline "wait_for_async_insert=1, async_insert_busy_timeout_min_ms=100, async_insert_busy_timeout_max_ms=100" "${Q}_4" > "${TMP_OUT}.4" &
for _ in $(seq 1 100); do
    if [ "$($CLICKHOUSE_CLIENT -q "SELECT count() FROM system.processes WHERE query_id = '${Q}_4'")" = "1" ]; then break; fi
    sleep 0.1
done
$CLICKHOUSE_CLIENT -q "KILL QUERY WHERE query_id = '${Q}_4' ASYNC FORMAT Null"
wait
echo "client error: $(cat "${TMP_OUT}.4")"
echo "client: $(outcome "${Q}_4" 4000)"
F4=$(flush_id_of "${Q}_4")
echo "flush: $(outcome "$F4" 100000)"
echo "async_insert_log: $(async_log_status "${Q}_4")"
echo "rows at the end of the chain: $(rows_with_id t3_deadline 4)"

echo "-- 5. setting disabled: the client times out at 2 s and the flush runs to completion"
echo "client error: $(run_insert 5 src_deadline "wait_for_async_insert=1, wait_for_async_insert_timeout=2, async_insert_flush_timeout_from_queries=0, async_insert_busy_timeout_min_ms=100, async_insert_busy_timeout_max_ms=100" "${Q}_5")"
echo "client: $(outcome "${Q}_5" 4000)"
F5=$(flush_id_of "${Q}_5")
echo "flush: $($CLICKHOUSE_CLIENT -q "SELECT type, exception_code, if(query_duration_ms >= 5000, 'ran to completion', 'stopped early') FROM system.query_log WHERE query_id = '$F5' AND type != 'QueryStart' AND event_date >= yesterday() ORDER BY event_time_microseconds DESC LIMIT 1 FORMAT TSV")"
echo "rows at the end of the chain: $(rows_with_id t3_deadline 5)"

$CLICKHOUSE_CLIENT -q "
    DROP TABLE mv3_deadline;
    DROP TABLE mv2_deadline;
    DROP TABLE mv1_deadline;
    DROP TABLE t3_deadline;
    DROP TABLE t2_deadline;
    DROP TABLE t1_deadline;
    DROP TABLE src_deadline;
    DROP TABLE plain_deadline;
"
